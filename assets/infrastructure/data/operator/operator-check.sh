#!/usr/bin/env bash
# data/operator/operator-check.sh — 읽기 전용 데이터베이스 진단 (데이터베이스 운영자 이미지와 읽기 전용 진단; 운영자 이미지 안에서 Job 으로 실행)
# 확인하는 것: 실행 신원(운영자 Role · 계정) → 관리자 시크릿으로 TLS 접속 → 읽기 전용 세션 → 초기화 객체(스키마 · 계정 2)의 존재 → 엔진 버전 일치.
# 아무것도 바꾸지 않습니다 (default_transaction_read_only). 초기화 전에도 접속·TLS·버전이 맞으면 PASS일 수 있습니다. public schema는 이미 있을 수 있고 앱 계정 두 개는 별도로 확인합니다. 이 PASS만으로 앱 준비 완료를 판단하지 않습니다.
# 종료 코드: 0 PASS · 1 FAIL(버전 불일치 · TLS 아님) · 2 사전 조건(입력 · 신원 · 계정) · 3 DB 접속.
set -euo pipefail

OPERATOR_HOME="${OPERATOR_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/common.sh
. "${OPERATOR_LIB:-$OPERATOR_HOME/../lib/common.sh}"
LOG_PREFIX=operator-check

require_tools aws jq psql
require_env EXPECTED_OPERATOR_ROLE_ARN DATA_ENVIRONMENT DATA_ACCOUNT_ID DATA_REGION \
  DATA_DB_ADDRESS DATA_DB_PORT DATA_DB_NAME DATA_DB_SCHEMA DATA_DB_ENGINE_VERSION DATA_MASTER_SECRET_ARN

MIGRATION_ROLE="${DATA_DB_MIGRATION_ROLE:-commerce_migrator}"
RUNTIME_ROLE="${DATA_DB_RUNTIME_ROLE:-commerce_runtime}"
CA_BUNDLE="${RDS_CA_BUNDLE:-/opt/contract2whale/certs/rds-global-bundle.pem}"

# 1. 신원. 이미지 pull 실패 · Pod Identity 미연결 · 잘못된 Role 은 여기서 각각 다른 오류로 드러납니다.
assert_caller_role "$EXPECTED_OPERATOR_ROLE_ARN"
caller_account="$(aws sts get-caller-identity --query Account --output text)"
[ "$caller_account" = "$DATA_ACCOUNT_ID" ] || die 2 "caller account does not match the data contract account"

# 2. 접속. 관리자 시크릿은 읽기만 하고 값은 환경 변수로만 전달합니다.
master_user="$(secret_field "$DATA_MASTER_SECRET_ARN" username)" || die 3 "cannot read the master secret username"
master_password="$(secret_field "$DATA_MASTER_SECRET_ARN" password)" || die 3 "cannot read the master secret password"
[ -f "$CA_BUNDLE" ] || die 3 "RDS CA bundle not found: $CA_BUNDLE"
export PGHOST="$DATA_DB_ADDRESS" PGPORT="$DATA_DB_PORT" PGDATABASE="$DATA_DB_NAME" PGCONNECT_TIMEOUT=10
export PGSSLMODE=verify-full PGSSLROOTCERT="$CA_BUNDLE"
export PGUSER="$master_user" PGPASSWORD="$master_password"
export PGOPTIONS='-c default_transaction_read_only=on' # 예: 이 세션의 모든 트랜잭션을 읽기 전용으로 (실수로도 쓰지 못함)

psql_value 'SELECT 1' > /dev/null 2>&1 || die 3 "cannot connect to ${DATA_DB_ADDRESS}:${DATA_DB_PORT}/${DATA_DB_NAME} over TLS"

tls_in_use="$(psql_value 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()')"
read_only="$(psql_value 'SHOW transaction_read_only')"
server_version="$(psql_value 'SHOW server_version' | awk '{print $1}')"
schema_exists="$(psql_value "SELECT count(*) FROM pg_namespace WHERE nspname = '${DATA_DB_SCHEMA}'")"
migration_exists="$(psql_value "SELECT count(*) FROM pg_roles WHERE rolname = '${MIGRATION_ROLE}'")"
runtime_exists="$(psql_value "SELECT count(*) FROM pg_roles WHERE rolname = '${RUNTIME_ROLE}'")"

to_bool() { [ "${1:-0}" = "1" ] || [ "${1:-}" = "t" ] || [ "${1:-}" = "on" ] && printf true || printf false; }
version_matches=false
case "$server_version" in "$DATA_DB_ENGINE_VERSION") version_matches=true ;; esac

result=PASS
exit_code=0
if [ "$(to_bool "$tls_in_use")" != true ] || [ "$version_matches" != true ] || [ "$(to_bool "$read_only")" != true ]; then
  result=FAIL
  exit_code=1
fi

# 4. 결과 JSON (원본 진단 결과와 같은 필드). 비밀값 · 접속 URI 는 없습니다.
jq -cn --arg result "$result" --arg environment "$DATA_ENVIRONMENT" --arg database "$DATA_DB_NAME" --arg user "$master_user" \
  --argjson tls "$(to_bool "$tls_in_use")" --argjson read_only "$(to_bool "$read_only")" \
  --argjson schema "$(to_bool "$schema_exists")" --argjson migration "$(to_bool "$migration_exists")" --argjson runtime "$(to_bool "$runtime_exists")" \
  --argjson version_matches "$version_matches" --arg server_version "$server_version" --arg expected "$DATA_DB_ENGINE_VERSION" \
  '{result: $result, scope: "LIVE_READ_ONLY_DATABASE_DIAGNOSTIC", environment: $environment, database: $database, user: $user,
    tls: $tls, transaction_read_only: $read_only,
    bootstrap_objects: {schema_app: $schema, commerce_migrator: $migration, commerce_runtime: $runtime},
    engine_version_matches: $version_matches, server_version: $server_version, expected_engine_version: $expected}'
exit "$exit_code"
