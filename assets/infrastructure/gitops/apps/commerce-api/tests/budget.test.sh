#!/usr/bin/env bash
# gitops/apps/commerce-api/tests/budget.test.sh — DB 연결 예산 검사(check-db-connection-budget.sh) 회귀 테스트 16개 (연결 예산).
# 실제 overlays/dev · prod 를 kustomize 로 렌더한 경우와, 렌더 결과를 흉내 낸 작은 YAML 로 경계 조건을 봅니다. 클러스터 · AWS 호출 없음.
# 계약 값(max_connections 81 등)은 시험 입력이지 실측이 아닙니다. contracts/dev.env 를 실측값으로 채운 뒤에도 시험은 키마다 시험 값으로 덮어 같은 결과를 냅니다.
# 실제 overlay 시험은 렌더와 계산이 BUDGET_ERROR 없이 끝나는지만 봅니다(큰 시험 상한으로 PASS). 복제본 · 풀 값을 바꾼 PR 은 이 시험이 아니라 다음 단계의 예산 검사에서 실패합니다.
# 필요 도구: kustomize 5.8.1 · mikefarah yq v4 (없으면 INCONCLUSIVE 로 종료 2)
# 실행: bash gitops/apps/commerce-api/tests/budget.test.sh — 마지막 "Ran 16 tests" · "OK" 가 정상.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
command -v kustomize > /dev/null 2>&1 && yq --version 2> /dev/null | grep -q 'version v4' || { echo 'INCONCLUSIVE kustomize and mikefarah yq v4 are required'; exit 2; }
T_RUN=0; T_FAIL=0; T_NAME=""; T_OUT=""; T_CODE=0
T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/budget-test.XXXXXX")"
trap 'rm -rf "$T_TMP"' EXIT
t_begin() { T_NAME="$1"; T_RUN=$((T_RUN + 1)); T_CASE_FAILED=0; }
t_fail() { T_CASE_FAILED=1; printf 'FAIL: %s — %s\n' "$T_NAME" "$1" >&2; }
t_end() { if [ "$T_CASE_FAILED" = 1 ]; then T_FAIL=$((T_FAIL + 1)); printf '%s ... FAIL\n' "$T_NAME"; else printf '%s ... ok\n' "$T_NAME"; fi; }
t_exit() {
  expected="$1"; shift
  set +e
  T_OUT="$("$@" 2> "$T_TMP/stderr")"; T_CODE=$?
  set -e
  [ "$T_CODE" = "$expected" ] || t_fail "exit $T_CODE (expected $expected); stdout=$T_OUT; stderr=$(tail -3 "$T_TMP/stderr" | tr '\n' ' ')"
}
t_out_contains() { case "$T_OUT" in *"$1"*) ;; *) t_fail "stdout does not contain '$1': $T_OUT" ;; esac; }
t_summary() {
  printf -- '----------------------------------------------------------------------\nRan %d tests\n\n' "$T_RUN"
  if [ "$T_FAIL" = 0 ]; then printf 'OK\n'; exit 0; else printf 'FAILED (failures=%d)\n' "$T_FAIL"; exit 1; fi
}

CHECK="bash gitops/apps/commerce-api/tests/check-db-connection-budget.sh"
contract() { # 예: contract <env> <max_connections> [<terminating>] → 측정이 끝난 계약 파일 경로 (실제 계약의 현재 값과 상관없이 키마다 시험 값)
  local f="$T_TMP/contract-$1-$2-${3:-replicas}.env"
  sed -e "s/^CONTRACT_ENV=.*/CONTRACT_ENV=$1/" -e 's/^DB_ENGINE_VERSION=.*/DB_ENGINE_VERSION=17.6/' -e 's/^DB_INSTANCE_CLASS=.*/DB_INSTANCE_CLASS=db.t4g.micro/' \
      -e 's/^DB_PARAMETER_GROUP=.*/DB_PARAMETER_GROUP=fixture-pg17/' -e "s/^DB_MAX_CONNECTIONS=.*/DB_MAX_CONNECTIONS=$2/" \
      -e 's/^DB_MEASURED_AT=.*/DB_MEASURED_AT=2026-10-01T00:00:00Z/' -e 's/^BUDGET_POLICY_PERCENT=.*/BUDGET_POLICY_PERCENT=80/' \
      -e 's/^OPERATOR_RESERVE=.*/OPERATOR_RESERVE=2/' -e 's/^OTHER_DB_USERS=.*/OTHER_DB_USERS=0/' \
      -e "s/^TERMINATING_RESERVE=.*/TERMINATING_RESERVE=${3:-replicas}/" -e 's/^SUPPORTED_CONCURRENCY=.*/SUPPORTED_CONCURRENCY=one-rollout/' \
      gitops/apps/commerce-api/contracts/dev.env > "$f"
  printf '%s' "$f"
}
unmeasured() { # 예: 측정 전 계약 (DB_MAX_CONNECTIONS=REPLACE_MEASURED) — 실제 계약을 채운 뒤에도 같은 시험이 됨
  local f="$T_TMP/contract-unmeasured.env"
  sed 's/^DB_MAX_CONNECTIONS=.*/DB_MAX_CONNECTIONS=REPLACE_MEASURED/' "$(contract dev 81)" > "$f"
  printf '%s' "$f"
}
render() { # 예: render <replicas> <maxSurge> <API 의 env 블록> <envFrom 블록> [추가 문서] → 렌더 결과를 흉내 낸 파일
  local f="$T_TMP/render-$RANDOM.yaml"
  cat > "$f" << EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: commerce-api-config-abc}
