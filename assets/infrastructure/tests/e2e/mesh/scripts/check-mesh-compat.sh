#!/usr/bin/env bash
# tests/e2e/mesh/scripts/check-mesh-compat.sh
# 서비스 메시: 설치 전 호환성을 읽기 조회로만 확인해 표와 판정 한 줄을 냅니다. 클러스터를 바꾸지 않습니다 (원본 check-mesh-compat.py 의 셸 대체).
# 판정 세 값: PASS(0) · FAIL(1) · INCONCLUSIVE(2). 조회 실패는 실패가 아니라 보류입니다. 통과로 세지 않습니다.
# 사용: check-mesh-compat.sh --context <kube context> [--allow-existing-cni] [--tolerated key=value:effect ...]
set -uo pipefail                                         # 예: -e 는 넣지 않음 (조회 실패를 보류로 기록해야 하므로 즉시 종료하지 않음)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)    # 예: <INFRA_ROOT>/tests/e2e/mesh
# shellcheck source=../versions.env
source "$ROOT/versions.env" || { echo 'MESH_COMPAT_INCONCLUSIVE: versions.env를 읽지 못했습니다'; exit 2; } # 예: ISTIO_SUPPORTED_KUBERNETES · MESH_GATEWAY_CLASS_NAME 등을 읽음

CONTEXT=""                                               # 예: --context 로 받는 kube context (필수; 현재 context 를 자동으로 쓰지 않음)
ALLOW_EXISTING_CNI=false                                 # 예: false (이 과정이 소유한 기존 istio-cni 갱신 때만 --allow-existing-cni)
TOLERATED=()                                             # 예: 노드 대리자가 견딜 taint 목록 (비우면 아래 기본 2개)
while [ $# -gt 0 ]; do
  case "$1" in
    --context | --tolerated)                             # 예: 값을 하나 받는 옵션 (값이 빠지면 shift 2 가 실패해 같은 인자를 계속 읽으므로 먼저 확인)
      [ $# -ge 2 ] || { echo 'INCONCLUSIVE'; echo "$1 needs a value" >&2; exit 2; }
      if [ "$1" = --context ]; then CONTEXT="$2"; else TOLERATED+=("$2"); fi
      shift 2 ;;
    --allow-existing-cni) ALLOW_EXISTING_CNI=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CONTEXT" ] || { echo 'INCONCLUSIVE'; echo 'Pass --context <kube context> (work/lab.env 의 DEV_KUBE_CONTEXT)' >&2; exit 2; }
[ "${#TOLERATED[@]}" -gt 0 ] || TOLERATED=(workload=observability:NoSchedule workload=kafka:NoSchedule) # 예: 모니터링과 Kafka 노드 그룹의 taint

SEEN_FAIL=false
SEEN_INCONCLUSIVE=false
ROWS=()
k() { kubectl --context "$CONTEXT" --request-timeout=30s "$@" < /dev/null 2> /dev/null; } # 예: 모든 조회는 명시한 context 로, 30초 제한
record() {                                               # 예: record <항목> <읽은 값> <판정>
  ROWS+=("$1 -> $2 -> $3")
  case "$3" in FAIL) SEEN_FAIL=true ;; INCONCLUSIVE) SEEN_INCONCLUSIVE=true ;; esac
}

# 1. 클러스터 버전이 versions.env 의 지원 목록 안에 있는지 봅니다.
if SERVER=$(k version | awk '/^Server Version:/ {print $3}' | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/'); then VERSION_QUERY=ok; else VERSION_QUERY=failed; fi # 예: v1.36.3-eks-abc → 1.36
if [ "$VERSION_QUERY" != ok ] || [ -z "$SERVER" ]; then
  record '클러스터 버전' '조회 실패: kubectl version' INCONCLUSIVE
elif [ -z "${ISTIO_SUPPORTED_KUBERNETES:-}" ]; then
  record '클러스터 버전' "$SERVER · versions.env 의 지원 목록 미확정" INCONCLUSIVE
else
  case " $ISTIO_SUPPORTED_KUBERNETES " in
    *" $SERVER "*) record '클러스터 버전' "$SERVER · 지원 $(echo "$ISTIO_SUPPORTED_KUBERNETES" | tr ' ' ',')" PASS ;;
    *) record '클러스터 버전' "$SERVER · 지원 $(echo "$ISTIO_SUPPORTED_KUBERNETES" | tr ' ' ',')" FAIL ;;
  esac
fi

# 2. 네트워크 플러그인: aws-node 가 있고 메시 CNI(istio-cni-node)가 없어야 첫 설치입니다. 있으면 이 과정의 Argo Application 소유인지 봅니다.
if DAEMONSETS=$(k get daemonset -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); then DAEMONSET_QUERY=ok; else DAEMONSET_QUERY=failed; fi
if [ "$DAEMONSET_QUERY" != ok ] || [ -z "$DAEMONSETS" ]; then
  record '네트워크 플러그인' '조회 실패: daemonset 목록' INCONCLUSIVE
elif ! printf '%s\n' "$DAEMONSETS" | grep -qx 'kube-system/aws-node'; then
  record '네트워크 플러그인' 'aws-node를 찾지 못했습니다' INCONCLUSIVE
