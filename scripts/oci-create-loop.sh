#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

if [ -n "${OCI_CREATE_ENV_FILE:-}" ]; then
    CONFIG_FILE="$OCI_CREATE_ENV_FILE"
elif [ -f "$HOME/.oci-instance-creator.env" ]; then
    CONFIG_FILE="$HOME/.oci-instance-creator.env"
elif [ -f "$SCRIPT_DIR/.oci-instance-creator.env" ]; then
    CONFIG_FILE="$SCRIPT_DIR/.oci-instance-creator.env"
else
    CONFIG_FILE="$REPO_ROOT/.oci-instance-creator.env"
fi

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

LOG_FILE="${LOG_FILE:-$HOME/oci-instance.log}"
SUCCESS_FLAG="${SUCCESS_FLAG:-$HOME/.oci-instance-created}"
THROTTLE_STATE_FILE="${THROTTLE_STATE_FILE:-$HOME/.oci-instance-throttle.json}"
LOCK_DIR="${LOCK_DIR:-/tmp/oci-instance-creator-loop.lock}"

OCI_CLI_BIN="${OCI_CLI_BIN:-}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING="${OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING:-True}"
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING

COMPARTMENT_ID="${COMPARTMENT_ID:-}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-}"
AVAILABILITY_DOMAIN_NUMBER="${AVAILABILITY_DOMAIN_NUMBER:-1}"
SUBNET_ID="${SUBNET_ID:-}"
SUBNET_NAME="${SUBNET_NAME:-}"
IMAGE_ID="${IMAGE_ID:-}"
IMAGE_OPERATING_SYSTEM="${IMAGE_OPERATING_SYSTEM:-Canonical Ubuntu}"
IMAGE_OPERATING_SYSTEM_VERSION="${IMAGE_OPERATING_SYSTEM_VERSION:-24.04 Minimal aarch64}"

INSTANCE_NAME="${INSTANCE_NAME:-oci-free-tier-a1}"
INSTANCE_NAME_PREFIX="${INSTANCE_NAME_PREFIX:-$INSTANCE_NAME}"
TARGET_INSTANCE_COUNT="${TARGET_INSTANCE_COUNT:-1}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/oci_key.pub}"

DEFAULT_REGION="${DEFAULT_REGION:-}"
REGION_ROTATION="${REGION_ROTATION:-}"
OCI_SHAPE="${OCI_SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-4}"
MEMORY_GB="${MEMORY_GB:-24}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-100}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"

UPGRADE_AFTER_CREATE="${UPGRADE_AFTER_CREATE:-false}"
UPGRADE_STEPS="${UPGRADE_STEPS:-}"
UPGRADE_OCPUS="${UPGRADE_OCPUS:-$OCPUS}"
UPGRADE_MEMORY_GB="${UPGRADE_MEMORY_GB:-$MEMORY_GB}"

INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
RATE_LIMIT_BACKOFF_SECONDS="${RATE_LIMIT_BACKOFF_SECONDS:-180}"
JITTER_SECONDS="${JITTER_SECONDS:-10}"
MIN_INTERVAL_SECONDS="${MIN_INTERVAL_SECONDS:-$INTERVAL_SECONDS}"
MAX_INTERVAL_SECONDS="${MAX_INTERVAL_SECONDS:-360}"
RATE_LIMIT_MULTIPLIER="${RATE_LIMIT_MULTIPLIER:-1.15}"
DECAY_AFTER_NON_429="${DECAY_AFTER_NON_429:-3}"
DECAY_SECONDS="${DECAY_SECONDS:-15}"
EXISTING_CHECK_EVERY_ATTEMPTS="${EXISTING_CHECK_EVERY_ATTEMPTS:-20}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"
VALIDATE_ONLY="${VALIDATE_ONLY:-0}"

ATTEMPT=1
LAST_INSTANCES_FILE=""
LAST_INSTANCE_COUNT=0
LAST_PRIMARY_ID=""
LAST_PRIMARY_NAME=""
LAST_PRIMARY_REGION=""
LAST_PRIMARY_OCPUS="0"
LAST_PRIMARY_MEMORY_GB="0"

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "$LOG_FILE"
}

