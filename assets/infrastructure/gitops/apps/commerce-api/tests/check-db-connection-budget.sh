#!/usr/bin/env bash
# gitops/apps/commerce-api/tests/check-db-connection-budget.sh
# 연결 고갈: commerce-api 의 DB 연결 예산을 overlay 렌더 결과와 환경별 계약(contracts/<env>.env)으로 계산합니다. 클러스터 · AWS 호출 없음.
#   needed = (R + S + T) × P + J + O + U        budget = 실측 max_connections × 정책 % (내림)
#   R 복제본(렌더된 Deployment) · S maxSurge 추가 Pod(퍼센트는 올림) · T 종료 중 Pod(계약: replicas 또는 숫자)
#   P API 의 DB_POOL_MAX(env > envFrom 의 뒤쪽 소스) · J 마이그레이션 Job 들의 DB_POOL_MAX × parallelism · O 운영 몫 · U 그 밖의 사용자
# 종료 중 Pod 는 replicas + maxSurge 계산에 들어가지 않아 그 밖에서 연결을 쥡니다 (Kubernetes Deployment 문서). PreSync Job 과 롤아웃이 겹치는 경우까지 더한 보수적 상한입니다.
# 값을 못 찾거나 지원하지 않는 구성(HPA · valueFrom · 출처를 모르는 Secret · 계약 누락)은 0 으로 바꾸지 않고 BUDGET_ERROR 로 멈춥니다.
# 사용: bash gitops/apps/commerce-api/tests/check-db-connection-budget.sh <env> [--rendered <렌더 파일>] [--contract <계약 파일>]
# 출력: BUDGET … 한 줄(계산 근거) + BUDGET_PASS · BUDGET_FAIL · BUDGET_ERROR 한 줄
# 종료: 0 PASS · 1 FAIL(예산 초과) · 2 입력 오류 · 지원하지 않는 구성 · 도구 없음
set -euo pipefail

ENV_NAME="${1:-}"
err() { printf 'BUDGET_ERROR env=%s reason=%s\n' "${ENV_NAME:-?}" "$1"; exit 2; }
case "$ENV_NAME" in '' | *[!a-z0-9-]*) err "usage: check-db-connection-budget.sh <env> [--rendered <file>] [--contract <file>]" ;; esac
shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$HERE")" # 예: gitops/apps/commerce-api
RENDERED="" CONTRACT="$APP_DIR/contracts/$ENV_NAME.env"
while [ $# -gt 0 ]; do
  case "$1" in
    --rendered) [ $# -ge 2 ] || err "--rendered needs a file"; RENDERED="$2"; shift 2 ;;
    --contract) [ $# -ge 2 ] || err "--contract needs a file"; CONTRACT="$2"; shift 2 ;;
    *) err "unknown argument: $1" ;;
  esac
done

command -v yq > /dev/null 2>&1 || err "yq-v4-required"
yq --version 2>/dev/null | grep -q 'version v4' || err "mikefarah-yq-v4-required"

# ── 계약 ───────────────────────────────────────────────────────────────
[ -f "$CONTRACT" ] || err "contract-missing:${CONTRACT#"$APP_DIR"/}" # 예: contract-missing:contracts/prod.env (Prod 계약은 incidents 에서 만들지 않음)
ckey() { # 예: ckey DB_MAX_CONNECTIONS → 값 (줄 끝 주석 · 공백 제거, 없으면 빈 값)
  awk -F= -v k="$1" '$1 == k { v = substr($0, index($0, "=") + 1); sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }' "$CONTRACT"
}
is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
for key in CONTRACT_ENV DB_ENGINE_VERSION DB_INSTANCE_CLASS DB_PARAMETER_GROUP DB_MAX_CONNECTIONS DB_MEASURED_AT BUDGET_POLICY_PERCENT OPERATOR_RESERVE OTHER_DB_USERS TERMINATING_RESERVE SUPPORTED_CONCURRENCY; do
  value="$(ckey "$key")"
  [ -n "$value" ] || err "contract-key-missing:$key"
  case "$value" in REPLACE*) err "contract-not-measured:$key" ;; esac
