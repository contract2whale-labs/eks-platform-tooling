#!/usr/bin/env bash
# platform/environments/dev/application/drills/pool-probe.sh
# 연결 고갈: 업무 DB 역할의 연결 한도를 그 순간의 세션 수로 낮춰 "새 접속 거부" 를 만들고, 판정한 뒤 원래 한도(-1)로 되돌리는 실험 코드입니다.
# Job(운영자 이미지 · ServiceAccount database-operator)이 ConfigMap 으로 받아 bash 로 실행합니다. 결과는 한 줄짜리 JSON 을 단계마다 stdout 에 씁니다(Job 로그 = 외부 기록).
# 판정과 종료 코드 (문서 · Job · 시험이 같은 번호를 씀):
#   0 PASS             유효한 장애(역할 한도 거부)를 확인했고 -1 로 복원 · 새 업무 로그인까지 확인
#   2 PREFLIGHT_FAILED 바꾸기 전에 멈춤 — ALTER ROLE 0회 (관리 · 업무 로그인, 역할, 숫자 한도, 원래 한도 -1, 계약 max_connections 대조, 예산)
#   3 INJECT_FAILED    한도 변경 · 재조회 실패 (복원은 시도하고 결과를 남김)
#   4 RESTORE_FAILED   복원 · 재조회 · 새 업무 로그인 실패 — 다른 판정보다 앞섭니다 (후속 조치: MODE=restore 로 다시 실행)
#   5 FAULT_INVALID    주입 뒤에도 접속 성공, 또는 역할 한도가 아닌 이유로 거부 (복원 결과를 남김)
#   128+n INTERRUPTED  TERM · INT 로 중단 (EXIT trap 이 복원을 한 번 시도)
# MODE=measure 는 바꾸지 않고 SHOW max_connections 만 재서 "measure" 줄로 남깁니다 (계약 contracts/<env>.env 의 DB_MAX_CONNECTIONS 를 채울 때, PASS 0 · 실패 2).
# MODE=restore 는 Job 이 중간에 끊겨 한도가 남았을 때 -1 로만 되돌립니다.
# 원복은 restore 함수 하나가 맡습니다(정상 경로 · MODE=restore 는 직접 호출, EXIT trap 은 주입을 시도했는데 복원이 끝나지 않았을 때만 호출, 성공 뒤 RESTORED=1 이 다시 하지 않게 막음). bash 는 foreground 명령이 끝나야 trap 을 돌리므로 대기는 "sleep & wait" 로 하고,
# psql 에는 연결 · 문장 · 잠금 기한을 둬 Job 의 종료 유예(terminationGracePeriodSeconds) 안에 복원이 끝나게 합니다. SIGKILL · 노드 손실은 trap 이 돌지 않습니다.
# 비밀번호는 Secrets Manager 에서 읽어 이 프로세스 안에서만 쓰고 출력하지 않습니다.
# 입력(env): DATA_DB_ADDRESS DATA_DB_PORT DATA_DB_NAME DATA_MASTER_SECRET_ARN DATA_RUNTIME_SECRET_ARN RDS_CA_BUNDLE
#            CONTRACT_MAX_CONNECTIONS BUDGET_POLICY_PERCENT BUDGET_NEEDED (gitops/apps/commerce-api/tests/check-db-connection-budget.sh 의 계약 · 결과) HOLD_SECONDS [MODE=drill|measure|restore]
set -uo pipefail

export PGHOST="${DATA_DB_ADDRESS:-}" PGPORT="${DATA_DB_PORT:-5432}" PGDATABASE="${DATA_DB_NAME:-}"
export PGCONNECT_TIMEOUT=10 PGSSLMODE="${PGSSLMODE:-verify-full}" PGSSLROOTCERT="${RDS_CA_BUNDLE:-}"
ADMIN_OPTIONS="-c statement_timeout=5000 -c lock_timeout=3000" # 예: ALTER ROLE · 조회가 잠금에 걸려도 5초 안에 끝남

INJECT_ATTEMPTED=0 RESTORED=0 RESULT="" EXIT_CODE=0 INJECTION_VERIFIED=false
role="" role_password="" redis_scheme="" max_conn=null budget=null needed="${BUDGET_NEEDED:-null}"

jq_str() { printf '%s' "$1" | tr '"\\' "''" | tr -d '\n\r'; } # 예: JSON 문자열 안에 넣을 값 (따옴표 · 줄바꿈 제거)
num_or_null() { case "${1:-}" in '' | *[!0-9-]*) printf null ;; *) printf '%s' "$1" ;; esac; }

admin() { # 예: admin "SQL" → 관리 계정으로 한 문장 (기한 있음)
  PGUSER="$ADMIN_USER" PGPASSWORD="$ADMIN_PASSWORD" PGOPTIONS="$ADMIN_OPTIONS" psql -AtqX -v ON_ERROR_STOP=1 -c "$1"
}
sessions() { admin "SELECT count(*) FROM pg_stat_activity WHERE usename = '$role'"; }
role_limit() { admin "SELECT rolconnlimit FROM pg_roles WHERE rolname = '$role'"; }

