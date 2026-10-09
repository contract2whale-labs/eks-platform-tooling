#!/usr/bin/env bash
# 실행: bash data/tests/operator.test.sh — 마지막 "Ran 27 tests" · "OK" 가 정상.
set -euo pipefail
cd "$(dirname "$0")/../.."
. data/tests/lib.sh
# mock 전용 CLI가 실행 가능하지 않으면 시스템 AWS/psql로 넘어가지 않습니다.
for fake in aws psql; do
  [ -x "$PWD/data/tests/fake/$fake" ] || { printf 'Mock CLI is not executable: %s\n' "$fake" >&2; exit 2; }
done
export PATH="$PWD/data/tests/fake:$PATH"
hash -r
for fake in aws psql; do
  [ "$(command -v "$fake")" = "$PWD/data/tests/fake/$fake" ] || { printf 'Mock CLI resolution mismatch: %s\n' "$fake" >&2; exit 2; }
done
# These settings affect this test process only; never read existing user credentials.
: > "$T_TMP/empty-aws-config"
: > "$T_TMP/empty-aws-credentials"
export AWS_CONFIG_FILE="$T_TMP/empty-aws-config" AWS_SHARED_CREDENTIALS_FILE="$T_TMP/empty-aws-credentials"
export AWS_EC2_METADATA_DISABLED=true AWS_SDK_LOAD_CONFIG=0
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
unset AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI
unset AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE

RUN_A=0f1e2d3c-4b5a-4678-9abc-def012345678 # 예: 초기화 작업 ID (공개값)
RUN_B=11111111-2222-4333-8444-555555555555 # 예: 다른 작업 ID
export EXPECTED_OPERATOR_ROLE_ARN=arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-app-database-operator
export RDS_CA_BUNDLE="$T_TMP/rds-ca.pem"; printf 'fixture ca\n' > "$RDS_CA_BUNDLE"
export DATA_DB_MIGRATION_ROLE=commerce_migrator DATA_DB_RUNTIME_ROLE=commerce_runtime

load_fixture() { set -a; . data/fixtures/dev.data-contract.env; set +a; } # 예: 계약 env 를 환경 변수로
seed_master() { # 예: RDS 관리 Secret 의 현재 버전
  local d="$FAKE_DIR/secrets/$(basename "$DATA_MASTER_SECRET_ARN")"; mkdir -p "$d"
  printf '{"username":"postgres","password":"master-fixture-password","engine":"postgres"}' > "$d/m1.json"; printf m1 > "$d/AWSCURRENT"
}
seed_app() { # 예: 앱 비밀(JWT · 쿠키 서명 키) — 이 Job 은 읽기만 하고 쓰지 않습니다
  local d="$FAKE_DIR/secrets/$(basename "$DATA_APP_SECRET_ARN")"; mkdir -p "$d"
  printf '{"jwt_secret":"jwt-fixture-value","cookie_secret":"cookie-fixture-value"}' > "$d/a1.json"; printf a1 > "$d/AWSCURRENT"
}
seed_stage() { # 예: seed_stage <secret arn> <stage> <version id> <run id> — 앱 시크릿에 후보 · 현재 버전을 미리 둠
  local d="$FAKE_DIR/secrets/$(basename "$1")"; mkdir -p "$d"
  jq -cn --arg u task --arg p "seeded-$3" --arg r "$4" '{username: $u, password: $p, run_id: $r}' > "$d/$3.json"; printf '%s' "$3" > "$d/$2"
  printf '%s' "seeded-$3" > "$FAKE_DIR/pg/passwords/commerce_migrator"; printf '%s' "seeded-$3" > "$FAKE_DIR/pg/passwords/commerce_runtime"
}
seed_pending_only() { # 예: seed_pending_only <secret arn> <version id> <run id> — 후보(AWSPENDING) 버전만 둠 (DB 비밀번호는 그대로)
  local d="$FAKE_DIR/secrets/$(basename "$1")"; mkdir -p "$d"
  jq -cn --arg p "pending-$2" --arg r "$3" '{username: "task", password: $p, run_id: $r}' > "$d/$2.json"; printf '%s' "$2" > "$d/AWSPENDING"
}
seed_pending_raw() { # 예: seed_pending_raw <secret arn> <version id> <SecretString 원문> — 이 프로그램이 쓰지 않은 후보(JSON 이 아님 · run_id 없음)
  local d="$FAKE_DIR/secrets/$(basename "$1")"; mkdir -p "$d"
  printf '%s' "$3" > "$d/$2.json"; printf '%s' "$2" > "$d/AWSPENDING"
}
reset() { # 예: 케이스마다 새 작업 폴더 · 호출 기록 · 기본 fake 상태
  rm -rf "$T_TMP/case"; mkdir -p "$T_TMP/case/pg/passwords"; export FAKE_DIR="$T_TMP/case" FAKE_LOG="$T_TMP/case/calls.log"
  unset FAKE_CALLER_ARN FAKE_CALLER_ACCOUNT FAKE_PG_UNREACHABLE FAKE_PG_VERSION FAKE_PG_SSL FAKE_PG_READ_ONLY FAKE_PG_REJECT_APP_LOGIN FAKE_PG_OBJECTS_EXIST FAKE_SECRET_PUT_FAIL FAKE_PG_SQL_FAIL FAKE_STAGE_CLEAR_FAIL FAKE_SECRET_READ_FAIL 2> /dev/null || true
  load_fixture; export BOOTSTRAP_RUN_ID="$RUN_A"; : > "$FAKE_LOG"; seed_master; seed_app
}
bootstrap() { t_exit "$1" bash data/operator/bootstrap.sh; }
check() { t_exit "$1" bash data/operator/operator-check.sh; }
stage_of() { cat "$FAKE_DIR/secrets/$(basename "$1")/$2" 2> /dev/null || printf none; }