data: {DB_POOL_MAX: "10", NODE_ENV: production}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: commerce-api-runtime}
spec:
  target:
    name: commerce-api-runtime
    template:
      data: {DATABASE_URL: x, REDIS_URL: x, JWT_SECRET: x, COOKIE_SECRET: x}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: commerce-api}
spec:
  replicas: $1
  strategy: {type: RollingUpdate, rollingUpdate: {maxSurge: $2, maxUnavailable: 0}}
  template:
    spec:
      containers:
        - name: commerce-api
          env: $3
          envFrom: $4
---
apiVersion: batch/v1
kind: Job
metadata: {name: commerce-api-migrate}
spec:
  template:
    spec:
      containers:
        - name: migrate
          env: [{name: DB_POOL_MAX, value: "5"}]
${5:-}
EOF
  printf '%s' "$f"
}
CM='[{configMapRef: {name: commerce-api-config-abc}}, {secretRef: {name: commerce-api-runtime}}]'

t_begin "test_real_dev_overlay_passes_with_fixture_contract"
t_exit 0 $CHECK dev --contract "$(contract dev 100000)"; t_out_contains 'BUDGET env=dev replicas='; t_out_contains '(configmap/commerce-api-config-'; t_out_contains 'BUDGET_PASS env=dev'; t_end

t_begin "test_real_prod_overlay_passes_with_fixture_contract"
t_exit 0 $CHECK prod --contract "$(contract prod 100000)"; t_out_contains 'BUDGET env=prod replicas='; t_out_contains '(configmap/commerce-api-config-'; t_out_contains 'BUDGET_PASS env=prod'; t_end

t_begin "test_terminating_pods_are_counted_beyond_replicas_plus_surge"
t_exit 0 $CHECK dev --rendered "$(render 2 1 '[]' "$CM")" --contract "$(contract dev 72)"; t_out_contains 'terminating=2'; t_out_contains 'needed=57'
t_exit 1 $CHECK dev --rendered "$(render 2 1 '[]' "$CM")" --contract "$(contract dev 71)"; t_out_contains 'over=1'; t_end

t_begin "test_measured_terminating_reserve_lowers_the_need"
t_exit 0 $CHECK dev --rendered "$(render 2 1 '[]' "$CM")" --contract "$(contract dev 59 1)"; t_out_contains 'terminating=1'; t_out_contains 'needed=47'; t_end

t_begin "test_percent_surge_rounds_up"
t_exit 0 $CHECK dev --rendered "$(render 3 '"50%"' '[]' "$CM")" --contract "$(contract dev 200)"; t_out_contains 'surge=2(50%)'
t_exit 0 $CHECK dev --rendered "$(render 3 '"25%"' '[]' "$CM")" --contract "$(contract dev 200)"; t_out_contains 'surge=1(25%)'; t_end

t_begin "test_recreate_strategy_has_no_surge_or_terminating_overlap"
f="$(render 2 1 '[]' "$CM")"; yq -i 'select(.kind == "Deployment").spec.strategy = {"type": "Recreate"}' "$f"
t_exit 0 $CHECK dev --rendered "$f" --contract "$(contract dev 100)"; t_out_contains 'surge=0'; t_out_contains 'needed=27'; t_end

t_begin "test_explicit_env_overrides_configmap"
t_exit 0 $CHECK dev --rendered "$(render 2 1 '[{name: DB_POOL_MAX, value: "4"}]' "$CM")" --contract "$(contract dev 100)"; t_out_contains 'pool=4(env)'; t_end

