#!/usr/bin/env bash
# tests/e2e/mesh/scripts/probe-connect.sh
# 서비스 메시: 검사 Pod 안에서 mesh-server 의 ClusterIP:8080 에 새 TCP 연결을 만들고 응답 바이트까지 읽어 세 가지로 분류합니다.
#   REACHED (0)      : HTTP 응답을 받음 — 평문 또는 허용된 신분으로 도달 (src=<출발 주소:포트> 를 함께 출력; ztunnel 로그 대조용)
#   CLOSED (1)       : 응답 없이 연결이 닫힘(reset · EOF) — STRICT 또는 AuthorizationPolicy 거부의 관찰. 원인은 받는 쪽 ztunnel 로그로 확정
#   INCONCLUSIVE (2) : 시간 초과 · 연결 거절 등 — 대상 준비 상태와 네트워크를 먼저 조사 (거부로 세지 않음)
# connect 성공만으로 도달을 판정하지 않습니다 (받는 쪽 대리자가 연결을 먼저 받으므로 응답 바이트까지 읽어야 합니다).
# 사용: probe-connect.sh <네임스페이스> <Deployment 이름>   예: probe-connect.sh team-mesh-outside mesh-outside
set -uo pipefail                                         # 예: -e 없음 (닫힘 · 보류가 정상 결과인 실행)
: "${KUBE_CONTEXT:?Set the intended EKS context}"        # 예: work/lab.env 의 DEV_KUBE_CONTEXT
PROBE_NAMESPACE="${1:?namespace of the probe deployment}" # 예: team-mesh-outside
PROBE_DEPLOYMENT="${2:?name of the probe deployment}"     # 예: mesh-outside
SERVER_NAMESPACE="${SERVER_NAMESPACE:-team-mesh-check}"   # 예: team-mesh-check (받는 쪽 네임스페이스)
SERVER_SERVICE="${SERVER_SERVICE:-mesh-server}"           # 예: mesh-server (받는 쪽 Service)
SERVER_PORT="${SERVER_PORT:-8080}"                        # 예: 8080
if SERVER_IP=$(kubectl --context "$KUBE_CONTEXT" -n "$SERVER_NAMESPACE" get svc "$SERVER_SERVICE" -o jsonpath='{.spec.clusterIP}' 2> /dev/null); then :; else echo 'INCONCLUSIVE: Service lookup failed'; exit 2; fi # 예: 10.100.12.34 (이름 해석 실패가 판정에 섞이지 않도록 주소로 접속)
[ -n "$SERVER_IP" ] || { echo "INCONCLUSIVE: service ${SERVER_NAMESPACE}/${SERVER_SERVICE} has no clusterIP"; exit 2; }
# 검사 Pod 의 image 가 Python 3 이므로(클러스터 공통 서비스 와 같은 PROBE_IMAGE) 연결 시도만 그 안의 python3 로 합니다. 작업 PC 의 Python 은 쓰지 않습니다.
# kubectl 자체의 실패(exec 권한 없음 · API 오류 · stream 실패)도 종료 코드가 1 이라 코드만으로는 "연결이 닫혔다" 와 구분되지 않습니다.
# 그래서 출력을 받아 두고, Pod 안의 검사가 직접 낸 판정 줄(REACHED · CLOSED · INCONCLUSIVE)이 종료 코드와 맞을 때만 그 결과를 돌려줍니다.
OUTPUT=$(kubectl --context "$KUBE_CONTEXT" -n "$PROBE_NAMESPACE" exec "deployment/${PROBE_DEPLOYMENT}" -- \
  python3 -c 'import socket, sys
s = socket.socket(); s.settimeout(5)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    src = s.getsockname()
    s.sendall(b"GET / HTTP/1.0\r\nHost: mesh-check\r\n\r\n")
    data = s.recv(128)
except (ConnectionResetError, BrokenPipeError):
    print("CLOSED: reset or broken pipe; inspect receiver ztunnel logs"); sys.exit(1)
except OSError as exc:
    print("INCONCLUSIVE: " + type(exc).__name__); sys.exit(2)
if data.startswith(b"HTTP/"):
    print("REACHED: " + data.split(b"\r\n", 1)[0].decode(errors="replace") + " src=%s:%d" % src); sys.exit(0)
if data:
    print("REACHED: non-HTTP response " + repr(data[:32]) + " src=%s:%d" % src); sys.exit(0)
print("CLOSED: EOF without response; inspect receiver ztunnel logs"); sys.exit(1)' "$SERVER_IP" "$SERVER_PORT" 2>&1)
RC=$?
VERDICT=$(printf '%s\n' "$OUTPUT" | grep -E '^(REACHED|CLOSED|INCONCLUSIVE): ' | tail -n 1)
case "$RC:${VERDICT%%:*}" in
  0:REACHED | 1:CLOSED | 2:INCONCLUSIVE) echo "$VERDICT"; exit "$RC" ;; # 예: 검사가 실제로 실행되어 낸 결과
  *) echo "INCONCLUSIVE: the probe did not run to a verdict (kubectl rc=$RC): $(printf '%s' "$OUTPUT" | tail -n 1 | cut -c1-160)"; exit 2 ;; # 예: Forbidden · API 오류 — 거부로 세지 않음
esac
