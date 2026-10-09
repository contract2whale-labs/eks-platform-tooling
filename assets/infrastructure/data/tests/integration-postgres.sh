#!/usr/bin/env bash
# data/tests/integration-postgres.sh — 실제 PostgreSQL 17 로 초기화 SQL 전문과 계정 비밀번호 변경 경로를 확인합니다 (데이터베이스 초기화).
# tests/fake/psql 은 SQL 을 파싱하지 않아 "psql -c 는 :\"role\" · :'pw' 를 치환하지 않는다" 같은 문법 오류를 잡지 못합니다. 이 검사는 lib/common.sh 의
# psql_set_role_password 를 Docker 의 postgres:17-alpine 에 그대로 실행해 (1) 특수 문자가 든 비밀번호 설정 → 새 비밀번호 로그인 (2) 같은 호출 반복(멱등)
# (3) 없는 계정은 실패하고 기존 계정의 비밀번호는 그대로 (4) 옛 방식(-c)은 문법 오류 — 네 가지를 봅니다. 그 앞에서 operator/bootstrap.sql 전문을
# RDS 처럼 SUPERUSER 가 아닌 관리자 계정으로 (a) 첫 실행 (b) 재실행 (c) 두 계정의 권한(스키마 변경 계정만 CREATE) 까지 확인합니다. AWS · 클러스터 호출 없음.
# 사용: bash data/tests/integration-postgres.sh   → "integration-postgres: 7 OK, 0 FAIL" (Docker 가 없으면 종료 3)
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v docker > /dev/null && docker info > /dev/null 2>&1 || { echo "integration-postgres: Docker 가 필요합니다" >&2; exit 3; }
RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')" || exit 3
[ -n "$RUN_ID" ] || exit 3
NAME="database-bootstrap-pg-$RUN_ID"; IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}" # 예: 운영(RDS PostgreSQL 17)과 같은 주 버전
OWNED_CONTAINER_ID=""
cleanup() {
  local original_rc=$? cleanup_rc=0
  trap - EXIT
  if [ -n "$OWNED_CONTAINER_ID" ]; then
    docker rm -f "$OWNED_CONTAINER_ID" > /dev/null 2>&1 || cleanup_rc=$?
    if [ "$cleanup_rc" -ne 0 ]; then
      printf 'integration-postgres: cleanup failed container=%s exit=%s; inspect this owned container\n' "$OWNED_CONTAINER_ID" "$cleanup_rc" >&2
      [ "$original_rc" -ne 0 ] || original_rc=3
    fi
  fi
  exit "$original_rc"
}
trap cleanup EXIT
# create 실패 출력은 소유권이 아닙니다. 성공 응답의 전체 ID만 기록하고 동명 객체는 채택하지 않습니다.
created_id="$(docker create --name "$NAME" -e POSTGRES_PASSWORD=master-fixture "$IMAGE")" || exit 3
case "$created_id" in
  ''|*[!0123456789abcdef]*) echo 'integration-postgres: invalid create ID; inspect the create response without deleting by name' >&2; exit 3 ;;
