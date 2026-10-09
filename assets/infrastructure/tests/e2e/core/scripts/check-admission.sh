#!/usr/bin/env bash
# tests/e2e/core/scripts/check-admission.sh
# 클러스터 공통 서비스: 실제 API server에서 Service CEL 정책의 허용·거부를 확인합니다. PSA 판정은 별도 Pod 검사로 확인합니다. dry-run=server라 객체는 저장되지 않습니다.
set -euo pipefail                                        # 예: 오류 · 미정의 변수 · 파이프 실패에서 즉시 중단
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)    # 예: <INFRA_ROOT>/tests/e2e/core (script 위치의 한 단계 위)
: "${KUBE_CONTEXT:?Set the intended EKS context}"        # 예: 값이 없으면 메시지와 함께 종료
kubectl --context "$KUBE_CONTEXT" apply --dry-run=server -f "$ROOT/checks/allowed-service.yaml" # 예: 통과해야 하는 요청 (created (server dry run))
# 어떤 실패든 성공으로 착각하지 않도록 기대한 VAP message 도 확인합니다.
ERR=$(mktemp)                                            # 예: /tmp/tmp.AbCdEf (표준 오류를 모을 임시 파일)
trap 'rm -f "$ERR"' EXIT                                 # 예: script 가 끝날 때 임시 파일을 지움
if kubectl --context "$KUBE_CONTEXT" apply --dry-run=server -f "$ROOT/checks/denied-service.yaml" 2>"$ERR"; then # 예: 통과하면 비정상
  echo 'FAIL: LoadBalancer Service unexpectedly allowed' >&2; exit 1 # 예: 거부되지 않았으므로 실패로 끝냄
fi
grep -q 'Tenant services must use ClusterIP' "$ERR" || { cat "$ERR" >&2; exit 1; } # 예: 기대한 정책 메시지가 없으면 실패 (권한 부족 · 연결 실패와 구분)
echo 'PASS: allowed ClusterIP, denied tenant LoadBalancer via expected policy' # 예: 두 판정을 모두 통과한 경우