# --- 초기화 (데이터베이스 초기화) ---
t_begin "test_bootstrap_rejects_missing_run_id"
reset; unset BOOTSTRAP_RUN_ID; bootstrap 2; t_out_contains 'BOOTSTRAP_RUN_ID'; t_file_lacks "$FAKE_LOG" 'psql'; t_end

t_begin "test_bootstrap_rejects_malformed_run_id"
reset; export BOOTSTRAP_RUN_ID=not-a-uuid; bootstrap 2; t_out_contains 'lower case UUID'; t_file_lacks "$FAKE_LOG" 'sts get-caller-identity'; t_end

t_begin "test_bootstrap_rejects_wrong_caller_role"
reset; export FAKE_CALLER_ARN=arn:aws:sts::111111111111:assumed-role/contract2whale-dev-eks-nodes/i-0123; bootstrap 2; t_out_contains 'not the approved operator role'; t_file_lacks "$FAKE_LOG" 'get-secret-value'; t_end

t_begin "test_bootstrap_rejects_account_mismatch"
reset; export FAKE_CALLER_ACCOUNT=222222222222; bootstrap 2; t_out_contains 'caller account does not match'; t_file_lacks "$FAKE_LOG" 'psql'; t_end

t_begin "test_bootstrap_fails_before_any_secret_write_when_database_unreachable"
reset; export FAKE_PG_UNREACHABLE=1; bootstrap 3; t_out_contains 'cannot connect'; t_file_lacks "$FAKE_LOG" 'put-secret-value'; t_end

t_begin "test_bootstrap_rejects_engine_version_mismatch"
reset; export FAKE_PG_VERSION=16.4; bootstrap 3; t_out_contains 'does not match the data contract engine version'; t_file_lacks "$FAKE_LOG" 'bootstrap.sql'; t_end

t_begin "test_bootstrap_uses_verify_full_tls_for_every_session"
reset; bootstrap 0
[ "$(grep -c 'sslmode=verify-full' "$FAKE_LOG")" = "$(grep -c '^psql' "$FAKE_LOG")" ] || t_fail "some psql sessions did not use verify-full: $(grep '^psql' "$FAKE_LOG" | grep -vc verify-full)"
t_end

t_begin "test_bootstrap_passes_schema_and_roles_to_sql_file"
reset; bootstrap 0; t_file_contains "$FAKE_LOG" 'bootstrap.sql'; t_file_contains "$FAKE_LOG" 'schema_name=public'; t_file_contains "$FAKE_LOG" 'migration_role=commerce_migrator'; t_end

