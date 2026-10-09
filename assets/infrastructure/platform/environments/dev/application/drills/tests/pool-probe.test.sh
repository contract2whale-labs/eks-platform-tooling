#!/usr/bin/env bash
# platform/environments/dev/application/drills/tests/pool-probe.test.sh — 연결 한도 실험 코드(drills/pool-probe.sh) 회귀 테스트 19개 (연결 고갈).
# 가짜 psql · aws(tests/fake) 로 판정 상태와 종료 코드, ALTER ROLE 호출 순서 · 횟수를 대조합니다. AWS · DB 접속 없음, 비밀은 공개 시험 값뿐.
# 컨테이너 PID 1 의 신호 전달 · 실제 이미지의 bash 는 이 시험이 대신하지 못합니다(Dev 의 Job 실행으로 확인).
# 실행: bash platform/environments/dev/application/drills/tests/pool-probe.test.sh — 마지막 "Ran 19 tests" · "OK" 가 정상.
set -euo pipefail
cd "$(dirname "$0")/.."
T_RUN=0; T_FAIL=0; T_NAME=""; T_OUT=""; T_CODE=0
T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pool-probe-test.XXXXXX")"
trap 'rm -rf "$T_TMP"' EXIT
t_begin() { T_NAME="$1"; T_RUN=$((T_RUN + 1)); T_CASE_FAILED=0; }
t_fail() { T_CASE_FAILED=1; printf 'FAIL: %s — %s\n' "$T_NAME" "$1" >&2; }
t_end() { if [ "$T_CASE_FAILED" = 1 ]; then T_FAIL=$((T_FAIL + 1)); printf '%s ... FAIL\n' "$T_NAME"; else printf '%s ... ok\n' "$T_NAME"; fi; }
t_exit() {
  expected="$1"; shift
  set +e
  T_OUT="$("$@" 2> "$T_TMP/stderr")"; T_CODE=$?
  set -e
  [ "$T_CODE" = "$expected" ] || t_fail "exit $T_CODE (expected $expected); stdout=$(printf '%s' "$T_OUT" | tail -2 | tr '\n' ' ')"
}
t_out_contains() { case "$T_OUT" in *"$1"*) ;; *) t_fail "stdout does not contain '$1'" ;; esac; }
t_summary() {
  printf -- '----------------------------------------------------------------------\nRan %d tests\n\n' "$T_RUN"
  if [ "$T_FAIL" = 0 ]; then printf 'OK\n'; exit 0; else printf 'FAILED (failures=%d)\n' "$T_FAIL"; exit 1; fi
}

export PATH="$PWD/tests/fake:$PATH"
# 실행 권한이나 PATH가 잘못되면 실제 aws/psql로 넘어가지 않고 시험을 중단합니다.
for tool in aws psql; do
  expected="$PWD/tests/fake/$tool"
  if [ ! -x "$expected" ] || [ "$(command -v "$tool" || true)" != "$expected" ]; then
    printf 'INCONCLUSIVE: executable local fake required: %s\n' "$expected" >&2
    exit 2
  fi
done
reset() { # 예: 케이스마다 새 DB 상태(한도 -1 · 세션 4 · max_connections 81)와 비밀 · 호출 기록
  rm -rf "$T_TMP/case"; mkdir -p "$T_TMP/case/pg" "$T_TMP/case/secrets"
  export FAKE_DIR="$T_TMP/case" FAKE_LOG="$T_TMP/case/calls.log"; : > "$FAKE_LOG"
  echo -1 > "$FAKE_DIR/pg/limit"; echo 4 > "$FAKE_DIR/pg/sessions"; echo 81 > "$FAKE_DIR/pg/max_connections"; echo 9 > "$FAKE_DIR/pg/total"
  printf '{"username":"postgres","password":"master-fixture-password"}' > "$FAKE_DIR/secrets/master.json"
  printf '{"username":"commerce_runtime","password":"runtime-fixture-password","redis_url":"rediss://cache.example:6379"}' > "$FAKE_DIR/secrets/runtime.json"
  for v in $(env | awk -F= '$1 ~ /^(FAKE_PG_[A-Z_]+|FAKE_SECRET_FAIL|MODE)$/ { print $1 }'); do unset "$v"; done
  export DATA_DB_ADDRESS=db.example DATA_DB_PORT=5432 DATA_DB_NAME=commercedb RDS_CA_BUNDLE="$T_TMP/ca.pem"
  export DATA_MASTER_SECRET_ARN=arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:master DATA_RUNTIME_SECRET_ARN=arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:runtime
  export CONTRACT_MAX_CONNECTIONS=81 BUDGET_POLICY_PERCENT=80 BUDGET_NEEDED=57 HOLD_SECONDS=0
}
probe() { t_exit "$1" bash pool-probe.sh; }
limit_now() { cat "$FAKE_DIR/pg/limit"; }
alters() { awk '/ALTER ROLE "commerce_runtime" CONNECTION LIMIT/ { n++ } END { print n+0 }' "$FAKE_LOG"; }
restores() { awk '/ALTER ROLE "commerce_runtime" CONNECTION LIMIT -1/ { n++ } END { print n+0 }' "$FAKE_LOG"; }
no_change() { [ "$(alters)" = 0 ] || t_fail "ALTER ROLE was called $(alters) times"; }

t_begin "test_valid_fault_is_verified_and_restored"
reset; probe 0; t_out_contains '"phase": "fault"'; t_out_contains "too many connections for role 'commerce_runtime'"
t_out_contains '"result": "PASS", "exit": 0, "injection_verified": true, "restored": true'
[ "$(limit_now)" = -1 ] || t_fail "limit $(limit_now)"; [ "$(restores)" = 1 ] || t_fail "restores $(restores)"
[ "$(grep -n 'CONNECTION LIMIT 4' "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n 'CONNECTION LIMIT -1' "$FAKE_LOG" | cut -d: -f1)" ] || t_fail "restore came before inject"; t_end

