#!/usr/bin/env bash
# data/operator/bootstrap.sh — 데이터베이스 초기화 프로그램 (데이터베이스 초기화; 운영자 이미지 안에서 Job 으로 실행)
# 하는 일: 신원 확인 → 관리자 시크릿으로 TLS 접속 → 스키마 · 계정 · 권한(bootstrap.sql) → 앱 시크릿 2개를 "후보(AWSPENDING) → DB 반영 → 재접속 확인 → 현재(AWSCURRENT)" 순서로 채웁니다.
# 실행 계정 비밀에는 DB 자격 다섯 키에 더해 redis_url · jwt_secret · cookie_secret 를 함께 적습니다 — ExternalSecret 이 이 한 비밀에서 DATABASE_URL · REDIS_URL · JWT_SECRET · COOKIE_SECRET 를 만들기 때문입니다(애플리케이션 배포).
# 같은 BOOTSTRAP_RUN_ID 로 다시 실행하면 이미 끝난 시크릿은 현재 비밀번호의 로그인만 확인하고 건너뛰며, 중간에 끊긴 후보(첫 버전 · 승격 뒤 정리 전 포함)는 같은 비밀번호로 끝까지 이어서 씁니다. 다른 run id 의 후보가 남아 있으면 덮어쓰지 않고 멈춥니다 (종료 4). run id 를 읽을 수 없는 후보(JSON 이 아니거나 run_id 문자열이 없는 값 — 이 프로그램이 쓰지 않은 후보)도 다른 run 의 후보로 보고 멈춥니다 (종료 4). 단 이 run id 가 이미 현재 버전이면 그 후보는 그대로 두고 현재 비밀번호의 로그인만 확인합니다 (종료 0, 로그인 실패면 5).
# 시크릿의 AWSCURRENT · AWSPENDING 조회가 "그 단계 없음(ResourceNotFoundException)" 이 아닌 오류로 실패하면 후보가 없다고 보지 않고, 후보 저장 · 비밀번호 변경 전에 멈춥니다 (종료 4).
# 종료 코드: 0 완료 · 2 사전 조건(입력 · 신원 · 계정) · 3 DB 접속 · 4 비밀 조회 실패 · 발행 충돌 · 5 재접속 실패(새 비밀번호 · 끝난 run 의 현재 비밀번호).
# 표준 출력은 결과 JSON 한 덩어리뿐이며 비밀번호는 어디에도 남기지 않습니다.
set -euo pipefail

OPERATOR_HOME="${OPERATOR_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}" # 예: /opt/contract2whale/operator (이미지) 또는 저장소의 data/operator (로컬 테스트)
# shellcheck source=../lib/common.sh
. "${OPERATOR_LIB:-$OPERATOR_HOME/../lib/common.sh}"
LOG_PREFIX=bootstrap

require_tools aws jq psql
require_env BOOTSTRAP_RUN_ID EXPECTED_OPERATOR_ROLE_ARN DATA_ENVIRONMENT DATA_ACCOUNT_ID DATA_REGION \
  DATA_DB_ADDRESS DATA_DB_PORT DATA_DB_NAME DATA_DB_SCHEMA DATA_DB_ENGINE_VERSION \
  DATA_REDIS_ADDRESS DATA_REDIS_PORT \
  DATA_MASTER_SECRET_ARN DATA_MIGRATION_SECRET_ARN DATA_RUNTIME_SECRET_ARN DATA_APP_SECRET_ARN
assert_uuid "$BOOTSTRAP_RUN_ID"

MIGRATION_ROLE="${DATA_DB_MIGRATION_ROLE:-commerce_migrator}" # 예: commerce_migrator (스키마 변경 계정)
RUNTIME_ROLE="${DATA_DB_RUNTIME_ROLE:-commerce_runtime}"      # 예: commerce_runtime (앱 실행 계정)
CA_BUNDLE="${RDS_CA_BUNDLE:-/opt/contract2whale/certs/rds-global-bundle.pem}" # 예: 이미지에 넣은 RDS 전역 CA 묶음