attempt() { # 예: attempt → "ok|" 또는 "refused|<FATAL 뒤의 문장>" (업무 계정의 새 접속 한 번)
  local out
  if out="$(PGUSER="$role" PGPASSWORD="$role_password" psql -AtqX -c 'SELECT 1' 2>&1)"; then
    printf 'ok|'
  else
    printf 'refused|%s' "$(printf '%s' "$out" | sed -n 's/.*FATAL: *//p' | head -1)"
  fi
}

report() { # 예: report <phase> <attempt 결과> → JSON 한 줄
  local state reason limit
  state="${2%%|*}"; reason="${2#*|}"
  limit="$(num_or_null "$(role_limit 2> /dev/null)")"
  printf '{"phase": "%s", "role": "%s", "role_limit": %s, "connect": "%s", "reason": "%s", "sessions_role": %s, "sessions_total": %s, "max_connections": %s, "budget": %s, "needed": %s, "redis_scheme": "%s", "at": "%s"}\n' \
    "$1" "$(jq_str "$role")" "$limit" "$state" "$(jq_str "$reason")" "$(num_or_null "$(sessions 2> /dev/null)")" \
    "$(num_or_null "$(admin 'SELECT count(*) FROM pg_stat_activity' 2> /dev/null)")" "$max_conn" "$budget" "$needed" "$(jq_str "$redis_scheme")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

note() { printf '{"phase": "%s", "detail": "%s", "at": "%s"}\n' "$1" "$(jq_str "$2")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

finish() { # 예: finish <결과> <종료 코드> <설명> — 판정을 한 번만 정하고 끝냄 (복원 실패가 다른 판정보다 앞섬)
  [ -n "$RESULT" ] || { RESULT="$1"; EXIT_CODE="$2"; note "decision" "$1: $3"; }
  exit "$EXIT_CODE"
}

restore() { # 예: 원래 한도 -1 로 복원 → 재조회 → 새 업무 로그인 (성공한 뒤에는 다시 하지 않음)
  [ "$RESTORED" = 0 ] || return 0
  if ! admin "ALTER ROLE \"$role\" CONNECTION LIMIT -1" > /dev/null 2>&1; then note "restore" "ALTER ROLE -1 failed"; return 1; fi
  if [ "$(role_limit 2> /dev/null)" != "-1" ]; then note "restore" "role limit is not -1 after restore"; return 1; fi
  local login
  login="$(attempt)"
  report restored "$login"
  [ "${login%%|*}" = ok ] || return 1
  RESTORED=1
}

on_exit() {
  local code=$?
  trap - EXIT TERM INT
  if [ "$INJECT_ATTEMPTED" = 1 ] && [ "$RESTORED" = 0 ]; then
    if ! restore; then RESULT=RESTORE_FAILED; code=4; fi
  fi
  [ -n "$RESULT" ] || RESULT="UNKNOWN"
  printf '{"phase": "verdict", "result": "%s", "exit": %s, "injection_verified": %s, "restored": %s, "inject_attempted": %s, "at": "%s"}\n' \
    "$RESULT" "$code" "$INJECTION_VERIFIED" "$([ "$RESTORED" = 1 ] && printf true || printf false)" "$([ "$INJECT_ATTEMPTED" = 1 ] && printf true || printf false)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit "$code"
}
trap on_exit EXIT
trap 'RESULT=INTERRUPTED; EXIT_CODE=143; note interrupted TERM; exit 143' TERM
trap 'RESULT=INTERRUPTED; EXIT_CODE=130; note interrupted INT; exit 130' INT

# ── 1. 선행 확인 (실패하면 ALTER ROLE 0회) ─────────────────────────────
for key in DATA_DB_ADDRESS DATA_DB_NAME DATA_MASTER_SECRET_ARN DATA_RUNTIME_SECRET_ARN; do
  [ -n "${!key:-}" ] || finish PREFLIGHT_FAILED 2 "missing env $key"
done
case "${MODE:-drill}" in
  drill)
    for key in CONTRACT_MAX_CONNECTIONS BUDGET_POLICY_PERCENT BUDGET_NEEDED HOLD_SECONDS; do
      case "${!key:-}" in '' | *[!0-9]*) finish PREFLIGHT_FAILED 2 "env $key must be a non-negative integer" ;; esac
    done ;;
  measure | restore) ;;
  *) finish PREFLIGHT_FAILED 2 "unknown MODE ${MODE}" ;;
