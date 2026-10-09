#!/usr/bin/env bash
# platform/environments/dev/observability/scripts/check-collection-boundary.sh
# 수집이 막혔을 때의 판정: 수집 경계 5가지(송신 정책 존재 · 수집 포트 도달 · 미허용 대상 차단 · 에이전트 권한 범위 · hostPath 쓰기 거부)만 판정합니다. 앱 기능 판정과 섞지 않습니다. 읽기 조회와 서버 쪽 시험 적용(--dry-run=server)만 쓰며 자원을 만들지 않습니다.
# 판정 PASS / FAIL / INCONCLUSIVE = 종료 코드 0 / 1 / 2. 확인하지 못한 것은 실패가 아니라 보류(INCONCLUSIVE)입니다. 근거는 local-inputs/collection-boundary-evidence.tsv 에 남깁니다 (커밋하지 않음).
# 원본 core/scripts/check-collection-boundary.sh 의 셸 버전이며 SelfSubjectRulesReview + Python 해석 대신 kubectl auth can-i 를 네임스페이스마다 씁니다 (결정 8). 앱 자리 Pod 안의 python3 -c 는 클러스터 보안 기반 check-network.sh 와 같은 방식입니다.
# 사용: KUBE_CONTEXT=<context> PROBE_IMAGE=<저장소@sha256:64자리> scripts/check-collection-boundary.sh
set -uo pipefail # 예: -e 없음 (거부가 정상인 조회의 0 이 아닌 종료를 판정으로 다룸)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)                 # 예: <INFRA_ROOT>/platform/environments/dev/observability
APP_NAMESPACE="${APP_NAMESPACE:-team-platform-check}"                # 예: team-platform-check (클러스터 보안 기반 검사 네임스페이스; 60-application-egress.yaml 의 대상)
COLLECTION_NAMESPACE="${COLLECTION_NAMESPACE:-observability}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-collection-gateway}"             # 예: collection-gateway (30-gateway-service.yaml)
AGENT_SERVICE_ACCOUNT="${AGENT_SERVICE_ACCOUNT:-collection-agent}"   # 예: collection-agent (61-collector-rbac.yaml)
APP_PROBE="${APP_PROBE:-deployment/policy-client}"                   # 예: deployment/policy-client (클러스터 보안 기반 checks/network-probes.yaml 의 client Pod)
EVIDENCE="$ROOT/local-inputs/collection-boundary-evidence.tsv"       # 예: 판정 근거 (result · name · detail)
VERDICT=PASS # 예: PASS (검사 결과에 따라 FAIL 또는 INCONCLUSIVE 로 바뀜)
RESULTS=()   # 예: 검사마다 한 줄

# 이전 실행 증거는 호출자가 먼저 보존합니다. 이번 시도는 입력 검사 전 빈 파일로 시작합니다.
umask 077
mkdir -p "$ROOT/local-inputs" || { echo 'Cannot prepare evidence directory' >&2; exit 2; }
: > "$EVIDENCE" || { echo 'Cannot invalidate earlier evidence' >&2; exit 2; }
# 입력이 없으면 실패가 아니라 보류입니다.
if [ -z "${KUBE_CONTEXT:-}" ] || [ -z "${PROBE_IMAGE:-}" ]; then
  echo 'INCONCLUSIVE'
  echo 'Set KUBE_CONTEXT and PROBE_IMAGE before running this gate' >&2
  exit 2
fi
if ! [[ "$PROBE_IMAGE" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
  echo 'INCONCLUSIVE'; echo 'PROBE_IMAGE must have a complete sha256 digest' >&2; exit 2
fi
K=(kubectl --context "$KUBE_CONTEXT")

record() { # 예: record <PASS|FAIL|INCONCLUSIVE> <검사 이름> <설명>
  RESULTS+=("$1	$2	$3")
  case "$1" in
    FAIL) VERDICT=FAIL ;;                                             # 예: 확인된 실패는 보류보다 우선
    INCONCLUSIVE) [ "$VERDICT" = FAIL ] || VERDICT=INCONCLUSIVE ;;    # 예: 이미 FAIL 이면 그대로
  esac
  printf '%-13s %-16s %s\n' "$1" "$2" "$3"
}

if ! FOUND=$("${K[@]}" -n "$APP_NAMESPACE" get networkpolicy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); then
  record INCONCLUSIVE policy-present "cannot read the network policy list"