die_config() {
    log "$1"
    echo "$1" >&2
    exit 2
}

is_true() {
    printf '%s' "$1" | grep -Eiq '^(1|true|yes)$'
}

is_missing() {
    value="$1"
    [ -z "$value" ] || printf '%s' "$value" | grep -Eq 'xxxxx|replace-me|null|None'
}

require_value() {
    name="$1"
    value="$2"
    if is_missing "$value"; then
        die_config "Missing required config: $name"
    fi
}

require_number() {
    name="$1"
    value="$2"
    if ! printf '%s' "$value" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
        die_config "$name must be a number."
    fi
}

find_python() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif command -v python >/dev/null 2>&1; then
        command -v python
    else
        return 1
    fi
}

PYTHON_BIN="$(find_python || true)"
[ -n "$PYTHON_BIN" ] || die_config "python3 or python is required for JSON parsing."

if [ -z "$OCI_CLI_BIN" ]; then
    if command -v oci >/dev/null 2>&1; then
        OCI_CLI_BIN="$(command -v oci)"
    elif [ -x "$REPO_ROOT/.venv/bin/oci" ]; then
        OCI_CLI_BIN="$REPO_ROOT/.venv/bin/oci"
    elif [ -x "$REPO_ROOT/.venv/Scripts/oci.exe" ]; then
        OCI_CLI_BIN="$REPO_ROOT/.venv/Scripts/oci.exe"
    fi
fi

[ -n "$OCI_CLI_BIN" ] || die_config "OCI CLI not found. Set OCI_CLI_BIN or install oci-cli."
[ -x "$OCI_CLI_BIN" ] || command -v "$OCI_CLI_BIN" >/dev/null 2>&1 || die_config "OCI CLI not executable: $OCI_CLI_BIN"
[ -f "$OCI_CONFIG_FILE" ] || die_config "OCI config file not found: $OCI_CONFIG_FILE"

require_value "COMPARTMENT_ID" "$COMPARTMENT_ID"
require_number "TARGET_INSTANCE_COUNT" "$TARGET_INSTANCE_COUNT"
require_number "INTERVAL_SECONDS" "$INTERVAL_SECONDS"
require_number "MAX_ATTEMPTS" "$MAX_ATTEMPTS"
require_number "EXISTING_CHECK_EVERY_ATTEMPTS" "$EXISTING_CHECK_EVERY_ATTEMPTS"

if [ "$TARGET_INSTANCE_COUNT" -lt 1 ]; then
    die_config "TARGET_INSTANCE_COUNT must be at least 1"
fi

if is_true "$UPGRADE_AFTER_CREATE" && [ "$TARGET_INSTANCE_COUNT" -ne 1 ]; then
    die_config "UPGRADE_AFTER_CREATE requires TARGET_INSTANCE_COUNT=1"
fi

OCI_CMD=("$OCI_CLI_BIN" --config-file "$OCI_CONFIG_FILE" --profile "$OCI_PROFILE")

run_oci() {
    region="$1"
    shift
    if [ -n "$region" ]; then
        "${OCI_CMD[@]}" --region "$region" "$@"
    else
        "${OCI_CMD[@]}" "$@"
    fi
}