# 앱이 붙을 캐시 주소도 실행 계정 비밀에 함께 넣습니다. 서버리스 ElastiCache 는 전송 구간 암호화를 끌 수 없어 계약이 DATA_REDIS_TLS=true 를 주며, 그때는 redis:// 가 열리지 않습니다.
case "${DATA_REDIS_SCHEME:-}" in
  redis | rediss) REDIS_SCHEME="$DATA_REDIS_SCHEME" ;;                                 # 예: 계약이 직접 지정하면 그 값
  "") [ "${DATA_REDIS_TLS:-}" = true ] && REDIS_SCHEME=rediss || REDIS_SCHEME=redis ;; # 예: DATA_REDIS_TLS=true → rediss (modules/data 가 내보내는 줄)
  *) die 2 "DATA_REDIS_SCHEME must be redis or rediss: ${DATA_REDIS_SCHEME}" ;;
esac
REDIS_URL="${REDIS_SCHEME}://${DATA_REDIS_ADDRESS}:${DATA_REDIS_PORT}" # 예: rediss://contract2whale-dev-eks-data-redis-….serverless.apn2.cache.amazonaws.com:6379

# 1. 누가 실행하는지 먼저 확인합니다. 승인한 운영자 Role 이 아니면 DB 에 닿기 전에 멈춥니다.
assert_caller_role "$EXPECTED_OPERATOR_ROLE_ARN"
caller_account="$(aws sts get-caller-identity --query Account --output text)"
[ "$caller_account" = "$DATA_ACCOUNT_ID" ] || die 2 "caller account does not match the data contract account"

# 2. 관리자 시크릿은 RDS 가 관리하는 Secret 에서 읽습니다. 값은 환경 변수로만 psql 에 전달합니다. 앱 서명 키 두 개는 별도 비밀에서 읽기만 합니다 (이 Job 이 만들지 않습니다).
master_user="$(secret_field "$DATA_MASTER_SECRET_ARN" username)" || die 3 "cannot read the master secret username"
master_password="$(secret_field "$DATA_MASTER_SECRET_ARN" password)" || die 3 "cannot read the master secret password"
app_jwt_secret="$(secret_field "$DATA_APP_SECRET_ARN" jwt_secret)" || die 3 "cannot read jwt_secret from the application secret"
app_cookie_secret="$(secret_field "$DATA_APP_SECRET_ARN" cookie_secret)" || die 3 "cannot read cookie_secret from the application secret"
[ -f "$CA_BUNDLE" ] || die 3 "RDS CA bundle not found: $CA_BUNDLE"

export PGHOST="$DATA_DB_ADDRESS" PGPORT="$DATA_DB_PORT" PGDATABASE="$DATA_DB_NAME" PGCONNECT_TIMEOUT=10
export PGSSLMODE=verify-full PGSSLROOTCERT="$CA_BUNDLE" # 예: 서버 인증서를 CA 로 검증하고 호스트 이름까지 대조 (평문 · 자체 서명 거부)
export PGUSER="$master_user" PGPASSWORD="$master_password"

# 3. 접속 · 버전 확인. 계약의 엔진 버전(major.minor)과 서버가 말하는 버전이 같아야 합니다.
psql_value 'SELECT 1' > /dev/null 2>&1 || die 3 "cannot connect to ${DATA_DB_ADDRESS}:${DATA_DB_PORT}/${DATA_DB_NAME} as the master user over TLS"
server_version="$(psql_value 'SHOW server_version' | awk '{print $1}')"
case "$server_version" in
  "$DATA_DB_ENGINE_VERSION") log "server version ${server_version} matches contract ${DATA_DB_ENGINE_VERSION}" ;;
  *) die 3 "server version ${server_version} does not match the data contract engine version ${DATA_DB_ENGINE_VERSION}" ;;
esac
tls_in_use="$(psql_value 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()')"
[ "$tls_in_use" = "t" ] || die 3 "the session is not using TLS"