t_begin "test_fresh_run_stores_pending_applies_verifies_then_promotes"
reset; bootstrap 0; t_json .result BOOTSTRAP_COMPLETE; t_json .secrets.migration promoted; t_json .secrets.runtime promoted
# 예: 비밀의 첫 버전은 저장할 때 AWSCURRENT 가 자동으로 붙으므로(Secrets Manager 규칙) 승격은 후보 표식 정리(release)로 끝나고 AWSCURRENT 이동은 없습니다
seq="$(grep -E 'put-secret-value|ALTER ROLE|user=commerce_migrator .*current_user|AWSCURRENT --move-to|AWSPENDING --remove-from' "$FAKE_LOG" | sed -n 1,4p | awk '{if ($0 ~ /put-secret-value/) print "pending"; else if ($0 ~ /ALTER ROLE/) print "alter"; else if ($0 ~ /current_user/) print "verify"; else if ($0 ~ /AWSPENDING --remove-from/) print "release"; else print "promote"}' | tr '\n' ' ')"
[ "$seq" = "pending alter verify release " ] || t_fail "order was: $seq"
t_file_lacks "$FAKE_LOG" 'AWSCURRENT --move-to'
[ "$(stage_of "$DATA_RUNTIME_SECRET_ARN" AWSCURRENT)" = "$RUN_A" ] || t_fail "runtime AWSCURRENT is not run A"
[ "$(stage_of "$DATA_RUNTIME_SECRET_ARN" AWSPENDING)" = none ] || t_fail "AWSPENDING label was not cleared"
t_end

t_begin "test_rerun_with_same_run_id_changes_nothing"
reset; bootstrap 0; : > "$FAKE_LOG"; bootstrap 0; t_json .secrets.migration already_current; t_json .secrets.runtime already_current
t_file_lacks "$FAKE_LOG" 'put-secret-value'; t_file_lacks "$FAKE_LOG" 'ALTER ROLE'; t_end

t_begin "test_interrupted_run_reuses_its_pending_candidate"
reset; seed_stage "$DATA_MIGRATION_SECRET_ARN" AWSPENDING p1 "$RUN_A"; bootstrap 0; t_json .secrets.migration reused_pending; t_json .secrets.runtime promoted
[ "$(grep -c 'put-secret-value' "$FAKE_LOG")" = 1 ] || t_fail "expected exactly one new candidate (runtime), got $(grep -c 'put-secret-value' "$FAKE_LOG")"
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSCURRENT)" = p1 ] || t_fail "migration candidate p1 was not promoted"
t_end

t_begin "test_pending_candidate_of_another_run_id_is_never_overwritten"
reset; seed_stage "$DATA_MIGRATION_SECRET_ARN" AWSPENDING p9 "$RUN_B"; bootstrap 4; t_out_contains 'another run id'
t_file_lacks "$FAKE_LOG" 'ALTER ROLE'; t_file_lacks "$FAKE_LOG" 'put-secret-value'; [ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = p9 ] || t_fail "candidate p9 was touched"; t_end

t_begin "test_unreadable_pending_candidate_is_never_overwritten"
# 예: AWSPENDING 버전의 값이 JSON 이 아님 — "후보 없음"으로 세면 새 후보 저장이 그 버전의 AWSPENDING 표식을 가져가므로 쓰기 전에 종료 4
reset; seed_pending_raw "$DATA_MIGRATION_SECRET_ARN" p9 'plain-text-candidate'; bootstrap 4; t_out_contains 'run id cannot be read'
t_file_lacks "$FAKE_LOG" 'get-random-password'; t_file_lacks "$FAKE_LOG" 'put-secret-value'; t_file_lacks "$FAKE_LOG" 'ALTER ROLE'
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = p9 ] || t_fail "the unreadable candidate p9 lost its AWSPENDING label"; t_end

t_begin "test_pending_candidate_without_run_id_is_never_overwritten"
# 예: JSON 이지만 run_id 문자열이 없는 후보 — 다른 run 의 후보와 같이 멈춥니다
reset; seed_pending_raw "$DATA_MIGRATION_SECRET_ARN" p9 '{"username":"task","password":"pending-p9"}'; bootstrap 4; t_out_contains 'run id cannot be read'
t_file_lacks "$FAKE_LOG" 'put-secret-value'; t_file_lacks "$FAKE_LOG" 'ALTER ROLE'
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = p9 ] || t_fail "the candidate p9 without run_id lost its AWSPENDING label"; t_end