region_key() {
    printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

get_region_value() {
    region="$1"
    suffix="$2"
    global="$3"
    if [ -n "$region" ]; then
        key="REGION_$(region_key "$region")_${suffix}"
        eval "value=\${$key:-}"
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return
        fi
    fi
    printf '%s' "$global"
}

build_regions() {
    if [ -n "$REGION_ROTATION" ]; then
        printf '%s' "$REGION_ROTATION" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
    elif [ -n "$DEFAULT_REGION" ]; then
        printf '%s\n' "$DEFAULT_REGION"
    else
        printf '\n'
    fi
}

json_field() {
    "$PYTHON_BIN" -c '
import json, sys
path = sys.argv[1].split(".") if sys.argv[1] else []
default = sys.argv[2]
try:
    data = json.load(sys.stdin)
    for item in path:
        if item.isdigit():
            data = data[int(item)]
        else:
            data = data[item]
    print(default if data is None else data)
except Exception:
    print(default)
' "$1" "$2"
}

resolve_region_target() {
    region="$1"
    label="${region:-default}"
    ad="$(get_region_value "$region" "AVAILABILITY_DOMAIN" "$AVAILABILITY_DOMAIN")"
    subnet="$(get_region_value "$region" "SUBNET_ID" "$SUBNET_ID")"
    image="$(get_region_value "$region" "IMAGE_ID" "$IMAGE_ID")"
    subnet_name="$(get_region_value "$region" "SUBNET_NAME" "$SUBNET_NAME")"

    if is_missing "$ad"; then
        index=$((AVAILABILITY_DOMAIN_NUMBER - 1))
        result="$(run_oci "$region" iam availability-domain list --compartment-id "$COMPARTMENT_ID" --output json 2>>"$LOG_FILE")" || {
            log "Region skipped: region=$label reason=availability-domain lookup failed"
            return 1
        }
        ad="$(printf '%s' "$result" | json_field "data.$index.name" "")"
    fi

    if is_missing "$subnet" && [ -n "$subnet_name" ]; then
        result="$(run_oci "$region" network subnet list --compartment-id "$COMPARTMENT_ID" --display-name "$subnet_name" --all --output json 2>>"$LOG_FILE")" || true
        subnet="$(printf '%s' "$result" | json_field "data.0.id" "")"
    fi

    if is_missing "$image"; then
        result="$(run_oci "$region" compute image list \
            --compartment-id "$COMPARTMENT_ID" \
            --operating-system "$IMAGE_OPERATING_SYSTEM" \
            --operating-system-version "$IMAGE_OPERATING_SYSTEM_VERSION" \
            --shape "$OCI_SHAPE" \
            --sort-by TIMECREATED \
            --sort-order DESC \
            --all \
            --output json 2>>"$LOG_FILE")" || {
            log "Region skipped: region=$label reason=image lookup failed"
            return 1
        }
        image="$(printf '%s' "$result" | json_field "data.0.id" "")"
    fi

    if is_missing "$ad" || is_missing "$subnet" || is_missing "$image"; then
        log "Region skipped: region=$label reason=missing target ad=$ad subnet=$subnet image=$image"
        return 1
    fi

    printf '%s\t%s\t%s\t%s\n' "$region" "$ad" "$subnet" "$image"
}

write_temp_json() {
    file="$(mktemp "${TMPDIR:-/tmp}/oci-instance-creator.XXXXXX")"
    printf '%s' "$1" > "$file"
    printf '%s' "$file"
}

file_uri() {
    case "$1" in
        /*) printf 'file://%s' "$1" ;;
        *) printf 'file://%s/%s' "$PWD" "$1" ;;
    esac
}

parse_upgrade_steps() {
    if ! is_true "$UPGRADE_AFTER_CREATE"; then
        return
    fi

    if [ -n "$UPGRADE_STEPS" ]; then
        printf '%s' "$UPGRADE_STEPS" | tr ',' '\n' | while IFS= read -r step; do
            trimmed="$(printf '%s' "$step" | tr -d '[:space:]')"
            [ -n "$trimmed" ] || continue
            printf '%s' "$trimmed" | grep -Eq '^[0-9]+([.][0-9]+)?[:/][0-9]+([.][0-9]+)?$' || {
                echo "Invalid UPGRADE_STEPS item: $trimmed" >&2
                exit 2
            }
            printf '%s\n' "$trimmed" | tr ':/' ' '
        done
    else
        printf '%s %s\n' "$UPGRADE_OCPUS" "$UPGRADE_MEMORY_GB"
    fi
}

UPGRADE_STEPS_PARSED="$(parse_upgrade_steps)"
if is_true "$UPGRADE_AFTER_CREATE" && [ -z "$UPGRADE_STEPS_PARSED" ]; then
    die_config "UPGRADE_AFTER_CREATE requires at least one upgrade target"
fi

compare_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

final_upgrade_target() {
    printf '%s\n' "$UPGRADE_STEPS_PARSED" | awk 'NF { oc=$1; mem=$2 } END { if (oc != "") print oc, mem }'
}

next_upgrade_step() {
    current_ocpus="$1"
    current_mem="$2"
    printf '%s\n' "$UPGRADE_STEPS_PARSED" | while read -r target_ocpus target_mem; do
        [ -n "$target_ocpus" ] || continue
        if ! compare_ge "$current_ocpus" "$target_ocpus" || ! compare_ge "$current_mem" "$target_mem"; then
            printf '%s %s\n' "$target_ocpus" "$target_mem"
            return
        fi
    done
}

get_target_instances() {
    output_file="$(mktemp "${TMPDIR:-/tmp}/oci-instance-list.XXXXXX")"
    : > "$output_file"

    build_regions | while IFS= read -r region; do
        target="$(resolve_region_target "$region")" || continue
        label="${region:-default}"
        json="$(run_oci "$region" compute instance list --compartment-id "$COMPARTMENT_ID" --all --output json 2>>"$LOG_FILE")" || {
            log "Region skipped: region=$label reason=instance list failed"
            continue
        }
        printf '%s' "$json" | "$PYTHON_BIN" -c '
import json, sys
prefix, region = sys.argv[1], sys.argv[2]
try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}
for item in payload.get("data", []):
    name = item.get("display-name") or ""
    state = item.get("lifecycle-state") or ""
    if state in {"TERMINATED", "TERMINATING"}:
        continue
    if name != prefix and not name.startswith(prefix + "-"):
        continue
    shape = item.get("shape-config") or {}
    print("\t".join([
        item.get("id") or "",
        name,
        state,
        str(shape.get("ocpus") or 0),
        str(shape.get("memory-in-gbs") or shape.get("memoryInGBs") or 0),
        item.get("time-created") or "",
        region,
    ]))
' "$INSTANCE_NAME_PREFIX" "$region" >> "$output_file"
    done

    printf '%s' "$output_file"
}

load_target_state() {
    LAST_INSTANCES_FILE="$(get_target_instances)"
    LAST_INSTANCE_COUNT=0
    LAST_PRIMARY_ID=""
    LAST_PRIMARY_NAME=""
    LAST_PRIMARY_REGION=""
    LAST_PRIMARY_OCPUS="0"
    LAST_PRIMARY_MEMORY_GB="0"

    if [ -s "$LAST_INSTANCES_FILE" ]; then
        LAST_INSTANCE_COUNT="$(wc -l < "$LAST_INSTANCES_FILE" | tr -d ' ')"
        primary_line="$(awk -F '\t' -v exact="$INSTANCE_NAME" 'BEGIN{best=""} $2==exact{print; exit} best==""{best=$0} END{if(best!="") print best}' "$LAST_INSTANCES_FILE" | head -n 1)"
        if [ -n "$primary_line" ]; then
            OLD_IFS="$IFS"
            IFS='	'
            set -- $primary_line
            IFS="$OLD_IFS"
            LAST_PRIMARY_ID="${1:-}"
            LAST_PRIMARY_NAME="${2:-}"
            LAST_PRIMARY_OCPUS="${4:-0}"
            LAST_PRIMARY_MEMORY_GB="${5:-0}"
            LAST_PRIMARY_REGION="${7:-}"
        fi
    fi

    names="$(awk -F '\t' '{ printf "%s:%s:%socpu/%sgb%s", $2, $3, $4, $5, ORS }' "$LAST_INSTANCES_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    [ -n "$names" ] || names="none"
    log "Target instance check: count=$LAST_INSTANCE_COUNT target=$TARGET_INSTANCE_COUNT instances=$names"
}

target_upgraded() {
    if ! is_true "$UPGRADE_AFTER_CREATE"; then
        return 0
    fi
    final="$(final_upgrade_target)"
    [ -n "$final" ] || return 1
    set -- $final
    compare_ge "$LAST_PRIMARY_OCPUS" "$1" && compare_ge "$LAST_PRIMARY_MEMORY_GB" "$2"
}

target_reached() {
    [ "$LAST_INSTANCE_COUNT" -ge "$TARGET_INSTANCE_COUNT" ] && target_upgraded
}

write_success_flag_if_reached() {
    if target_reached; then
        touch "$SUCCESS_FLAG"
        log "Target reached. Success flag created: $SUCCESS_FLAG"
        return 0
    fi
    return 1
}

classify_result() {
    text="$1"
    if printf '%s' "$text" | grep -Eiq 'TooManyRequests|"status"[[:space:]]*:[[:space:]]*429|status.: 429'; then
        printf '2'
    elif printf '%s' "$text" | grep -Eiq 'timed out|timeout|RequestException'; then
        printf '3'
    else
        printf '1'
    fi
}

invoke_upgrade_attempt() {
    [ -n "$LAST_PRIMARY_ID" ] || return 1
    step="$(next_upgrade_step "$LAST_PRIMARY_OCPUS" "$LAST_PRIMARY_MEMORY_GB")"
    if [ -z "$step" ]; then
        load_target_state
        write_success_flag_if_reached
        return 0
    fi

    set -- $step
    target_ocpus="$1"
    target_mem="$2"
    log "Attempting to upgrade instance: region=${LAST_PRIMARY_REGION:-default} name=$LAST_PRIMARY_NAME id=$LAST_PRIMARY_ID current=${LAST_PRIMARY_OCPUS}ocpu/${LAST_PRIMARY_MEMORY_GB}gb target=${target_ocpus}ocpu/${target_mem}gb"

    shape_file="$(write_temp_json "{\"ocpus\": $target_ocpus, \"memoryInGBs\": $target_mem}")"
    result="$(run_oci "$LAST_PRIMARY_REGION" compute instance update \
        --instance-id "$LAST_PRIMARY_ID" \
        --shape-config "$(file_uri "$shape_file")" \
        --force 2>&1)"
    exit_code=$?
    rm -f "$shape_file"

    if [ "$exit_code" -eq 0 ]; then
        log "Upgrade request succeeded: $LAST_PRIMARY_NAME"
        printf '%s\n' "$result" >> "$LOG_FILE"
        load_target_state
        write_success_flag_if_reached || true
        return 0
    fi

    log "Upgrade failed (exit code: $exit_code)"
    printf '%s\n---\n' "$result" >> "$LOG_FILE"
    return "$(classify_result "$result")"
}

get_target_instance_name() {
    if [ "$TARGET_INSTANCE_COUNT" -eq 1 ]; then
        printf '%s' "$INSTANCE_NAME"
        return
    fi

    index=1
    while [ "$index" -le "$TARGET_INSTANCE_COUNT" ]; do
        candidate="${INSTANCE_NAME_PREFIX}-${index}"
        if [ -z "$LAST_INSTANCES_FILE" ] || ! awk -F '\t' -v name="$candidate" '$2 == name { found=1 } END { exit found ? 0 : 1 }' "$LAST_INSTANCES_FILE"; then
            printf '%s' "$candidate"
            return
        fi
        index=$((index + 1))
    done
    printf '%s' "$INSTANCE_NAME_PREFIX"
}

invoke_create_attempt() {
    if [ -f "$SUCCESS_FLAG" ]; then
        log "Success flag exists. Nothing to do."
        return 0
    fi

    should_check=0
    if [ "$ATTEMPT" -eq 1 ] || [ "$VALIDATE_ONLY" = "1" ]; then
        should_check=1
    elif [ $(((ATTEMPT - 1) % EXISTING_CHECK_EVERY_ATTEMPTS)) -eq 0 ]; then
        should_check=1
    fi

    if [ "$should_check" -eq 1 ]; then
        load_target_state
    else
        LAST_INSTANCE_COUNT=0
        LAST_INSTANCES_FILE=""
        log "Skipping target instance check to reduce OCI API calls: attempt=$ATTEMPT nextCheckEvery=$EXISTING_CHECK_EVERY_ATTEMPTS"
    fi

    if [ "$VALIDATE_ONLY" = "1" ]; then
        log "Validation passed: namePrefix=$INSTANCE_NAME_PREFIX target=$TARGET_INSTANCE_COUNT upgradeAfterCreate=$UPGRADE_AFTER_CREATE"
        echo "Validation passed."
        return 0
    fi

    if [ "$should_check" -eq 1 ] && write_success_flag_if_reached; then
        return 0
    fi

    if [ "$should_check" -eq 1 ] && is_true "$UPGRADE_AFTER_CREATE" && [ "$LAST_INSTANCE_COUNT" -ge "$TARGET_INSTANCE_COUNT" ]; then
        invoke_upgrade_attempt
        return $?
    fi

    target="$(build_regions | while IFS= read -r region; do resolve_region_target "$region" && break; done | head -n 1)"
    [ -n "$target" ] || {
        log "No usable region target found."
        return 1
    }

    OLD_IFS="$IFS"
    IFS='	'
    set -- $target
    IFS="$OLD_IFS"
    region="${1:-}"
    ad="${2:-}"
    subnet="${3:-}"
    image="${4:-}"

    authorized_key_file="$SSH_KEY_FILE"
    temp_key_file=""
    if [ -n "$SSH_PUBLIC_KEY" ]; then
        temp_key_file="$(mktemp "${TMPDIR:-/tmp}/oci-instance-creator-ssh-key.XXXXXX")"
        printf '%s\n' "$SSH_PUBLIC_KEY" > "$temp_key_file"
        authorized_key_file="$temp_key_file"
    elif [ ! -f "$authorized_key_file" ]; then
        die_config "SSH public key file not found: $authorized_key_file"
    fi

    create_name="$(get_target_instance_name)"
    shape_file="$(write_temp_json "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}")"
    source_file="$(write_temp_json "{\"sourceType\":\"image\",\"imageId\":\"$image\",\"bootVolumeSizeInGBs\":$BOOT_VOLUME_GB}")"

    log "Attempting to create instance: region=${region:-default} name=$create_name target=$TARGET_INSTANCE_COUNT existing=$LAST_INSTANCE_COUNT shape=$OCI_SHAPE ocpus=$OCPUS memoryGB=$MEMORY_GB publicIp=$ASSIGN_PUBLIC_IP"
    result="$(run_oci "$region" compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$ad" \
        --shape "$OCI_SHAPE" \
        --shape-config "$(file_uri "$shape_file")" \
        --subnet-id "$subnet" \
        --source-details "$(file_uri "$source_file")" \
        --assign-public-ip "$ASSIGN_PUBLIC_IP" \
        --ssh-authorized-keys-file "$authorized_key_file" \
        --display-name "$create_name" 2>&1)"
    exit_code=$?

    rm -f "$shape_file" "$source_file" "$temp_key_file"

    if [ "$exit_code" -eq 0 ] && printf '%s' "$result" | grep -q "ocid1.instance"; then
        log "Create request succeeded: $create_name"
        printf '%s\n' "$result" >> "$LOG_FILE"
        load_target_state
        if [ "$LAST_INSTANCE_COUNT" -ge "$TARGET_INSTANCE_COUNT" ] && is_true "$UPGRADE_AFTER_CREATE"; then
            invoke_upgrade_attempt || true
        else
            write_success_flag_if_reached || true
        fi
        return 0
    fi

    log "Failed (exit code: $exit_code)"
    printf '%s\n---\n' "$result" >> "$LOG_FILE"
    return "$(classify_result "$result")"
}

read_throttle_state() {
    if [ -f "$THROTTLE_STATE_FILE" ]; then
        "$PYTHON_BIN" -c '
import json, sys
default, minimum, maximum, path = map(str, sys.argv[1:])
try:
    data = json.load(open(path, encoding="utf-8"))
    current = int(data.get("CurrentIntervalSeconds", default))
    non429 = int(data.get("ConsecutiveNon429", 0))
except Exception:
    current, non429 = int(default), 0
current = max(int(minimum), min(current, int(maximum)))
print(current, non429)
' "$INTERVAL_SECONDS" "$MIN_INTERVAL_SECONDS" "$MAX_INTERVAL_SECONDS" "$THROTTLE_STATE_FILE"
    else
        printf '%s 0\n' "$INTERVAL_SECONDS"
    fi
}

write_throttle_state() {
    current="$1"
    non429="$2"
    mkdir -p "$(dirname "$THROTTLE_STATE_FILE")" 2>/dev/null || true
    printf '{"CurrentIntervalSeconds":%s,"ConsecutiveNon429":%s}\n' "$current" "$non429" > "$THROTTLE_STATE_FILE"
}

adaptive_sleep_seconds() {
    result_code="$1"
    state="$(read_throttle_state)"
    set -- $state
    current="$1"
    non429="$2"

    if [ "$result_code" -eq 2 ]; then
        multiplied="$(awk -v c="$current" -v m="$RATE_LIMIT_MULTIPLIER" 'BEGIN { printf "%d", int(c * m + 0.999999) }')"
        current="$multiplied"
        [ "$current" -lt "$RATE_LIMIT_BACKOFF_SECONDS" ] && current="$RATE_LIMIT_BACKOFF_SECONDS"
        [ "$current" -gt "$MAX_INTERVAL_SECONDS" ] && current="$MAX_INTERVAL_SECONDS"
        non429=0
    elif [ "$result_code" -eq 3 ]; then
        :
    else
        non429=$((non429 + 1))
        if [ "$non429" -ge "$DECAY_AFTER_NON_429" ]; then
            current=$((current - DECAY_SECONDS))
            [ "$current" -lt "$MIN_INTERVAL_SECONDS" ] && current="$MIN_INTERVAL_SECONDS"
            non429=0
        fi
    fi

    write_throttle_state "$current" "$non429"
    sleep_seconds="$current"
    if [ "$JITTER_SECONDS" -gt 0 ]; then
        jitter=$((RANDOM % (JITTER_SECONDS + 1)))
        sleep_seconds=$((sleep_seconds + jitter))
    fi
    printf '%s\n' "$sleep_seconds"
}

if [ -f "$SUCCESS_FLAG" ]; then
    echo "Success flag already exists: $SUCCESS_FLAG"
    exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another loop is already running. Skipping."
    echo "Another loop is already running. Skipping."
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; [ -n "${LAST_INSTANCES_FILE:-}" ] && rm -f "$LAST_INSTANCES_FILE" 2>/dev/null || true' EXIT INT TERM

state="$(read_throttle_state)"
log "Throttle state loaded: interval=$(printf '%s' "$state" | awk '{print $1}') consecutiveNon429=$(printf '%s' "$state" | awk '{print $2}')"

while [ ! -f "$SUCCESS_FLAG" ]; do
    if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]; then
        echo "Max attempts reached: $MAX_ATTEMPTS"
        exit 1
    fi

    echo "Attempt $ATTEMPT at $(date '+%Y-%m-%d %H:%M:%S %z')"
    result_code=0
    invoke_create_attempt || result_code=$?

    if [ "$VALIDATE_ONLY" = "1" ] || [ -f "$SUCCESS_FLAG" ]; then
        exit "$result_code"
    fi

    sleep_seconds="$(adaptive_sleep_seconds "$result_code")"
    echo "Sleeping $sleep_seconds seconds"
    log "Sleeping $sleep_seconds seconds before next attempt."
    ATTEMPT=$((ATTEMPT + 1))
    sleep "$sleep_seconds"
done

echo "Success flag already exists: $SUCCESS_FLAG"
