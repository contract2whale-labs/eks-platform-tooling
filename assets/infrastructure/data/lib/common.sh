#!/usr/bin/env bash
# data/lib/common.sh — 데이터 운영 셸 프로그램의 공통 함수 (데이터베이스 운영자 이미지와 읽기 전용 진단)
# 비밀값은 표준 출력 · 로그 · 결과 JSON 에 넣지 않습니다. 비밀값은 환경 변수(PGPASSWORD)로만 전달합니다.

# 진행 로그는 표준 오류로 보냅니다. 표준 출력은 결과 JSON 한 덩어리만 싣습니다 (kubectl logs 로 그대로 파일에 담기 위함).
log() { printf '[%s] %s\n' "${LOG_PREFIX:-data}" "$*" >&2; }

# 종료 코드와 이유를 한 줄 JSON 으로 남기고 끝냅니다. 원인 문자열에 비밀값을 넣지 않습니다.
die() {
  local code="$1"
  shift
  printf '{"result":"FAILED","reason":"%s","exit_code":%s}\n' "$(json_escape "$*")" "$code"
  exit "$code"
}

# JSON 문자열 안에서 위험한 문자를 바꿉니다 (jq 없이도 쓸 수 있는 최소 버전).
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' | tr -d '\n'; }

# 필요한 명령이 모두 있는지 먼저 확인합니다. 없으면 이유를 분명히 하고 멈춥니다.
require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" > /dev/null 2>&1 || die 2 "required tool not found: $tool"
  done
}

# 환경 변수가 비어 있지 않은지 확인합니다.
require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || die 2 "required environment variable not set: $name"
  done
}

load_contract_env() {
  local file="$1" prefix="$2"
  [ -f "$file" ] || die 2 "contract file not found: $file"
  grep -qE "^${prefix}_" "$file" || die 2 "not a ${prefix} contract file: $file"
  # shellcheck disable=SC1090
  set -a && . "$file" && set +a
}

# 실행 신원이 승인한 Role 인지 확인합니다. Pod Identity 는 assumed-role 형태로 나타납니다.
assert_caller_role() {
  local expected_role_arn="$1" caller_arn role_name
  caller_arn="$(aws sts get-caller-identity --query Arn --output text)" || die 2 "cannot read the caller identity (is the Pod Identity association in place?)"
  role_name="${expected_role_arn##*/}"
  case "$caller_arn" in
    *":assumed-role/${role_name}/"*) log "caller identity matches ${role_name}" ;;
    *) die 2 "caller is not the approved operator role (expected ${role_name})" ;;
  esac
}

# UUID 형식 검사입니다 (초기화 작업 ID). 값은 공개값이며 비밀값이 아닙니다.
assert_uuid() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    *) die 2 "run id must be a lower case UUID: $1" ;;
  esac
}

# 시크릿 하나를 읽어 지정한 필드 값만 표준 출력으로 돌려줍니다 (호출부는 값을 변수에 담고 로그에 남기지 않습니다).
secret_field() {
  local secret_id="$1" field="$2" stage="${3:-AWSCURRENT}"
  aws secretsmanager get-secret-value --secret-id "$secret_id" --version-stage "$stage" --query SecretString --output text 2> /dev/null |
    jq -er --arg field "$field" '.[$field]'
}

# psql 한 줄 조회입니다. 값이 없으면 빈 문자열이 나옵니다 (ON_ERROR_STOP 으로 SQL 오류는 즉시 실패).
psql_value() {
  psql --no-psqlrc -X -A -t -q -v ON_ERROR_STOP=1 -c "$1"
}

# 계정 비밀번호를 바꿉니다. SQL 을 -c 가 아니라 표준 입력으로 넣는 이유: psql 은 -c 로 받은 문자열에 :"role" · :'pw' 변수 치환을 하지 않고
# 서버로 그대로 보내므로 "syntax error at or near \":\"" 로 실패합니다(PostgreSQL 17 에서 실측). 표준 입력과 -f 는 치환을 거칩니다.
# 비밀번호는 -v 인자(프로세스 목록에 보임)가 아니라 환경 변수로 넘기고 psql 의 \getenv(PostgreSQL 15+)로 받습니다. :"role" 은 식별자로, :'pw' 는 문자열로 인용됩니다.
psql_set_role_password() { # 예: psql_set_role_password commerce_runtime "$password"
  printf '%s\n' '\getenv pw BOOTSTRAP_ROLE_PASSWORD' 'ALTER ROLE :"role" PASSWORD :'"'"'pw'"'"';' |
    BOOTSTRAP_ROLE_PASSWORD="$2" psql --no-psqlrc -X -q -v ON_ERROR_STOP=1 -v role="$1" > /dev/null
}

# psql 파일 실행입니다.
psql_file() {
  psql --no-psqlrc -X -q -v ON_ERROR_STOP=1 -f "$1" > /dev/null
}