t_begin "test_secret_lookup_error_is_not_a_missing_candidate"
# 예: 다른 run 의 후보 p9 가 있는데 AWSPENDING 조회가 권한 오류로 실패 — "없음"으로 세면 새 후보 저장이 p9 의 표식을 가져가므로 쓰기 전에 종료 4
reset; seed_pending_only "$DATA_MIGRATION_SECRET_ARN" p9 "$RUN_B"; export FAKE_SECRET_READ_FAIL=AWSPENDING; bootstrap 4; t_out_contains 'cannot read the AWSPENDING version'
t_file_contains "$T_TMP/stderr" 'AccessDeniedException'; t_file_lacks "$FAKE_LOG" 'get-random-password'; t_file_lacks "$FAKE_LOG" 'put-secret-value'; t_file_lacks "$FAKE_LOG" 'ALTER ROLE'
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = p9 ] || t_fail "the other run candidate p9 lost its AWSPENDING label"; t_end

t_begin "test_finished_run_keeps_another_run_candidate_and_only_checks_login"
reset; bootstrap 0; seed_pending_only "$DATA_MIGRATION_SECRET_ARN" p9 "$RUN_B"; : > "$FAKE_LOG"; bootstrap 0; t_json .secrets.migration already_current
t_file_lacks "$FAKE_LOG" 'put-secret-value'; t_file_lacks "$FAKE_LOG" 'ALTER ROLE'; t_file_lacks "$FAKE_LOG" 'update-secret-version-stage'; t_file_contains "$FAKE_LOG" 'user=commerce_migrator'
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = p9 ] && [ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSCURRENT)" = "$RUN_A" ] || t_fail "the finished run changed the stages or the other run candidate p9"; t_end

t_begin "test_finished_run_keeps_an_unreadable_candidate_and_only_checks_login"
# 예: 이미 끝난 비밀에 이 프로그램이 쓰지 않은 후보(값이 JSON 이 아님)가 붙어 있음 — 끝난 run id 분기가 먼저라 로그인만 확인하고 그 후보 · 표식은 그대로 둡니다
reset; bootstrap 0; seed_pending_raw "$DATA_MIGRATION_SECRET_ARN" p9 'plain-text-candidate'; : > "$FAKE_LOG"; bootstrap 0; t_json .secrets.migration already_current
t_file_lacks "$FAKE_LOG" 'put-secret-value'; t_file_lacks "$FAKE_LOG" 'ALTER ROLE'; t_file_lacks "$FAKE_LOG" 'update-secret-version-stage'; t_file_contains "$FAKE_LOG" 'user=commerce_migrator'
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = p9 ] && [ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSCURRENT)" = "$RUN_A" ] || t_fail "the finished run changed the stages or the unreadable candidate p9"; t_end

t_begin "test_login_failure_keeps_candidate_pending_and_does_not_promote"
reset; export FAKE_PG_REJECT_APP_LOGIN=1; bootstrap 5; t_out_contains 'candidate stays AWSPENDING'
t_file_lacks "$FAKE_LOG" 'AWSCURRENT --move-to'; [ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = "$RUN_A" ] || t_fail "candidate is not pending"; t_end

t_begin "test_first_version_resume_after_login_failure_finishes_same_run"
reset; export FAKE_PG_REJECT_APP_LOGIN=1; bootstrap 5
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSCURRENT)" = "$RUN_A" ] || t_fail "the first version should also carry AWSCURRENT"
unset FAKE_PG_REJECT_APP_LOGIN; : > "$FAKE_LOG"; bootstrap 0; t_json .secrets.migration reused_pending; t_json .secrets.runtime promoted
t_file_lacks "$FAKE_LOG" "put-secret-value --secret-id $DATA_MIGRATION_SECRET_ARN"
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = none ] || t_fail "AWSPENDING label was not cleared"
[ "$(cat "$FAKE_DIR/pg/passwords/commerce_migrator")" = "$(jq -r .password "$FAKE_DIR/secrets/$(basename "$DATA_MIGRATION_SECRET_ARN")/$RUN_A.json")" ] || t_fail "the database password differs from AWSCURRENT"
t_end