else
  MISSING=''
  for NAME in default-deny-egress allow-dns-egress allow-telemetry-egress; do
    printf '%s\n' "$FOUND" | grep -qx "$NAME" || MISSING="$MISSING $NAME"
  done
  if [ -n "$MISSING" ]; then record FAIL policy-present "missing:$MISSING"; else record PASS policy-present "all three egress policies exist"; fi
fi

# 2 · 3 은 앱 자리 Pod 과 대상 주소가 있어야 판정할 수 있습니다.
TARGET_QUERY_OK=true
if ! READY=$("${K[@]}" -n "$APP_NAMESPACE" get "$APP_PROBE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null); then TARGET_QUERY_OK=false; READY=''; fi
if ! GATEWAY_IP=$("${K[@]}" -n "$COLLECTION_NAMESPACE" get svc "$GATEWAY_SERVICE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null); then TARGET_QUERY_OK=false; GATEWAY_IP=''; fi
if ! DENY_IP=$("${K[@]}" -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null); then TARGET_QUERY_OK=false; DENY_IP=''; fi
probe_connect() { # 예: probe_connect <주소> <포트> → 종료 0 도달 · 3 시간 초과 · 4 그 밖의 오류 (클러스터 보안 기반 check-network.sh 와 같은 Pod 안 python3)
  "${K[@]}" -n "$APP_NAMESPACE" exec "$APP_PROBE" -- python3 -c 'import socket,sys
s = socket.socket(); s.settimeout(5)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
except TimeoutError:
    sys.exit(3)
except OSError:
    sys.exit(4)
sys.exit(0)' "$1" "$2" > /dev/null 2>&1
}
# 2. 앱이 수집 포트(4317)로 나갈 수 있는지 봅니다.
if [ "$TARGET_QUERY_OK" != true ] || [ -z "${READY:-}" ] || [ "$READY" = 0 ]; then
  record INCONCLUSIVE egress-allowed "the destination/probe lookup failed or the probe is not ready"
elif [ -z "$GATEWAY_IP" ]; then
  record INCONCLUSIVE egress-allowed "the collection gateway service does not exist yet"
else
  probe_connect "$GATEWAY_IP" 4317
  case "$?" in
    0) record PASS egress-allowed "reached the collection port 4317" ;;
    3) record FAIL egress-allowed "cannot reach the collection port 4317" ;;
    *) record INCONCLUSIVE egress-allowed "the connection attempt did not yield a verdict" ;;
  esac
fi
# 3. 허용하지 않은 대상(API 서버 ClusterIP:443)으로는 나갈 수 없는지 봅니다. 시간 초과는 이 표본의 비도달이며 정책이 원인이라는 단독 증거는 아닙니다.
if [ "$TARGET_QUERY_OK" != true ] || [ -z "${READY:-}" ] || [ "$READY" = 0 ] || [ -z "$DENY_IP" ]; then
  record INCONCLUSIVE egress-denied "no probe pod or no target address for the deny check"
else
  probe_connect "$DENY_IP" 443
  case "$?" in
    3) record PASS egress-denied "the disallowed destination stayed blocked" ;;
    0) record FAIL egress-denied "the disallowed destination was reachable" ;;
    *) record INCONCLUSIVE egress-denied "the connection attempt did not yield a verdict" ;;
  esac
fi

# 4. 에이전트 신원: Pod 목록은 읽을 수 있어야 하고(yes) 모든 네임스페이스에서 Secret 읽기(get · list · watch)는 no 여야 합니다.
AGENT_USER="system:serviceaccount:${COLLECTION_NAMESPACE}:${AGENT_SERVICE_ACCOUNT}" # 예: system:serviceaccount:observability:collection-agent
# auth can-i: yes/0와 no/1만 판정으로 사용합니다. 부분 출력 뒤 일반 오류는 UNKNOWN입니다.
authorization_answer() {
  local answer rc
  answer=$("${K[@]}" auth can-i "$@" --as="$AGENT_USER" 2>/dev/null); rc=$?
  case "$rc:$answer" in
    0:yes) printf 'yes' ;;
    1:no) printf 'no' ;;
    *) printf 'UNKNOWN' ;;
  esac
}
CAN_PODS=$(authorization_answer list pods --all-namespaces)
SECRET_ALLOWED='' SECRET_UNKNOWN=''
if NAMESPACES=$("${K[@]}" get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null) && [ -n "$NAMESPACES" ]; then
  for NS in $NAMESPACES; do
    for VERB in get list watch; do
      ANSWER=$(authorization_answer "$VERB" secrets -n "$NS")
      case "$ANSWER" in
        yes) SECRET_ALLOWED="$SECRET_ALLOWED $NS/$VERB" ;;
        no) : ;;
        *) SECRET_UNKNOWN="$SECRET_UNKNOWN $NS/$VERB" ;;
      esac
    done
  done
