#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -n "${OCI_CREATE_ENV_FILE:-}" ]; then
    CONFIG_FILE="$OCI_CREATE_ENV_FILE"
elif [ -f "$HOME/.oci-instance-creator.env" ]; then
    CONFIG_FILE="$HOME/.oci-instance-creator.env"
elif [ -f "$SCRIPT_DIR/.oci-instance-creator.env" ]; then
    CONFIG_FILE="$SCRIPT_DIR/.oci-instance-creator.env"
else
    CONFIG_FILE="$SCRIPT_DIR/../.oci-instance-creator.env"
fi

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

LOG_FILE="${LOG_FILE:-$HOME/oci-instance.log}"
SUCCESS_FLAG="${SUCCESS_FLAG:-$HOME/.oci-instance-created}"
LOCK_DIR="${LOCK_DIR:-/tmp/oci-instance-creator.lock}"
VALIDATE_ONLY="${VALIDATE_ONLY:-0}"

DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
OCI_CLI_BIN="${OCI_CLI_BIN:-}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-}"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
OCI_CONNECTION_TIMEOUT_SECONDS="${OCI_CONNECTION_TIMEOUT_SECONDS:-240}"
OCI_READ_TIMEOUT_SECONDS="${OCI_READ_TIMEOUT_SECONDS:-480}"
COMPARTMENT_ID="${COMPARTMENT_ID:-}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-}"
AVAILABILITY_DOMAIN_NUMBER="${AVAILABILITY_DOMAIN_NUMBER:-}"
SUBNET_ID="${SUBNET_ID:-}"
SUBNET_NAME="${SUBNET_NAME:-}"
IMAGE_ID="${IMAGE_ID:-}"
IMAGE_OPERATING_SYSTEM="${IMAGE_OPERATING_SYSTEM:-}"
IMAGE_OPERATING_SYSTEM_VERSION="${IMAGE_OPERATING_SYSTEM_VERSION:-}"
INSTANCE_NAME="${INSTANCE_NAME:-oci-free-tier-a1}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/oci_key.pub}"

OCI_SHAPE="${OCI_SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-4}"
MEMORY_GB="${MEMORY_GB:-24}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-100}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING="${OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING:-True}"
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING

log() {
    printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "$LOG_FILE"
}

require_value() {
    name="$1"
    value="$2"
    if is_missing "$value"; then
        log "Missing required config: $name"
        echo "Missing required config: $name" >&2
        exit 2
    fi
}

is_missing() {
    value="$1"
    [ -z "$value" ] || printf '%s' "$value" | grep -Eq 'xxxxx|replace-me|null|None'
}

if [ -f "$SUCCESS_FLAG" ]; then
    log "Success flag exists. Nothing to do."
    exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another attempt is already running. Skipping."
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

if [ -z "$OCI_CLI_BIN" ]; then
    if command -v oci >/dev/null 2>&1; then
        OCI_CLI_BIN="oci"
    elif [ -x "$SCRIPT_DIR/../.venv/Scripts/oci.exe" ]; then
        OCI_CLI_BIN="$SCRIPT_DIR/../.venv/Scripts/oci.exe"
    elif [ -x "$SCRIPT_DIR/../.venv/bin/oci" ]; then
        OCI_CLI_BIN="$SCRIPT_DIR/../.venv/bin/oci"
    fi
fi

if [ -z "$OCI_CLI_BIN" ]; then
    log "OCI CLI not found in PATH."
    echo "OCI CLI not found in PATH." >&2
    exit 127
fi

OCI_CMD=("$OCI_CLI_BIN")
OCI_CMD+=(--connection-timeout "$OCI_CONNECTION_TIMEOUT_SECONDS" --read-timeout "$OCI_READ_TIMEOUT_SECONDS")
if [ -n "$OCI_CONFIG_FILE" ]; then
    if [ ! -f "$OCI_CONFIG_FILE" ]; then
        log "OCI config file not found: $OCI_CONFIG_FILE"
        echo "OCI config file not found: $OCI_CONFIG_FILE" >&2
        exit 2
    fi
    OCI_CMD+=(--config-file "$OCI_CONFIG_FILE" --profile "$OCI_PROFILE")
fi

require_value "COMPARTMENT_ID" "$COMPARTMENT_ID"

if is_missing "$AVAILABILITY_DOMAIN" && [ -n "$AVAILABILITY_DOMAIN_NUMBER" ]; then
    AD_INDEX=$((AVAILABILITY_DOMAIN_NUMBER - 1))
    AVAILABILITY_DOMAIN=$("${OCI_CMD[@]}" iam availability-domain list \
        --compartment-id "$COMPARTMENT_ID" \
        --query "data[$AD_INDEX].name" \
        --raw-output 2>>"$LOG_FILE")
