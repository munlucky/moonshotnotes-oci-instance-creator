# Moonshotnotes OCI Instance Creator

Oracle Cloud Always Free A1 Flex 인스턴스를 CLI로 반복 생성하는 자동화 스크립트입니다.

핵심 동작:

- 기본 `60초 + 0~10초 jitter` 간격으로 생성 시도
- `429 TooManyRequests` 발생 시에만 `180 -> 207 -> 238 -> 273 -> 314 -> 360초` backoff
- 429가 아닌 응답이 3회 연속 나오면 15초씩 낮추며 429가 덜 뜨는 안정 텀 탐색
- `Out of host capacity` / `500 InternalError`는 A1 자리 부족으로 보고 계속 재시도
- 기존 인스턴스 조회는 기본 20회마다 1번만 수행해서 불필요한 API 요청 최소화
- `1 OCPU / 6GB`로 먼저 생성한 뒤 `2/12 -> 4/24` 순서로 resize 가능
- 성공하면 success flag를 만들고 PM2가 다시 실행하지 않도록 정상 종료

## 권장 전략

Always Free A1은 `4 OCPU / 24GB`를 한 번에 확보하기 어렵습니다. 아래 전략을 권장합니다.

```env
OCPUS="1"
MEMORY_GB="6"
UPGRADE_AFTER_CREATE="true"
UPGRADE_STEPS="2:12,4:24"
```

동작 순서:

1. `1 OCPU / 6GB` 인스턴스 생성
2. 생성 성공 후 같은 인스턴스를 `2 OCPU / 12GB`로 resize
3. 성공하면 `4 OCPU / 24GB`로 resize
4. 목표 상태 확인 후 `SUCCESS_FLAG` 생성
5. PM2 실행 중이면 exit code `0`으로 종료되어 재시작하지 않음

## 에러 의미

| 에러 | 의미 | 처리 |
| --- | --- | --- |
| `Out of host capacity` / `InternalError` / `500` | 해당 리전에 빈 A1 자리가 없음 | 정상 실패로 보고 계속 재시도 |
| `TooManyRequests` / `429` | OCI API 요청이 너무 잦음 | 429 전용 backoff 적용 |
| `The connection to endpoint timed out` | OCI CLI 또는 Oracle endpoint 응답 지연 | 다음 루프에서 재시도 |
| `NotAuthenticated` | OCI config, private key, fingerprint, region, 구독 문제 | 인증 설정부터 수정 |

## 준비물

- Oracle Cloud 계정
- OCI API key private key `.pem`
- OCI config preview 값
- VCN / subnet
- SSH 공개키
- Node.js와 PM2, 장시간 실행할 경우
- Python 3, macOS shell 루프에서 JSON 파싱에 사용

## 1. 저장소 받기

**Windows PowerShell**

```powershell
git clone https://github.com/munlucky/moonshotnotes-oci-instance-creator.git
cd moonshotnotes-oci-instance-creator
```

**macOS Terminal**

```bash
git clone https://github.com/munlucky/moonshotnotes-oci-instance-creator.git
cd moonshotnotes-oci-instance-creator
chmod +x scripts/oci-create.sh scripts/oci-create-loop.sh
```

## 2. OCI CLI 설치

**Windows PowerShell**

repo 안의 `.venv`에 OCI CLI를 설치하면 기본 설정 그대로 동작합니다.

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install oci-cli
.\.venv\Scripts\oci.exe --version
```

**macOS Terminal**

Homebrew를 쓰면 가장 단순합니다.

```bash
brew install oci-cli
oci --version
```

Homebrew를 쓰지 않는다면 Oracle 공식 설치 스크립트를 사용할 수 있습니다.

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
source ~/.bashrc 2>/dev/null || source ~/.zshrc
oci --version
```

이미 OCI CLI가 다른 경로에 설치되어 있다면 env에서 직접 지정할 수 있습니다.

```env
OCI_CLI_BIN="/path/to/oci"
```

Windows 예:

```env
OCI_CLI_BIN="C:\path\to\oci.exe"
```

## 3. OCI API key 만들기

OCI 콘솔에서 API key를 만들고 Configuration preview 값을 복사합니다.

```text
OCI Console -> 우측 상단 Profile -> User settings -> Tokens and keys -> Add API key
```