t_begin "test_resume_after_promotion_clears_pending_without_moving_current_again"
reset; seed_stage "$DATA_MIGRATION_SECRET_ARN" AWSCURRENT c0 "$RUN_B"; export FAKE_STAGE_CLEAR_FAIL=1; bootstrap 4; t_out_contains 'cannot clear the AWSPENDING label'
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSCURRENT)" = "$RUN_A" ] && [ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = "$RUN_A" ] || t_fail "setup: expected a promoted candidate that still carries AWSPENDING"
unset FAKE_STAGE_CLEAR_FAIL; : > "$FAKE_LOG"; bootstrap 0; t_json .secrets.migration reused_pending
t_file_lacks "$FAKE_LOG" 'AWSCURRENT --move-to'
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPENDING)" = none ] || t_fail "AWSPENDING label was not cleared"
[ "$(stage_of "$DATA_MIGRATION_SECRET_ARN" AWSPREVIOUS)" = c0 ] || t_fail "AWSPREVIOUS no longer points to the old version c0"
t_end

t_begin "test_finished_run_whose_current_password_no_longer_logs_in_exits_5"
reset; bootstrap 0; printf 'changed-outside-the-program' > "$FAKE_DIR/pg/passwords/commerce_migrator"; : > "$FAKE_LOG"; bootstrap 5
t_out_contains 'does not log in'; t_file_lacks "$FAKE_LOG" 'put-secret-value'; t_file_lacks "$FAKE_LOG" 'ALTER ROLE'; t_end

t_begin "test_runtime_secret_carries_redis_url_and_signing_keys"
reset; bootstrap 0
runtime_json="$(cat "$FAKE_DIR/secrets/$(basename "$DATA_RUNTIME_SECRET_ARN")/$RUN_A.json")"
[ "$(printf '%s' "$runtime_json" | jq -r '.redis_url')" = "rediss://${DATA_REDIS_ADDRESS}:${DATA_REDIS_PORT}" ] || t_fail "runtime secret has no rediss:// address: $(printf '%s' "$runtime_json" | jq -r '.redis_url')"
[ "$(printf '%s' "$runtime_json" | jq -r '.jwt_secret + " " + .cookie_secret')" = "jwt-fixture-value cookie-fixture-value" ] || t_fail "runtime secret does not carry the application signing keys"
[ "$(printf '%s' "$runtime_json" | jq -r 'keys | length')" = 10 ] || t_fail "runtime secret has $(printf '%s' "$runtime_json" | jq -r 'keys | length') properties, expected 10 (contract 8 + engine + run_id)"
migration_json="$(cat "$FAKE_DIR/secrets/$(basename "$DATA_MIGRATION_SECRET_ARN")/$RUN_A.json")"
[ "$(printf '%s' "$migration_json" | jq -r 'has("redis_url")')" = false ] || t_fail "the migration secret must carry database credentials only"
t_end

t_begin "test_bootstrap_output_and_log_carry_no_password"
reset; export FAKE_RANDOM_PASSWORD=SuperSecretFixturePassword; bootstrap 0; t_out_lacks SuperSecretFixturePassword; t_out_lacks master-fixture-password
t_file_lacks "$T_TMP/stderr" 'SuperSecretFixturePassword'; t_file_lacks "$T_TMP/stderr" 'master-fixture-password'; t_file_lacks "$FAKE_LOG" 'SuperSecretFixturePassword'; t_end

# --- 진단 (데이터베이스 운영자 이미지와 읽기 전용 진단) ---
t_begin "test_check_passes_with_objects_missing_before_bootstrap"
reset; check 0; t_json .result PASS; t_json .scope LIVE_READ_ONLY_DATABASE_DIAGNOSTIC; t_json .bootstrap_objects.schema_app false; t_json .transaction_read_only true; t_json .tls true; t_end

t_begin "test_check_reports_objects_after_bootstrap"
reset; bootstrap 0; check 0; t_json .bootstrap_objects.schema_app true; t_json .bootstrap_objects.commerce_runtime true; t_json .engine_version_matches true
t_file_lacks "$FAKE_LOG" 'ALTER ROLE PASSWORD'; t_end

t_begin "test_check_fails_when_engine_version_differs"
reset; export FAKE_PG_VERSION=16.4; check 1; t_json .result FAIL; t_json .engine_version_matches false; t_end

t_begin "test_check_rejects_wrong_caller_role_before_connecting"
reset; export FAKE_CALLER_ARN=arn:aws:sts::111111111111:assumed-role/contract2whale-dev-eks-app-runtime/pod; check 2; t_file_lacks "$FAKE_LOG" 'psql'; t_end

t_summary