fi

if is_missing "$SUBNET_ID" && [ -n "$SUBNET_NAME" ]; then
    SUBNET_ID=$("${OCI_CMD[@]}" network subnet list \
        --compartment-id "$COMPARTMENT_ID" \
        --display-name "$SUBNET_NAME" \
        --all \
        --query 'data[0].id' \
        --raw-output 2>>"$LOG_FILE")
fi

if is_missing "$IMAGE_ID" && [ -n "$IMAGE_OPERATING_SYSTEM" ] && [ -n "$IMAGE_OPERATING_SYSTEM_VERSION" ]; then
    IMAGE_ID=$("${OCI_CMD[@]}" compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --operating-system "$IMAGE_OPERATING_SYSTEM" \
        --operating-system-version "$IMAGE_OPERATING_SYSTEM_VERSION" \
        --shape "$OCI_SHAPE" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --all \
        --query 'data[0].id' \
        --raw-output 2>>"$LOG_FILE")
fi

TEMP_SSH_KEY_FILE=""
if [ -n "$SSH_PUBLIC_KEY" ]; then
    TEMP_SSH_KEY_FILE="${TMPDIR:-/tmp}/oci-instance-creator-ssh-key.$$"
    printf '%s\n' "$SSH_PUBLIC_KEY" > "$TEMP_SSH_KEY_FILE"
    SSH_KEY_FILE="$TEMP_SSH_KEY_FILE"
elif [ ! -f "$SSH_KEY_FILE" ]; then
    log "SSH public key file not found: $SSH_KEY_FILE"
    echo "SSH public key file not found: $SSH_KEY_FILE" >&2
    exit 2
fi

require_value "AVAILABILITY_DOMAIN" "$AVAILABILITY_DOMAIN"
require_value "SUBNET_ID" "$SUBNET_ID"
require_value "IMAGE_ID" "$IMAGE_ID"

if [ "$VALIDATE_ONLY" = "1" ]; then
    log "Validation passed: name=$INSTANCE_NAME availabilityDomain=$AVAILABILITY_DOMAIN subnet=$SUBNET_ID image=$IMAGE_ID"
    echo "Validation passed."
    echo "Instance: $INSTANCE_NAME"
    echo "Availability domain: $AVAILABILITY_DOMAIN"
    echo "Subnet: $SUBNET_ID"
    echo "Image: $IMAGE_ID"
    exit 0
fi

log "Attempting to create instance: name=$INSTANCE_NAME shape=$OCI_SHAPE ocpus=$OCPUS memoryGB=$MEMORY_GB"

RESULT=$("${OCI_CMD[@]}" compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AVAILABILITY_DOMAIN" \
    --shape "$OCI_SHAPE" \
    --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
    --subnet-id "$SUBNET_ID" \
    --source-details "{\"sourceType\":\"image\",\"imageId\":\"$IMAGE_ID\",\"bootVolumeSizeInGBs\":$BOOT_VOLUME_GB}" \
    --assign-public-ip "$ASSIGN_PUBLIC_IP" \
    --ssh-authorized-keys-file "$SSH_KEY_FILE" \
    --display-name "$INSTANCE_NAME" \
    2>&1)

EXIT_CODE=$?

if [ -n "$TEMP_SSH_KEY_FILE" ]; then
    rm -f "$TEMP_SSH_KEY_FILE"
fi

if [ "$EXIT_CODE" -eq 0 ] && printf '%s' "$RESULT" | grep -q "ocid1.instance"; then
    log "SUCCESS!"
    printf '%s\n' "$RESULT" >> "$LOG_FILE"
    touch "$SUCCESS_FLAG"

    if [ -n "$DISCORD_WEBHOOK" ]; then
        curl -fsS -H "Content-Type: application/json" \
            -d "{\"content\":\"OCI 인스턴스 생성 성공: $INSTANCE_NAME\n$(date '+%Y-%m-%d %H:%M:%S %z')\"}" \
            "$DISCORD_WEBHOOK" >/dev/null || log "Discord notification failed."
    fi
else
    log "Failed (exit code: $EXIT_CODE)"
    printf '%s\n---\n' "$RESULT" >> "$LOG_FILE"
    if printf '%s' "$RESULT" | grep -Eiq 'TooManyRequests|"status"[[:space:]]*:[[:space:]]*429|status.: 429'; then
        exit 2
    fi
    if printf '%s' "$RESULT" | grep -Eiq 'timed out|timeout|RequestException'; then
        exit 3
    fi
    exit 1
fi