else
  SECRET_UNKNOWN='namespace-list-unavailable'
fi
if [ "$CAN_PODS" = no ] || [ -n "$SECRET_ALLOWED" ]; then
  record FAIL agent-scope "pods-list=$CAN_PODS secret-read-allowed:${SECRET_ALLOWED:-none}"
elif [ "$CAN_PODS" != yes ] || [ -n "$SECRET_UNKNOWN" ]; then
  record INCONCLUSIVE agent-scope "authorization incomplete:${SECRET_UNKNOWN:-pods-list}"
else
  record PASS agent-scope "pods list allowed; Secret get/list/watch denied in all checked namespaces"
fi

# 5. 승인 정책(62-collector-admission.yaml)이 쓰기 가능한 hostPath 마운트를 막는지 봅니다. 읽기 전용 대조군이 먼저 통과해야 판정합니다.
DENIED_INPUT="$ROOT/local-inputs/collection-hostpath-denied.yaml"
ALLOWED_INPUT="$ROOT/local-inputs/collection-hostpath-allowed.yaml"
write_probe_pod() { # 예: write_probe_pod <파일> <이름> <마운트 줄>
  cat > "$1" <<POD
apiVersion: v1
kind: Pod
metadata:
  name: $2
spec:
  serviceAccountName: ${AGENT_SERVICE_ACCOUNT}
  containers:
    - name: probe
      image: ${PROBE_IMAGE}
      command: ["sleep", "1"]
      volumeMounts:
        - $3
  volumes:
    - name: hostlogs
      hostPath: {path: /var/log, type: Directory}
POD
}
write_probe_pod "$DENIED_INPUT" collection-hostpath-denied '{name: hostlogs, mountPath: /var/log}'
write_probe_pod "$ALLOWED_INPUT" collection-hostpath-allowed '{name: hostlogs, mountPath: /var/log, readOnly: true}'
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
if ! "${K[@]}" -n "$COLLECTION_NAMESPACE" apply --dry-run=server -f "$ALLOWED_INPUT" > /dev/null 2> "$ERR"; then
  record INCONCLUSIVE hostpath-denied "the read-only host path control was not admitted"
elif "${K[@]}" -n "$COLLECTION_NAMESPACE" apply --dry-run=server -f "$DENIED_INPUT" > /dev/null 2> "$ERR"; then
  record FAIL hostpath-denied "a writable host path pod was admitted"
elif grep -q 'mount host log paths read-only' "$ERR"; then
  record PASS hostpath-denied "read-only control admitted; writable host path denied by the expected policy"
else
  record INCONCLUSIVE hostpath-denied "denied but not by the expected policy message"
fi

# 판정과 근거를 파일로 남깁니다 (실행 화면은 사라져도 파일은 남음).
{
  printf 'checked_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'scope\tCollection boundary only. Application behaviour and storage retention are judged elsewhere.\n'
  printf 'verdict\t%s\n' "$VERDICT"
  printf 'app_namespace\t%s\ncollection_namespace\t%s\n' "$APP_NAMESPACE" "$COLLECTION_NAMESPACE"
  printf 'result\tname\tdetail\n'
  printf '%s\n' "${RESULTS[@]}"
} > "$EVIDENCE" || { echo 'Cannot save the current evidence file' >&2; [ "$VERDICT" = FAIL ] || VERDICT=INCONCLUSIVE; }
echo "$VERDICT"
case "$VERDICT" in
  PASS) exit 0 ;; # 예: 0 (다섯 검사가 모두 확인되고 기대와 같음)
  FAIL) exit 1 ;; # 예: 1 (확인된 실패가 있음)
  *) exit 2 ;;    # 예: 2 (확인하지 못한 검사가 있음)
esac
