#!/usr/bin/env bash
# scripts/toolchain/vendor-crd-schemas.sh — kubeconform 이 쓰는 CRD JSON schema 를 인프라 저장소 gitops/schemas/ 에 내려받아 커밋합니다 (오프라인 검사 · 외부 URL 의존 제거)
# 사용: bash scripts/toolchain/vendor-crd-schemas.sh   (INFRA_ROOT 필요 — scripts/toolchain/env.sh)
# 출처: datreeio/CRDs-catalog (https://github.com/datreeio/CRDs-catalog) — 경로 규칙 <group>/<kind 소문자>_<version>.json 은 kubeconform 의 -schema-location 템플릿과 같습니다. 새 CRD 를 쓰기 시작하면 목록에 더하고 다시 실행합니다.
set -euo pipefail
: "${INFRA_ROOT:?INFRA_ROOT 가 필요합니다 (source scripts/toolchain/env.sh)}"
BASE="https://raw.githubusercontent.com/datreeio/CRDs-catalog/main"
SCHEMAS=(
  argoproj.io/rollout_v1alpha1                 # 예: Argo Rollouts Rollout
  argoproj.io/analysistemplate_v1alpha1        # 예: Argo Rollouts AnalysisTemplate
  argoproj.io/application_v1alpha1             # 예: Argo CD Application
  argoproj.io/appproject_v1alpha1              # 예: Argo CD AppProject
  kyverno.io/clusterpolicy_v1                  # 예: Kyverno ClusterPolicy
  external-secrets.io/secretstore_v1           # 예: External Secrets SecretStore
  external-secrets.io/externalsecret_v1        # 예: External Secrets ExternalSecret
  monitoring.coreos.com/servicemonitor_v1      # 예: Prometheus Operator ServiceMonitor
  gateway.networking.k8s.io/httproute_v1       # 예: Gateway API HTTPRoute
)
for s in "${SCHEMAS[@]}"; do
  out="$INFRA_ROOT/gitops/schemas/$s.json"; mkdir -p "$(dirname "$out")"
  curl -sSfL -o "$out" "$BASE/$s.json" && printf 'VENDORED %s (%s bytes)\n' "$s" "$(wc -c < "$out" | tr -d ' ')" # 예: VENDORED argoproj.io/rollout_v1alpha1 (277391 bytes)
done
echo "SCHEMAS_OK ${#SCHEMAS[@]} files under $INFRA_ROOT/gitops/schemas" # 예: SCHEMAS_OK 9 files …