done
[ "$(ckey CONTRACT_ENV)" = "$ENV_NAME" ] || err "contract-env-mismatch:$(ckey CONTRACT_ENV)"
MAXC="$(ckey DB_MAX_CONNECTIONS)"; PCT="$(ckey BUDGET_POLICY_PERCENT)"; O="$(ckey OPERATOR_RESERVE)"; U="$(ckey OTHER_DB_USERS)"; TR="$(ckey TERMINATING_RESERVE)"
is_uint "$MAXC" && [ "$MAXC" -gt 0 ] || err "contract-max-connections-not-positive-integer:$MAXC"
is_uint "$PCT" && [ "$PCT" -ge 1 ] && [ "$PCT" -le 100 ] || err "contract-policy-percent-out-of-range:$PCT"
is_uint "$O" || err "contract-operator-reserve-not-integer:$O"
is_uint "$U" || err "contract-other-users-not-integer:$U"
[ "$TR" = replicas ] || is_uint "$TR" || err "contract-terminating-reserve-invalid:$TR"
[ "$(ckey SUPPORTED_CONCURRENCY)" = one-rollout ] || err "contract-concurrency-unsupported:$(ckey SUPPORTED_CONCURRENCY)"

# ── 렌더 ───────────────────────────────────────────────────────────────
if [ -z "$RENDERED" ]; then
  command -v kustomize > /dev/null 2>&1 || err "kustomize-required"
  [ -d "$APP_DIR/overlays/$ENV_NAME" ] || err "overlay-missing:overlays/$ENV_NAME"
  RENDERED="$(mktemp "${TMPDIR:-/tmp}/budget-render.XXXXXX")"; trap 'rm -f "$RENDERED" "$RENDERED.err"' EXIT
  kustomize build "$APP_DIR/overlays/$ENV_NAME" > "$RENDERED" 2> "$RENDERED.err" || err "kustomize-build-failed:$(head -1 "$RENDERED.err" | tr ' ' '_')"
fi
[ -s "$RENDERED" ] || err "rendered-file-empty"
q() { yq e "$1" "$RENDERED"; }                 # 예: 문서마다 따로 평가 (조건에 맞는 문서만 출력)
qn() { yq ea "[$1] | length" "$RENDERED"; }    # 예: 조건에 맞는 문서 수

DEP='select(.kind == "Deployment" and .metadata.name == "commerce-api")'
[ "$(qn "$DEP")" = 1 ] || err "deployment-commerce-api-not-exactly-one"
[ "$(qn 'select(.kind == "HorizontalPodAutoscaler" and .spec.scaleTargetRef.name == "commerce-api")')" = 0 ] || err "hpa-unsupported"
R="$(q "$DEP | .spec.replicas // \"\"")"
is_uint "$R" || err "replicas-missing-or-not-integer:$R"

STRATEGY="$(q "$DEP | .spec.strategy.type // \"RollingUpdate\"")"
case "$STRATEGY" in
  RollingUpdate)
    SURGE="$(q "$DEP | .spec.strategy.rollingUpdate.maxSurge // \"25%\"")" # 예: 값이 없으면 Kubernetes 기본 25%
    case "$SURGE" in
      *%) pct="${SURGE%\%}"; is_uint "$pct" || err "max-surge-invalid:$SURGE"; S=$(( (R * pct + 99) / 100 )) ;;
      *) is_uint "$SURGE" || err "max-surge-invalid:$SURGE"; S="$SURGE" ;;
    esac
    if [ "$TR" = replicas ]; then T="$R"; else T="$TR"; fi ;;
  Recreate) S=0; T=0; SURGE=0 ;; # 예: 옛 Pod 가 모두 끝난 뒤 새 Pod 를 만듦
  *) err "strategy-unsupported:$STRATEGY" ;;
esac