esac
[ "${#created_id}" -eq 64 ] || { echo 'integration-postgres: invalid create ID length; no cleanup by name' >&2; exit 3; }
OWNED_CONTAINER_ID="$created_id"
docker start "$OWNED_CONTAINER_ID" > /dev/null || exit 3
# 이후 모든 실행은 성공한 create 응답의 ID를 사용합니다.
NAME="$OWNED_CONTAINER_ID"
for _ in $(seq 1 30); do docker exec "$NAME" pg_isready -U postgres -q 2> /dev/null && break; sleep 1; done
# 시험 대상 함수가 부르는 psql 을 컨테이너 안의 psql 로 바꿉니다. 비밀번호 환경 변수는 -e 로 이름만 넘깁니다(값은 인자에 나오지 않음).
psql() { docker exec -i -e BOOTSTRAP_ROLE_PASSWORD -e PGPASSWORD -e PGUSER "$NAME" psql -h 127.0.0.1 -d postgres "$@"; }
log() { :; }; die() { echo "die $*" >&2; return 1; }
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh" 2> /dev/null || true
ok=0; bad=0
pass() { ok=$((ok + 1)); printf 'OK    %s\n' "$1"; }; fail() { bad=$((bad + 1)); printf 'FAIL  %s\n' "$1"; }
login() { PGUSER="$1" PGPASSWORD="$2" psql --no-psqlrc -X -At -c 'SELECT current_user' 2> /dev/null; }
export PGUSER=postgres PGPASSWORD=master-fixture
# RDS 의 관리자 계정은 SUPERUSER 가 아닙니다. 같은 조건(CREATEROLE · CREATEDB · 데이터베이스 소유)의 계정으로 bootstrap.sql 을 실행합니다.
psql --no-psqlrc -X -q -c "CREATE ROLE rds_like_master LOGIN CREATEROLE CREATEDB PASSWORD 'master-fixture'" -c 'CREATE DATABASE commercedb OWNER rds_like_master' > /dev/null
bootstrap_sql() { # 예: bootstrap.sh 가 psql_file 에 넘기는 것과 같은 변수 네 개
  PGUSER=rds_like_master docker exec -i -e PGPASSWORD -e PGUSER "$NAME" psql -h 127.0.0.1 -d commercedb --no-psqlrc -X -q -v ON_ERROR_STOP=1 \
    -v migration_role=commerce_migrator -v runtime_role=commerce_runtime -v schema_name=public -v database_name=commercedb -f - < "$ROOT/operator/bootstrap.sql" > /dev/null 2>&1
}
privileges() { docker exec -i -e PGPASSWORD -e PGUSER "$NAME" psql -h 127.0.0.1 -d commercedb --no-psqlrc -X -At -c "SELECT concat_ws(',', (SELECT count(*) FROM pg_roles WHERE rolname IN ('commerce_migrator','commerce_runtime') AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole), has_schema_privilege('commerce_migrator','public','CREATE'), has_schema_privilege('commerce_runtime','public','CREATE'), has_schema_privilege('commerce_runtime','public','USAGE'))" 2> /dev/null; }
PW1="p'w\"x;-- \$(id) %s"; PW2='second-Password_2'

bootstrap_sql && pass 'bootstrap.first-run       bootstrap.sql 전문이 SUPERUSER 가 아닌 관리자 계정으로 실행됨' || fail 'bootstrap.first-run'
bootstrap_sql && pass 'bootstrap.rerun           같은 SQL 을 다시 실행해도 성공(멱등)' || fail 'bootstrap.rerun'
[ "$(privileges)" = '2,t,f,t' ] && pass 'bootstrap.privileges      계정 2 · CREATE 는 스키마 변경 계정만 · 실행 계정은 USAGE' || fail "bootstrap.privileges ($(privileges))"
psql_set_role_password commerce_runtime "$PW1" && [ "$(login commerce_runtime "$PW1")" = commerce_runtime ] && pass 'set.special-characters  새 비밀번호로 로그인' || fail 'set.special-characters'
psql_set_role_password commerce_runtime "$PW1" && [ "$(login commerce_runtime "$PW1")" = commerce_runtime ] && pass 'set.idempotent          같은 호출을 반복해도 같은 결과' || fail 'set.idempotent'
if psql_set_role_password no_such_role "$PW2" 2> /dev/null; then fail 'set.unknown-role (성공하면 안 됨)'
elif [ "$(login commerce_runtime "$PW1")" = commerce_runtime ]; then pass 'set.unknown-role        실패하고 기존 계정의 비밀번호는 그대로'; else fail 'set.unknown-role (기존 비밀번호가 바뀜)'; fi
OLD=$(psql --no-psqlrc -X -q -v ON_ERROR_STOP=1 -v role=commerce_runtime -v pw="$PW2" -c "ALTER ROLE :\"role\" PASSWORD :'pw'" 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$OLD" | grep -q 'syntax error at or near ":"' && pass 'old-form.rejected        psql -c 는 변수를 치환하지 않음 (syntax error)' || fail "old-form.rejected (rc=$rc)"
echo "integration-postgres: $ok OK, $bad FAIL"; [ "$bad" -eq 0 ]