# 4. 스키마 · 계정 · 권한. 여러 번 실행해도 같은 결과입니다 (bootstrap.sql).
psql --no-psqlrc -X -q -v ON_ERROR_STOP=1 \
  -v migration_role="$MIGRATION_ROLE" -v runtime_role="$RUNTIME_ROLE" \
  -v schema_name="$DATA_DB_SCHEMA" -v database_name="$DATA_DB_NAME" \
  -f "$OPERATOR_HOME/bootstrap.sql" > /dev/null || die 3 "bootstrap.sql failed"
log "schema ${DATA_DB_SCHEMA} and roles ${MIGRATION_ROLE}/${RUNTIME_ROLE} are in place"

# 시크릿 하나의 지정 단계(AWSCURRENT · AWSPENDING) 버전을 JSON 한 줄로 읽습니다. 그 단계가 붙은 버전이 없을 때(ResourceNotFoundException)만 빈 출력입니다.
# 권한 · 호출 제한 · 네트워크 같은 그 밖의 조회 오류는 상태 1 이고, 호출한 쪽이 종료 4 로 멈춥니다. 이 오류를 "후보 없음"으로 세면
# 새 후보를 저장하는 호출이 다른 run 의 AWSPENDING 표식을 새 버전으로 옮겨 버립니다 (Secrets Manager 는 다른 버전에 붙은 단계 표식을 새 버전으로 옮김).
stage_json() {
  local out
  if out="$(aws secretsmanager get-secret-value --secret-id "$1" --version-stage "$2" --output json 2>&1)"; then
    printf '%s' "$out" | jq -ce 'select(type == "object" and has("VersionId"))' 2> /dev/null && return 0
    log "unexpected answer while reading the $2 version" # 예: 표준 오류의 경고가 섞인 출력 — 값은 로그에 남기지 않음
    return 1
  fi
  case "$out" in
    *"(ResourceNotFoundException)"*) return 0 ;; # 예: 그 단계가 붙은 버전이 없음 → 빈 출력
  esac
  log "cannot read the $2 version: $(printf '%s\n' "$out" | sed -n 1p)" # 예: AccessDeniedException · ThrottlingException (오류 문장에는 비밀값이 없음)
  return 1
}

# 지정 단계 버전의 run_id 필드와 VersionId 입니다. 그 단계가 없으면 빈 문자열, 조회 오류는 상태 1 입니다.
# 버전은 있는데 run_id 를 읽을 수 없으면(SecretString 이 JSON 이 아니거나 run_id 문자열이 없음) ?unreadable 을 돌려줍니다. 빈 문자열로 돌려주면
# 호출한 쪽이 "후보 없음"으로 보고 새 후보를 저장해, 그 버전에 붙은 AWSPENDING 표식이 새 버전으로 옮겨 갑니다.
stage_run_id() {
  local found run
  found="$(stage_json "$1" "$2")" || return 1
  [ -n "$found" ] || return 0 # 예: 그 단계가 붙은 버전이 없음 → 빈 출력
  run="$(printf '%s' "$found" | jq -r '.SecretString // empty | fromjson? | .run_id // empty | strings' 2> /dev/null)"
  printf '%s' "${run:-?unreadable}" # 예: 평문 문자열 · run_id 없는 JSON · SecretBinary 버전 → ?unreadable
}

stage_version_id() {
  local found
  found="$(stage_json "$1" "$2")" || return 1
  printf '%s' "$found" | jq -r '.VersionId // empty'
}