secret_keys() { # 예: secret_keys commerce-api-runtime → 그 Secret 이 env 로 내보낼 키 목록 (모르면 BUDGET_ERROR)
  local n es
  es="select(.kind == \"ExternalSecret\" and (.spec.target.name // .metadata.name) == \"$1\")"
  n="$(qn "$es")"
  if [ "$n" = 1 ]; then
    [ "$(q "$es | ((.spec.target.template.data // {}) | length) > 0")" = true ] || err "secret-keys-unknown:$1"
    q "$es | .spec.target.template.data | keys | .[]"
    return 0
  fi
  n="$(qn "select(.kind == \"Secret\" and .metadata.name == \"$1\")")"
  [ "$n" = 1 ] || err "secret-source-not-in-render:$1"
  q "select(.kind == \"Secret\" and .metadata.name == \"$1\") | ((.data // {}) * (.stringData // {})) | keys | .[]"
}

pool_of() { # 예: pool_of Deployment commerce-api commerce-api → "<값> <출처>" (env 가 envFrom 보다 앞서고, envFrom 은 뒤 소스가 앞 소스를 덮음)
  local sel lit kind ref value="" from="" x
  sel="select(.kind == \"$1\" and .metadata.name == \"$2\") | .spec.template.spec.containers[] | select(.name == \"$3\")"
  [ "$(q "$sel | (.env // [])[] | select(.name == \"DB_POOL_MAX\") | has(\"valueFrom\")")" != true ] || err "pool-from-valueFrom-unsupported:$1/$2/$3"
  lit="$(q "$sel | (.env // [])[] | select(.name == \"DB_POOL_MAX\") | .value // \"\"")"
  if [ -n "$lit" ]; then printf '%s env' "$lit"; return 0; fi
  while IFS='|' read -r kind ref; do
    [ -n "$kind" ] || continue
    case "$kind" in
      configMapRef)
        [ "$(qn "select(.kind == \"ConfigMap\" and .metadata.name == \"$ref\")")" = 1 ] || err "configmap-not-in-render:$ref"
        x="$(q "select(.kind == \"ConfigMap\" and .metadata.name == \"$ref\") | .data.DB_POOL_MAX // \"\"")"
        if [ -n "$x" ]; then value="$x"; from="configmap/$ref"; fi ;;
      secretRef)
        x="$(secret_keys "$ref")" || { printf '%s\n' "$x"; exit 2; } # 예: 출처를 모르면 secret_keys 가 BUDGET_ERROR 를 냄
        case " $(printf '%s' "$x" | tr '\n' ' ') " in *" DB_POOL_MAX "*) err "pool-from-secret-unreadable:$ref" ;; esac ;;
    esac
  done << EOF
$(q "$sel | (.envFrom // [])[] | ((select(has(\"configMapRef\")) | \"configMapRef|\" + .configMapRef.name), (select(has(\"secretRef\")) | \"secretRef|\" + .secretRef.name))")
EOF
  [ -n "$value" ] || err "pool-not-found:$1/$2/$3"
  printf '%s %s' "$value" "$from"
}

out="$(pool_of Deployment commerce-api commerce-api)" || { printf '%s\n' "$out"; exit 2; }
P="${out%% *}"; PFROM="${out#* }"
is_uint "$P" && [ "$P" -gt 0 ] || err "api-pool-not-positive-integer:$P"

J=0
for job in $(q 'select(.kind == "Job") | .metadata.name'); do
  par="$(q "select(.kind == \"Job\" and .metadata.name == \"$job\") | .spec.parallelism // 1")"
  is_uint "$par" || err "job-parallelism-invalid:$job"
  for c in $(q "select(.kind == \"Job\" and .metadata.name == \"$job\") | .spec.template.spec.containers[].name"); do
    out="$(pool_of Job "$job" "$c")" || { printf '%s\n' "$out"; exit 2; }
    is_uint "${out%% *}" || err "job-pool-not-integer:$job/$c:${out%% *}"
    J=$(( J + ${out%% *} * par ))
  done
done

NEEDED=$(( (R + S + T) * P + J + O + U ))
BUDGET=$(( MAXC * PCT / 100 ))
printf 'BUDGET env=%s replicas=%s surge=%s(%s) terminating=%s pool=%s(%s) jobs=%s operator=%s other=%s needed=%s max_connections=%s measured_at=%s policy=%s%% budget=%s\n' \
  "$ENV_NAME" "$R" "$S" "$SURGE" "$T" "$P" "$PFROM" "$J" "$O" "$U" "$NEEDED" "$MAXC" "$(ckey DB_MEASURED_AT)" "$PCT" "$BUDGET"
if [ "$NEEDED" -le "$BUDGET" ]; then
  printf 'BUDGET_PASS env=%s needed=%s budget=%s headroom=%s\n' "$ENV_NAME" "$NEEDED" "$BUDGET" "$((BUDGET - NEEDED))"
else
  printf 'BUDGET_FAIL env=%s needed=%s budget=%s over=%s\n' "$ENV_NAME" "$NEEDED" "$BUDGET" "$((NEEDED - BUDGET))"
  exit 1
fi