필요한 값:

| 값 | 설명 |
| --- | --- |
| `user` | OCI user OCID |
| `fingerprint` | API key fingerprint |
| `tenancy` | tenancy OCID |
| `region` | 예: `ap-chuncheon-1` |
| private key `.pem` | API key 생성 시 다운로드한 파일 |

## 4. OCI config 작성

**Windows PowerShell**

```powershell
New-Item -ItemType Directory -Force "$HOME\.oci" | Out-Null
notepad "$HOME\.oci\config"
```

`config` 내용:

```ini
[DEFAULT]
user=<oci-user-ocid>
fingerprint=<api-key-fingerprint>
tenancy=<oci-tenancy-ocid>
region=ap-chuncheon-1
key_file=C:\Users\YOUR_WINDOWS_USER\.oci\key.pem
```

private key 복사:

```powershell
Copy-Item "C:\path\to\downloaded-api-key.pem" "$HOME\.oci\key.pem"
```

연결 테스트:

```powershell
.\.venv\Scripts\oci.exe iam region-subscription list --output table
```

**macOS Terminal**

```bash
mkdir -p ~/.oci
nano ~/.oci/config
```

`config` 내용:

```ini
[DEFAULT]
user=<oci-user-ocid>
fingerprint=<api-key-fingerprint>
tenancy=<oci-tenancy-ocid>
region=ap-chuncheon-1
key_file=/Users/YOUR_MAC_USER/.oci/key.pem
```

private key 복사와 권한 설정:

```bash
cp /path/to/downloaded-api-key.pem ~/.oci/key.pem
chmod 600 ~/.oci/config ~/.oci/key.pem
```

연결 테스트:

```bash
oci iam region-subscription list --output table
```

`ap-chuncheon-1`이 `READY` 상태여야 합니다. 구독되지 않은 리전은 인스턴스 생성에 사용할 수 없습니다.

## 5. SSH 공개키 준비

**Windows PowerShell**

기존 공개키 확인:

```powershell
Get-Content "$HOME\.ssh\id_rsa.pub"
```

없으면 생성:

```powershell
ssh-keygen -t rsa -b 4096 -f "$HOME\.ssh\id_rsa"
```

**macOS Terminal**

기존 공개키 확인:

```bash
cat ~/.ssh/id_rsa.pub
```

없으면 생성:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
```

env 파일에는 공개키 파일 경로를 쓰거나 공개키 문자열을 직접 넣을 수 있습니다.

```env
SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub"
SSH_PUBLIC_KEY=""
```

private key는 env 파일에 넣지 않습니다.

## 6. OCI 리소스 값 확인

필수값:

| env 키 | 확인 위치 |
| --- | --- |
| `COMPARTMENT_ID` | tenancy OCID 또는 사용할 compartment OCID |
| `SUBNET_ID` | OCI Console -> Networking -> VCN -> Subnets -> subnet OCID |
| `AVAILABILITY_DOMAIN` | OCI Console -> Compute -> Create instance 화면의 AD 값 |

이미지 OCID는 직접 넣어도 되고, OS 이름으로 조회하게 둘 수도 있습니다.

Ubuntu 24.04 Minimal aarch64 자동 조회 설정:

```env
IMAGE_ID=""
IMAGE_OPERATING_SYSTEM="Canonical Ubuntu"
IMAGE_OPERATING_SYSTEM_VERSION="24.04 Minimal aarch64"
```

## 7. env 파일 작성

**Windows PowerShell**

```powershell
Copy-Item .\scripts\oci-create.env.example .\.oci-instance-creator.env
notepad .\.oci-instance-creator.env
```

**macOS Terminal**

```bash
cp scripts/oci-create.env.example .oci-instance-creator.env
nano .oci-instance-creator.env
```

공통 최소 설정 예시:

```env
COMPARTMENT_ID="<oci-tenancy-or-compartment-ocid>"
AVAILABILITY_DOMAIN="sHjR:AP-CHUNCHEON-1-AD-1"
AVAILABILITY_DOMAIN_NUMBER="1"
SUBNET_ID="<oci-subnet-ocid>"
SUBNET_NAME=""

IMAGE_ID=""
IMAGE_OPERATING_SYSTEM="Canonical Ubuntu"
IMAGE_OPERATING_SYSTEM_VERSION="24.04 Minimal aarch64"