esac
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
master="$(secret "$DATA_MASTER_SECRET_ARN" 2> /dev/null)" || finish PREFLIGHT_FAILED 2 "cannot read the master secret"
runtime="$(secret "$DATA_RUNTIME_SECRET_ARN" 2> /dev/null)" || finish PREFLIGHT_FAILED 2 "cannot read the runtime secret"
ADMIN_USER="$(printf '%s' "$master" | jq -r '.username // empty')"; ADMIN_PASSWORD="$(printf '%s' "$master" | jq -r '.password // empty')"
role="$(printf '%s' "$runtime" | jq -r '.username // empty')"; role_password="$(printf '%s' "$runtime" | jq -r '.password // empty')"
redis_scheme="$(printf '%s' "$runtime" | jq -r '(.redis_url // "") | split(":")[0]')"
unset master runtime
[ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASSWORD" ] && [ -n "$role" ] && [ -n "$role_password" ] || finish PREFLIGHT_FAILED 2 "secret fields missing"
export ADMIN_USER ADMIN_PASSWORD

admin 'SELECT 1' > /dev/null 2>&1 || finish PREFLIGHT_FAILED 2 "admin login failed"
original="$(role_limit 2> /dev/null)" || finish PREFLIGHT_FAILED 2 "cannot read the role limit"
[ -n "$original" ] || finish PREFLIGHT_FAILED 2 "role $role does not exist"
case "$original" in '' | *[!0-9-]*) finish PREFLIGHT_FAILED 2 "role limit is not a number: $original" ;; esac

if [ "${MODE:-drill}" = measure ]; then # 예: 계약 값 측정 — 바꾸는 명령 없음 (ALTER ROLE 0회)
  max_conn="$(admin 'SHOW max_connections' 2> /dev/null)" || finish PREFLIGHT_FAILED 2 "cannot read max_connections"
  case "$max_conn" in '' | *[!0-9]*) finish PREFLIGHT_FAILED 2 "max_connections is not a number: $max_conn" ;; esac
  printf '{"phase": "measure", "role": "%s", "role_limit": %s, "max_connections": %s, "sessions_total": %s, "at": "%s"}\n' \
    "$(jq_str "$role")" "$(num_or_null "$original")" "$max_conn" "$(num_or_null "$(admin 'SELECT count(*) FROM pg_stat_activity' 2> /dev/null)")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finish PASS 0 "measured max_connections $max_conn without changes"
fi
if [ "${MODE:-drill}" = restore ]; then # 예: 수동 복원 — Job 이 중간에 끊겨 한도가 남았을 때만
  note "restore_only" "original limit $original"
  INJECT_ATTEMPTED=1
  if restore; then finish PASS 0 "restored to -1"; else finish RESTORE_FAILED 4 "manual restore failed"; fi
fi

[ "$original" = "-1" ] || finish PREFLIGHT_FAILED 2 "original limit is $original; only -1 is supported (change it back with its owner first)"
max_conn="$(admin 'SHOW max_connections' 2> /dev/null)" || finish PREFLIGHT_FAILED 2 "cannot read max_connections"
case "$max_conn" in '' | *[!0-9]*) finish PREFLIGHT_FAILED 2 "max_connections is not a number: $max_conn" ;; esac
[ "$max_conn" = "$CONTRACT_MAX_CONNECTIONS" ] || finish PREFLIGHT_FAILED 2 "max_connections $max_conn differs from the contract $CONTRACT_MAX_CONNECTIONS (re-measure and review the contract first)"
budget=$(( max_conn * BUDGET_POLICY_PERCENT / 100 ))
[ "$BUDGET_NEEDED" -le "$budget" ] || finish PREFLIGHT_FAILED 2 "budget FAIL: needed $BUDGET_NEEDED > budget $budget"
first="$(attempt)"
report normal "$first"
[ "${first%%|*}" = ok ] || finish PREFLIGHT_FAILED 2 "business login failed before the change"

# ── 2. 주입 (변경 시도 상태를 ALTER 전에 남김) ─────────────────────────
target="$(sessions 2> /dev/null)" || finish INJECT_FAILED 3 "cannot count sessions"
case "$target" in '' | *[!0-9]*) finish INJECT_FAILED 3 "session count is not a number: $target" ;; esac
note "inject_attempt" "ALTER ROLE $role CONNECTION LIMIT $target (original -1)"
INJECT_ATTEMPTED=1
admin "ALTER ROLE \"$role\" CONNECTION LIMIT $target" > /dev/null 2>&1 || finish INJECT_FAILED 3 "ALTER ROLE failed"
[ "$(role_limit 2> /dev/null)" = "$target" ] || finish INJECT_FAILED 3 "role limit read back differs from $target"

# ── 3. 장애 유효성 — 역할 한도 거부만 유효 ─────────────────────────────
fault="$(attempt)"
report fault "$fault"
case "$fault" in
  ok\|*) finish FAULT_INVALID 5 "a new business login still succeeded" ;;
  "refused|too many connections for role \"$role\""*) INJECTION_VERIFIED=true ;;
  *) finish FAULT_INVALID 5 "refused for another reason: ${fault#*|}" ;;
esac
sleep "$HOLD_SECONDS" &
wait $!
report during_fault "$(attempt)"

# ── 4. 복원과 판정 ─────────────────────────────────────────────────────
if restore; then finish PASS 0 "role-limit refusal observed and restored"; else RESULT=RESTORE_FAILED; EXIT_CODE=4; exit 4; fi