t_begin "test_unsupported_original_limit_stops_before_change"
reset; echo 5 > "$FAKE_DIR/pg/limit"; probe 2; t_out_contains 'PREFLIGHT_FAILED: original limit is 5'; no_change; [ "$(limit_now)" = 5 ] || t_fail "limit changed"; t_end

t_begin "test_non_numeric_limit_stops_before_change"
reset; export FAKE_PG_LIMIT_TEXT=abc; probe 2; t_out_contains 'role limit is not a number'; no_change; t_end

t_begin "test_missing_role_stops_before_change"
reset; export FAKE_PG_ROLE_MISSING=1; probe 2; t_out_contains 'does not exist'; no_change; t_end

t_begin "test_admin_login_failure_stops_before_change"
reset; export FAKE_PG_ADMIN_FAIL=1; probe 2; t_out_contains 'admin login failed'; no_change; t_end

t_begin "test_business_login_failure_stops_before_change"
reset; export FAKE_PG_ROLE_LOGIN_FAIL=1; probe 2; t_out_contains 'business login failed before the change'; no_change; t_end

t_begin "test_contract_mismatch_stops_before_change"
reset; echo 90 > "$FAKE_DIR/pg/max_connections"; probe 2; t_out_contains 'differs from the contract 81'; no_change; t_end

t_begin "test_budget_fail_stops_before_change"
reset; export BUDGET_NEEDED=70; probe 2; t_out_contains 'budget FAIL: needed 70 > budget 64'; no_change; t_end

t_begin "test_secret_read_failure_stops_before_change"
reset; export FAKE_SECRET_FAIL=1; probe 2; t_out_contains 'cannot read the master secret'; no_change; t_end

t_begin "test_inject_failure_is_reported_and_restored"
reset; export FAKE_PG_ALTER_FAIL=inject; probe 3; t_out_contains '"result": "INJECT_FAILED", "exit": 3'; t_out_contains '"restored": true'
[ "$(limit_now)" = -1 ] || t_fail "limit $(limit_now)"; t_end

t_begin "test_readback_mismatch_is_inject_failure"
reset; export FAKE_PG_READBACK_WRONG=1; probe 3; t_out_contains 'role limit read back differs from 4'; [ "$(limit_now)" = -1 ] || t_fail "not restored"; t_end

t_begin "test_login_still_succeeding_is_fault_invalid"
reset; export FAKE_PG_IGNORE_LIMIT=1; probe 5; t_out_contains '"result": "FAULT_INVALID", "exit": 5, "injection_verified": false, "restored": true'; t_end

t_begin "test_other_refusal_reason_is_fault_invalid"
reset; export FAKE_PG_REFUSE_REASON='password authentication failed for user "commerce_runtime"'; probe 5; t_out_contains 'refused for another reason'; t_out_contains '"restored": true'; t_end

t_begin "test_other_53300_message_is_fault_invalid"
reset; export FAKE_PG_REFUSE_REASON='too many connections for database "commercedb"'; probe 5; t_out_contains 'refused for another reason: too many connections for database'; t_end

t_begin "test_restore_failure_wins_over_other_results"
reset; export FAKE_PG_ALTER_FAIL=restore; probe 4; t_out_contains '"result": "RESTORE_FAILED", "exit": 4'; t_out_contains '"injection_verified": true, "restored": false'
reset; export FAKE_PG_LOGIN_FAIL_AFTER_RESTORE=1; probe 4; t_out_contains '"result": "RESTORE_FAILED"'; t_end

t_begin "test_term_during_hold_restores_once"
reset; export HOLD_SECONDS=30
bash pool-probe.sh > "$T_TMP/term.out" 2>&1 & pid=$!
for _ in $(seq 1 100); do grep -q '"phase": "fault"' "$T_TMP/term.out" 2> /dev/null && break; sleep 0.1; done
kill -TERM "$pid"; set +e; wait "$pid"; code=$?; set -e
[ "$code" = 143 ] || t_fail "exit $code (expected 143)"
grep -q '"result": "INTERRUPTED", "exit": 143, "injection_verified": true, "restored": true' "$T_TMP/term.out" || t_fail "verdict: $(tail -1 "$T_TMP/term.out")"
[ "$(limit_now)" = -1 ] || t_fail "limit $(limit_now)"; [ "$(restores)" = 1 ] || t_fail "restores $(restores)"; t_end

t_begin "test_manual_restore_mode"
reset; echo 3 > "$FAKE_DIR/pg/limit"; export MODE=restore; probe 0; t_out_contains '"phase": "restored"'; [ "$(limit_now)" = -1 ] || t_fail "limit $(limit_now)"; t_end

t_begin "test_measure_mode_reads_max_connections_without_change"
reset; for v in CONTRACT_MAX_CONNECTIONS BUDGET_POLICY_PERCENT BUDGET_NEEDED HOLD_SECONDS; do unset "$v"; done; export MODE=measure
probe 0; t_out_contains '"phase": "measure"'; t_out_contains '"max_connections": 81'; t_out_contains '"result": "PASS", "exit": 0, "injection_verified": false, "restored": false, "inject_attempted": false'
no_change; [ "$(limit_now)" = -1 ] || t_fail "limit $(limit_now)"; t_end

t_begin "test_unknown_mode_stops_before_change"
reset; export MODE=drlil; probe 2; t_out_contains 'unknown MODE drlil'; no_change; t_end

t_summary
