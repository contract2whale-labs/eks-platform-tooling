#!/usr/bin/env bash
# tests/e2e/mesh/scripts/deploy-probes.sh
# 서비스 메시: 검사 Deployment 4개(checks/mesh-probes.yaml)를 실제 Kubernetes 에 만듭니다. 사내 승인된 Python 3 image 를 @sha256 digest 로 입력합니다 (클러스터 공통 서비스 와 같은 PROBE_IMAGE).
# 정리: 출력한 MESH_PROBE_RUN_ID label에 해당하는 이번 실행 Deployment만 두 namespace에서 삭제합니다.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)    # 예: <INFRA_ROOT>/tests/e2e/mesh
: "${KUBE_CONTEXT:?Set the intended EKS context}"        # 예: 비어 있으면 중단 (work/lab.env 의 DEV_KUBE_CONTEXT)
: "${PROBE_IMAGE:?Set an approved Python 3 image reference pinned with @sha256 digest}" # 예: public.ecr.aws/docker/library/python@sha256:<64자리>
[[ "$PROBE_IMAGE" =~ @sha256:[a-f0-9]{64}$ ]] || { echo 'Image digest required' >&2; exit 1; } # 예: 태그 대신 digest 를 요구
for NS in team-mesh-check team-mesh-outside; do          # 예: 공유 namespaces Application과 mesh-policy identities가 먼저 적용되어 있어야 함
  kubectl --context "$KUBE_CONTEXT" get namespace "$NS" -o name > /dev/null || { echo "namespace $NS not found: wait for the namespaces Application first" >&2; exit 1; }
done
mkdir -p "$ROOT/local-inputs"
WORK=$(mktemp -d)
RUN_ID=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
CREATION_STARTED=false
echo "MESH_PROBE_RUN_ID=$RUN_ID" # 실패 정리가 불완전해도 이 실행을 식별합니다.
RENDERED="$ROOT/local-inputs/mesh-probes-$RUN_ID.yaml"
cleanup() {
  result=$?
  rm -rf "$WORK"
  if [ "$result" -ne 0 ] && [ "$CREATION_STARTED" = true ]; then
    for NS in team-mesh-check team-mesh-outside; do
      kubectl --context "$KUBE_CONTEXT" -n "$NS" delete deployment -l "platform.example/mesh-probe-run=$RUN_ID" --ignore-not-found || echo 'MESH_CLEANUP_INCOMPLETE: inspect this run diagnostic workloads' >&2
    done
  fi
  exit "$result"
}
trap cleanup EXIT
cp "$ROOT/checks/mesh-probes.yaml" "$ROOT/checks/kustomization.yaml" "$WORK/"
(cd "$WORK" && kustomize edit set image "platform-probe=$PROBE_IMAGE")
(cd "$WORK" && kustomize edit add label "platform.example/mesh-probe-run:$RUN_ID")
# Existing names and lookup failures stop before creation. create refuses a competing run.
for MESH_DEPLOY in team-mesh-check/mesh-server team-mesh-check/mesh-client team-mesh-check/mesh-stranger team-mesh-outside/mesh-outside; do
  existing=$(kubectl --context "$KUBE_CONTEXT" -n "${MESH_DEPLOY%%/*}" get "deployment/${MESH_DEPLOY##*/}" --ignore-not-found -o name) || exit 2
  [ -z "$existing" ] || { echo "MESH_EXISTING_OBJECT: $existing; inspect ownership before another run" >&2; exit 2; }
done
kustomize build "$WORK" > "$RENDERED"
# Isolated diagnostic workloads only; the next verification stage needs the same live connections.
CREATION_STARTED=true
printf 'MESH_PROBE_RUN_ID=%s\n' "$RUN_ID" >&2 # 생성·실패 정리 전에 실행 ID를 남깁니다.
kubectl --context "$KUBE_CONTEXT" create -f "$RENDERED"
for MESH_DEPLOY in team-mesh-check/mesh-server team-mesh-check/mesh-client team-mesh-check/mesh-stranger team-mesh-outside/mesh-outside; do
  kubectl --context "$KUBE_CONTEXT" -n "${MESH_DEPLOY%%/*}" rollout status "deployment/${MESH_DEPLOY##*/}" --timeout=180s # 예: 180s (Pod 가 뜰 때까지)
done
echo "Rendered manifest: $RENDERED"
for NS in team-mesh-check team-mesh-outside; do
  echo "Cleanup: kubectl --context $KUBE_CONTEXT -n $NS delete deployment -l platform.example/mesh-probe-run=$RUN_ID --ignore-not-found"
done