elif printf '%s\n' "$DAEMONSETS" | grep -qx 'istio-system/istio-cni-node'; then
  if OWNER=$(k -n istio-system get daemonset istio-cni-node \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'); then OWNER_QUERY=ok; else OWNER_QUERY=failed; fi # 예: istio-cni/istio-system
  if [ "$OWNER_QUERY" != ok ]; then
    record '네트워크 플러그인' '기존 CNI 소유권 조회 실패' INCONCLUSIVE
  elif [ "$OWNER" = 'platform-istio-cni-dev:apps/DaemonSet:istio-system/istio-cni-node' ] && [ "$ALLOW_EXISTING_CNI" = true ]; then
    record '네트워크 플러그인' '기존 CNI 소유권 확인' PASS
  elif [ "$OWNER" = 'platform-istio-cni-dev:apps/DaemonSet:istio-system/istio-cni-node' ]; then
    record '네트워크 플러그인' '기존 CNI 소유권 확인 · --allow-existing-cni 없이 실행' INCONCLUSIVE
  else
    record '네트워크 플러그인' "기존 CNI 소유권 불일치: ${OWNER:-없음}" INCONCLUSIVE
  fi
elif printf '%s\n' "$DAEMONSETS" | grep -qx 'kube-system/aws-node'; then
  record '네트워크 플러그인' 'aws-node · 메시 플러그인 없음' PASS
else
  record '네트워크 플러그인' "아는 이름이 없음: $(printf '%s\n' "$DAEMONSETS" | sort | tr '\n' ',')" INCONCLUSIVE
fi

# 3. GatewayClass: 자원 종류가 없으면(Gateway 관련 구성 전) 통과, 있으면 이름 · controllerName 충돌만 봅니다.
if ! CRD=$(kubectl --context "$CONTEXT" --request-timeout=30s get crd gatewayclasses.gateway.networking.k8s.io --ignore-not-found -o name < /dev/null 2> /dev/null); then
  record '기존 GatewayClass' '조회 실패: CRD 목록' INCONCLUSIVE
elif [ -z "$CRD" ]; then
  record '기존 GatewayClass' '자원 종류 없음 · Gateway 구성이 아직 없습니다' PASS
else
  if ! CLASSES=$(k get gatewayclass -o jsonpath='{range .items[*]}{.metadata.name}={.spec.controllerName}{"\n"}{end}'); then # 예: platform=gateway.envoyproxy.io/gatewayclass-controller
    record '기존 GatewayClass' '조회 실패 · 자원 종류는 있으나 읽지 못했습니다' INCONCLUSIVE
  elif printf '%s\n' "$CLASSES" | grep -q "^${MESH_GATEWAY_CLASS_NAME}="; then
    record '기존 GatewayClass' "이름 충돌: $MESH_GATEWAY_CLASS_NAME" FAIL
  elif printf '%s\n' "$CLASSES" | grep -q "=${MESH_GATEWAY_CONTROLLER_NAME}$"; then
    record '기존 GatewayClass' "controllerName 충돌: $MESH_GATEWAY_CONTROLLER_NAME" FAIL
  else
    EDGE=$(printf '%s\n' "$CLASSES" | awk -F= -v n="$EDGE_GATEWAY_CLASS" '$1 == n {print $2}')
    record '기존 GatewayClass' "$(printf '%s\n' "$CLASSES" | grep -c '=')개 · Gateway ${EDGE_GATEWAY_CLASS}=${EDGE:-없음}" PASS
  fi
fi

# 4. 노드 taint: 노드의 taint 전부가 견디는 목록 안에 있어야 합니다 (값 · effect 까지 같은 문자열로 대조).
# 노드 이름과 taint 를 조회 한 번으로 받습니다 — 두 번 나눠 부르면 둘째 조회만 실패했을 때 빈 taint 목록이 "0종 전부 견딤" 으로 읽힙니다.
if NODE_ROWS=$(k get nodes -o jsonpath='{range .items[*]}node/{.metadata.name}{"\n"}{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}{end}'); then NODE_QUERY=ok; else NODE_QUERY=failed; fi
NODE_COUNT=$(printf '%s\n' "$NODE_ROWS" | grep -c '^node/')
TAINTS=$(printf '%s\n' "$NODE_ROWS" | grep -v '^node/' | grep '=' | sort -u) # 예: workload=kafka:NoSchedule
if [ "$NODE_QUERY" != ok ] || [ "$NODE_COUNT" -eq 0 ]; then
  record '노드 taint' '조회 실패 또는 노드 목록이 비어 있습니다' INCONCLUSIVE
else
  MISSING=""
  for taint in $TAINTS; do
    case " ${TOLERATED[*]} " in *" $taint "*) ;; *) MISSING="${MISSING:+$MISSING,}$taint" ;; esac
  done
  if [ -n "$MISSING" ]; then
    record '노드 taint' "견디지 못하는 값: $MISSING" FAIL
  else
    record '노드 taint' "노드 ${NODE_COUNT}대 · taint $(printf '%s' "$TAINTS" | grep -c '=')종 전부 견딤" PASS
  fi
fi

printf '항목 -> 확인한 증거 -> 판정\n'
printf '%s\n' "${ROWS[@]}"
if [ "$SEEN_FAIL" = true ]; then echo 'MESH_COMPAT_FAIL: 설치를 시작하지 않습니다'; exit 1; fi
if [ "$SEEN_INCONCLUSIVE" = true ]; then echo 'MESH_COMPAT_INCONCLUSIVE: 확인하지 못한 항목이 있습니다'; exit 2; fi
echo 'MESH_COMPAT_PASS: 읽기 조회 네 항목만 확인했습니다'; exit 0