INSTANCE_NAME="instance-oci-a1"
INSTANCE_NAME_PREFIX="instance-oci-a1"
TARGET_INSTANCE_COUNT="1"

SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub"
SSH_PUBLIC_KEY=""

OCI_CONFIG_FILE="$HOME/.oci/config"
OCI_PROFILE="DEFAULT"
DEFAULT_REGION="ap-chuncheon-1"
REGION_ROTATION="ap-chuncheon-1"

OCI_SHAPE="VM.Standard.A1.Flex"
OCPUS="1"
MEMORY_GB="6"
BOOT_VOLUME_GB="50"
ASSIGN_PUBLIC_IP="true"

UPGRADE_AFTER_CREATE="true"
UPGRADE_STEPS="2:12,4:24"
UPGRADE_OCPUS="4"
UPGRADE_MEMORY_GB="24"

INTERVAL_SECONDS="60"
RATE_LIMIT_BACKOFF_SECONDS="180"
JITTER_SECONDS="10"
MIN_INTERVAL_SECONDS="60"
MAX_INTERVAL_SECONDS="360"
RATE_LIMIT_MULTIPLIER="1.15"
DECAY_AFTER_NON_429="3"
DECAY_SECONDS="15"
EXISTING_CHECK_EVERY_ATTEMPTS="20"
MAX_ATTEMPTS="0"

LOG_FILE="$HOME/oci-instance.log"
SUCCESS_FLAG="$HOME/.oci-instance-created"
THROTTLE_STATE_FILE="$HOME/.oci-instance-throttle.json"

DISCORD_WEBHOOK=""
OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING="True"
```

Windows에서도 위처럼 `$HOME/...` 경로를 쓰면 PowerShell 스크립트가 현재 사용자 홈 경로로 치환합니다.

주의:

- `.oci-instance-creator.env`는 `.gitignore`에 포함되어 있습니다.
- `.pem`, `.key`, `.oci/config`, 실제 OCID가 담긴 파일은 public repo에 올리지 않습니다.
- `ASSIGN_PUBLIC_IP="true"`면 생성된 인스턴스에 public IPv4를 요청합니다.

## 8. 설정 검증

OCI 생성 요청을 보내기 전에 설정과 조회 경로를 검증합니다.

**Windows PowerShell**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\oci-create-loop.ps1 -EnvFile .\.oci-instance-creator.env -ValidateOnly
```

**macOS Terminal**

```bash
VALIDATE_ONLY=1 ./scripts/oci-create-loop.sh
```

정상이라면 `Validation passed.`가 출력됩니다.

## 9. 1회 실행 테스트