# 5. 앱 비밀 하나를 채우는 단계입니다: 후보 만들기(또는 이어 쓰기) → DB 반영 → 새 비밀번호로 재접속 → 현재 버전으로 승격 → 후보 표식 정리. 결과는 PUBLISH_OUTCOME 에 남깁니다 (서브셸이 아니어야 die 가 프로그램을 끝냅니다).
#    비밀의 첫 버전에는 저장할 때 AWSCURRENT 가 자동으로 함께 붙습니다(Secrets Manager 규칙). 그래서 "현재 버전 = 이 run id" 만 보고 끝났다고 판단하지 않고, 이 run id 의 후보 표식이 남아 있는지를 먼저 봅니다.
publish_credentials() {
  local key="$1" secret_arn="$2" role="$3" extra="$4" pending_run current_run password pending_version current_version
  PUBLISH_OUTCOME=""
  current_run="$(stage_run_id "$secret_arn" AWSCURRENT)" || die 4 "${key}: cannot read the AWSCURRENT version; stopped before writing anything"
  pending_run="$(stage_run_id "$secret_arn" AWSPENDING)" || die 4 "${key}: cannot read the AWSPENDING version; stopped before writing anything"

  if [ "$pending_run" = "$BOOTSTRAP_RUN_ID" ]; then
    # 이 run id 의 후보가 남아 있습니다: DB 반영 · 재접속 · 승격 · 정리 중 어디서 끊겼든 같은 비밀번호로 끝까지 다시 합니다 (각 단계는 반복해도 결과가 같습니다).
    log "${key}: reusing the AWSPENDING candidate of run id ${BOOTSTRAP_RUN_ID}"
    password="$(secret_field "$secret_arn" password AWSPENDING)" || die 4 "${key}: cannot read the pending candidate"
    PUBLISH_OUTCOME=reused_pending
  elif [ "$current_run" = "$BOOTSTRAP_RUN_ID" ]; then
    # 이미 끝난 run id 입니다: 현재 비밀번호로 실제 로그인이 되는지만 확인하고 아무것도 바꾸지 않습니다. 다른 run id 의 후보나 run id 를 읽을 수 없는 후보가 있어도 이 분기가 먼저라 그 후보는 건드리지 않습니다 (그 run id 로 끝내거나 정리).
    password="$(secret_field "$secret_arn" password)" || die 4 "${key}: cannot read the current version"
    PGUSER="$role" PGPASSWORD="$password" psql_value 'SELECT current_user' > /dev/null 2>&1 || die 5 "${key}: the AWSCURRENT password of run id ${BOOTSTRAP_RUN_ID} does not log in; publish again with a new run id"
    log "${key}: AWSCURRENT already carries run id ${BOOTSTRAP_RUN_ID} — nothing to do"
    PUBLISH_OUTCOME=already_current
    return 0
  elif [ "$pending_run" = '?unreadable' ]; then
    die 4 "${key}: an AWSPENDING candidate exists but its run id cannot be read (not written by this program); release that candidate first (never overwrite a candidate with a new id)"
  elif [ -n "$pending_run" ]; then
    die 4 "${key}: an AWSPENDING candidate from another run id exists; finish or release that run first (never overwrite a candidate with a new id)"
  else
    password="$(aws secretsmanager get-random-password --password-length 32 --exclude-punctuation --require-each-included-type --query RandomPassword --output text)" || die 4 "${key}: cannot generate a password"
    jq -cn --arg username "$role" --arg password "$password" --arg host "$DATA_DB_ADDRESS" --arg port "$DATA_DB_PORT" \
      --arg dbname "$DATA_DB_NAME" --arg run_id "$BOOTSTRAP_RUN_ID" --argjson extra "$extra" \
      '{engine: "postgres", username: $username, password: $password, host: $host, port: ($port | tonumber), dbname: $dbname, run_id: $run_id} + $extra' |
      aws secretsmanager put-secret-value --secret-id "$secret_arn" --client-request-token "$BOOTSTRAP_RUN_ID" \
        --version-stages AWSPENDING --secret-string file:///dev/stdin --query VersionId --output text > /dev/null ||
      die 4 "${key}: cannot store the AWSPENDING candidate"
    log "${key}: stored a new AWSPENDING candidate for run id ${BOOTSTRAP_RUN_ID}"
    PUBLISH_OUTCOME=promoted
  fi

  # DB 반영: 후보 비밀번호를 계정에 넣습니다. 실패해도 후보 버전은 남으므로 같은 run id 로 이어서 할 수 있습니다.
  psql_set_role_password "$role" "$password" || die 4 "${key}: ALTER ROLE failed" # 예: lib/common.sh — SQL 은 표준 입력, 비밀번호는 환경 변수 + \getenv

  # 재접속 확인: 새 계정 · 새 비밀번호로 실제 로그인이 되는지 봅니다. 여기서 실패하면 승격하지 않습니다.
  PGUSER="$role" PGPASSWORD="$password" psql_value 'SELECT current_user' > /dev/null 2>&1 || die 5 "${key}: login with the new password failed; the candidate stays AWSPENDING"

  # 승격: 후보 버전을 현재 버전으로 옮깁니다. 이전 현재 버전은 AWSPREVIOUS 로 밀려납니다.
  # 첫 버전이거나 승격 뒤 정리 전에 끊긴 재실행이면 후보가 이미 현재 버전이므로 옮기지 않습니다.
  pending_version="$(stage_version_id "$secret_arn" AWSPENDING)" || die 4 "${key}: cannot read the AWSPENDING version before promotion"
  [ -n "$pending_version" ] || die 4 "${key}: the AWSPENDING version disappeared before promotion"
  current_version="$(stage_version_id "$secret_arn" AWSCURRENT)" || die 4 "${key}: cannot read the AWSCURRENT version before promotion"
  if [ "$current_version" = "$pending_version" ]; then
    log "${key}: the candidate is already AWSCURRENT (first version or resumed after promotion)"
  elif [ -n "$current_version" ]; then
    aws secretsmanager update-secret-version-stage --secret-id "$secret_arn" --version-stage AWSCURRENT \
      --move-to-version-id "$pending_version" --remove-from-version-id "$current_version" > /dev/null || die 4 "${key}: cannot promote the candidate"
  else
    aws secretsmanager update-secret-version-stage --secret-id "$secret_arn" --version-stage AWSCURRENT \
      --move-to-version-id "$pending_version" > /dev/null || die 4 "${key}: cannot promote the candidate"
  fi
  # 정리: 후보 표식을 뗍니다. 표식이 남으면 다음 run id 가 "다른 run 의 후보"로 보고 멈추므로, 같은 run id 로 다시 실행해 이 단계까지 끝냅니다.
  aws secretsmanager update-secret-version-stage --secret-id "$secret_arn" --version-stage AWSPENDING \
    --remove-from-version-id "$pending_version" > /dev/null || die 4 "${key}: cannot clear the AWSPENDING label"
  log "${key}: promoted run id ${BOOTSTRAP_RUN_ID} to AWSCURRENT"
}