t_begin "test_later_envFrom_configmap_wins"
extra='---
apiVersion: v1
kind: ConfigMap
metadata: {name: override}
data: {DB_POOL_MAX: "20"}'
t_exit 1 $CHECK dev --rendered "$(render 2 1 '[]' '[{configMapRef: {name: commerce-api-config-abc}}, {configMapRef: {name: override}}]' "$extra")" --contract "$(contract dev 100)"
t_out_contains 'pool=20(configmap/override)'; t_out_contains 'needed=107'; t_end

t_begin "test_pool_from_secret_template_is_unreadable"
f="$(render 2 1 '[]' "$CM")"; yq -i 'select(.kind == "ExternalSecret").spec.target.template.data.DB_POOL_MAX = "x"' "$f"
t_exit 2 $CHECK dev --rendered "$f" --contract "$(contract dev 100)"; t_out_contains 'pool-from-secret-unreadable'; t_end

t_begin "test_secret_without_template_is_unknown"
f="$(render 2 1 '[]' "$CM")"; yq -i 'del(select(.kind == "ExternalSecret").spec.target.template)' "$f"
t_exit 2 $CHECK dev --rendered "$f" --contract "$(contract dev 100)"; t_out_contains 'secret-keys-unknown'; t_end

t_begin "test_missing_or_invalid_pool_is_an_error"
f="$(render 2 1 '[]' "$CM")"; yq -i 'del(select(.kind == "ConfigMap").data.DB_POOL_MAX)' "$f"
t_exit 2 $CHECK dev --rendered "$f" --contract "$(contract dev 100)"; t_out_contains 'pool-not-found'
t_exit 2 $CHECK dev --rendered "$(render 2 1 '[{name: DB_POOL_MAX, value: "ten"}]' "$CM")" --contract "$(contract dev 100)"; t_out_contains 'api-pool-not-positive-integer'
t_exit 2 $CHECK dev --rendered "$(render 2 1 '[{name: DB_POOL_MAX, value: "-1"}]' "$CM")" --contract "$(contract dev 100)"; t_out_contains 'api-pool-not-positive-integer'; t_end

t_begin "test_job_without_pool_is_an_error"
f="$(render 2 1 '[]' "$CM")"; yq -i 'select(.kind == "Job").spec.template.spec.containers[0].env = []' "$f"
t_exit 2 $CHECK dev --rendered "$f" --contract "$(contract dev 100)"; t_out_contains 'pool-not-found:Job/commerce-api-migrate/migrate'; t_end

t_begin "test_hpa_is_unsupported"
extra='---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: commerce-api}
spec: {scaleTargetRef: {kind: Deployment, name: commerce-api}, maxReplicas: 6}'
t_exit 2 $CHECK dev --rendered "$(render 2 1 '[]' "$CM" "$extra")" --contract "$(contract dev 100)"; t_out_contains 'hpa-unsupported'; t_end

t_begin "test_unmeasured_or_wrong_contract_is_an_error"
t_exit 2 $CHECK dev --rendered "$(render 2 1 '[]' "$CM")" --contract "$(unmeasured)"; t_out_contains 'contract-not-measured:DB_MAX_CONNECTIONS'
t_exit 2 $CHECK staging --rendered "$(render 2 1 '[]' "$CM")"; t_out_contains 'contract-missing:contracts/staging.env'
t_exit 2 $CHECK prod --rendered "$(render 2 1 '[]' "$CM")" --contract "$(contract dev 100)"; t_out_contains 'contract-env-mismatch'
f="$(contract dev 100)"; sed -i.bak '/^OPERATOR_RESERVE=/d' "$f"
t_exit 2 $CHECK dev --rendered "$(render 2 1 '[]' "$CM")" --contract "$f"; t_out_contains 'contract-key-missing:OPERATOR_RESERVE'; t_end

t_begin "test_render_failure_is_an_error"
mkdir -p "$T_TMP/app/overlays/dev" "$T_TMP/app/tests" "$T_TMP/app/contracts"
cp gitops/apps/commerce-api/tests/check-db-connection-budget.sh "$T_TMP/app/tests/"
printf 'resources: [../../missing-base]\n' > "$T_TMP/app/overlays/dev/kustomization.yaml"
t_exit 2 bash "$T_TMP/app/tests/check-db-connection-budget.sh" dev --contract "$(contract dev 100)"; t_out_contains 'kustomize-build-failed'; t_end

t_begin "test_raising_replicas_turns_pass_into_fail"
t_exit 0 $CHECK dev --rendered "$(render 2 1 '[]' "$CM")" --contract "$(contract dev 81)"; t_out_contains 'BUDGET_PASS'
t_exit 1 $CHECK dev --rendered "$(render 3 1 '[]' "$CM")" --contract "$(contract dev 81)"; t_out_contains 'needed=77'; t_out_contains 'BUDGET_FAIL'; t_end

t_summary