**Windows PowerShell**

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\oci-create-loop.ps1 -EnvFile .\.oci-instance-creator.env -Once
```

로그 확인:

```powershell
Get-Content "$HOME/oci-instance.log" -Tail 80
```

**macOS Terminal**

```bash
./scripts/oci-create.sh
```

로그 확인:

```bash
tail -n 80 ~/oci-instance.log
```

`Out of host capacity`가 나오면 설정 문제는 아닙니다. A1 자리가 없어 실패한 것입니다.

## 10. PM2로 계속 실행

PM2는 Windows와 macOS 모두 같은 설정을 사용합니다.

- Windows: `scripts/oci-create-loop.ps1` 실행
- macOS/Linux: `scripts/oci-create-loop.sh` 실행

**Windows PowerShell**

PM2 설치:

```powershell
npm install -g pm2
pm2 --version
```

시작:

```powershell
pm2 start ecosystem.config.cjs --update-env
pm2 save
```

상태 확인:

```powershell
pm2 list
pm2 describe oci-instance-creator
```

로그 확인:

```powershell
Get-Content "$HOME/oci-instance.log" -Tail 80
```

중지:

```powershell
pm2 stop oci-instance-creator
```

**macOS Terminal**

PM2 설치:

```bash
npm install -g pm2
pm2 --version
```

시작:

```bash
pm2 start ecosystem.config.cjs --update-env
pm2 save
```

상태 확인:

```bash
pm2 list
pm2 describe oci-instance-creator
```

로그 확인:

```bash
tail -n 80 ~/oci-instance.log
```

중지:

```bash
pm2 stop oci-instance-creator
```

성공 후에는 `SUCCESS_FLAG` 파일이 생기고 스크립트가 exit code `0`으로 종료됩니다. `ecosystem.config.cjs`는 `stop_exit_codes: [0]`을 사용하므로 성공 종료 후 PM2가 다시 실행하지 않습니다.

## 11. throttle / success flag 초기화

429 backoff 상태를 초기화하려면 throttle state 파일을 지웁니다.

**Windows PowerShell**

```powershell
Remove-Item "$HOME/.oci-instance-throttle.json" -ErrorAction SilentlyContinue
pm2 restart oci-instance-creator --update-env
```

success flag가 있으면 스크립트는 더 이상 생성 시도를 하지 않습니다. 다시 시도하려면 success flag도 삭제합니다.

```powershell
Remove-Item "$HOME/.oci-instance-created" -ErrorAction SilentlyContinue
pm2 restart oci-instance-creator --update-env
```

**macOS Terminal**

```bash
rm -f ~/.oci-instance-throttle.json
pm2 restart oci-instance-creator --update-env
```

success flag 삭제:

```bash
rm -f ~/.oci-instance-created
pm2 restart oci-instance-creator --update-env
```

## 12. cron으로 실행, macOS/Linux 선택 사항

PM2를 권장하지만 cron으로도 실행할 수 있습니다.

```bash
crontab -e
```

```cron
* * * * * PATH=$HOME/bin:/usr/local/bin:/opt/homebrew/bin:$PATH /path/to/moonshotnotes-oci-instance-creator/scripts/oci-create.sh
```

cron은 shell profile을 읽지 않을 수 있으므로 `PATH`를 명시합니다.

## GitHub Actions

GitHub Actions 방식은 cron 지연과 최소 실행 간격 때문에 권장하지 않습니다. 로컬 PC, VM, 또는 PM2 실행이 더 적합합니다.

그래도 사용하려면 repository secrets에 아래 값을 넣어야 합니다.

| Secret | 설명 |
| --- | --- |
| `OCI_USER` | OCI user OCID |
| `OCI_FINGERPRINT` | API key fingerprint |
| `OCI_TENANCY` | tenancy OCID |
| `OCI_KEY` | API private key 내용 |
| `OCI_SUBNET` | subnet OCID |
| `OCI_IMAGE` | image OCID |
| `SSH_PUBLIC_KEY` | SSH 공개키 |

## 파일 구조

| 파일 | 역할 |
| --- | --- |
| `scripts/oci-create-loop.ps1` | Windows용 메인 루프. PM2에서 사용 |
| `scripts/oci-create-loop.sh` | macOS/Linux용 메인 루프. 429 backoff, target check 최소화, 생성 후 upgrade 지원 |
| `scripts/pm2-oci-runner.cjs` | OS별 루프를 PM2에서 실행하는 wrapper |
| `ecosystem.config.cjs` | Windows/macOS/Linux 공통 PM2 앱 설정 |
| `scripts/oci-create.sh` | macOS/Linux용 1회 실행 |
| `scripts/oci-create.env.example` | env 예제 |

## 보안 체크리스트

public repo에 올리면 안 되는 파일:

- `.oci-instance-creator.env`
- `.oci/`
- `*.pem`
- `*.key`
- `*.p8`
- `logs/`
- `*.log`
- `.venv/`
- `.uv-cache/`
- `.claude/`
- `.moonshot-state/`

이 저장소의 `.gitignore`에는 위 항목이 포함되어 있습니다.

## 빠른 진단 명령

**Windows PowerShell**

```powershell
pm2 list
pm2 describe oci-instance-creator
Get-Content "$HOME/oci-instance.log" -Tail 80
Get-Content "$HOME/.oci-instance-throttle.json"
.\.venv\Scripts\oci.exe iam region-subscription list --output table
```

**macOS Terminal**

```bash
pm2 list
pm2 describe oci-instance-creator
tail -n 80 ~/oci-instance.log
cat ~/.oci-instance-throttle.json
oci iam region-subscription list --output table
```

인스턴스 목록:

```bash
oci compute instance list --compartment-id <compartment-ocid> --region ap-chuncheon-1 --output table
```

## 참고

- [OCI Always Free](https://www.oracle.com/cloud/free/)
- [OCI CLI documentation](https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm)