# 실행 계정 비밀에만 더하는 3키입니다 — 앱과 마이그레이션 Job 이 같은 캐시 · 같은 서명 키를 쓰도록 한 비밀에 모읍니다. 스키마 변경 계정 비밀은 DB 자격 다섯 키만 담습니다.
runtime_extra="$(jq -cn --arg redis_url "$REDIS_URL" --arg jwt_secret "$app_jwt_secret" --arg cookie_secret "$app_cookie_secret" \
  '{redis_url: $redis_url, jwt_secret: $jwt_secret, cookie_secret: $cookie_secret}')"
publish_credentials migration "$DATA_MIGRATION_SECRET_ARN" "$MIGRATION_ROLE" '{}'
migration_outcome="$PUBLISH_OUTCOME"
publish_credentials runtime "$DATA_RUNTIME_SECRET_ARN" "$RUNTIME_ROLE" "$runtime_extra"
runtime_outcome="$PUBLISH_OUTCOME"

# 6. 결과 JSON. 완료 = 두 계정 모두 현재 버전으로 접속할 수 있는 상태입니다. 비밀번호는 없습니다.
jq -cn --arg environment "$DATA_ENVIRONMENT" --arg run_id "$BOOTSTRAP_RUN_ID" --arg database "$DATA_DB_NAME" \
  --arg schema "$DATA_DB_SCHEMA" --arg version "$server_version" \
  --arg migration_role "$MIGRATION_ROLE" --arg runtime_role "$RUNTIME_ROLE" \
  --arg migration_outcome "$migration_outcome" --arg runtime_outcome "$runtime_outcome" \
  '{result: "BOOTSTRAP_COMPLETE", environment: $environment, run_id: $run_id, database: $database, schema: $schema,
    server_version: $version, tls: true,
    roles: {migration: $migration_role, runtime: $runtime_role},
    secrets: {migration: $migration_outcome, runtime: $runtime_outcome}}'
