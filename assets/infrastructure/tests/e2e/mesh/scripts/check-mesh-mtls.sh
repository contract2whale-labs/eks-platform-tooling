#!/usr/bin/env bash
# tests/e2e/mesh/scripts/check-mesh-mtls.sh
# 서비스 메시: Pod 사이 상호 TLS 경계만 판정합니다. 앱 기능 판정과 합치지 않습니다. 읽기 조회와 검사 Pod 안의 연결 시도만 씁니다. 조회 판정에는 kubectl · grep · awk를 쓰고, 증거 JSON은 Python 표준 json 모듈로 저장합니다.
# 검사 5개: enrolled-ns · strict-mode · plaintext-denied · identity-logged · proxy-per-node. 판정 PASS(0) · FAIL(1) · INCONCLUSIVE(2). 근거는 local-inputs/mesh-mtls-evidence.json.
# gateway-rewrap(Gateway 네임스페이스 편입 · PERMISSIVE 확인)은 Gateway 관련 구성 가 생긴 뒤 추가합니다. 이 시점에는 검사 5개가 전부입니다.
set -uo pipefail                                         # 예: -e 없음 (거부가 정상인 연결 시도의 0 이 아닌 종료 코드를 판정에 씀)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)    # 예: <INFRA_ROOT>/tests/e2e/mesh
MESH_NAMESPACE="${MESH_NAMESPACE:-istio-system}"         # 예: istio-system (노드 대리자 DaemonSet 의 네임스페이스)
NODE_PROXY_DAEMONSET="${NODE_PROXY_DAEMONSET:-ztunnel}"  # 예: ztunnel
ENROLLED_NAMESPACES="${ENROLLED_NAMESPACES:-team-mesh-check}" # 예: 편입되어 있어야 하는 네임스페이스 목록 (공백 구분)
STRICT_NAMESPACES="${STRICT_NAMESPACES:-team-mesh-check}"     # 예: 네임스페이스 전체 STRICT 를 요구하는 목록
SERVER_NAMESPACE="${SERVER_NAMESPACE:-team-mesh-check}"  # 예: team-mesh-check (받는 쪽)
SERVER_SERVICE="${SERVER_SERVICE:-mesh-server}"          # 예: mesh-server (Service 이름 = Deployment 이름)
SERVER_PORT="${SERVER_PORT:-8080}"                       # 예: 8080
CLIENT_PROBE="${CLIENT_PROBE:-mesh-client}"              # 예: mesh-client (허용된 신분의 Deployment)
OUTSIDE_NAMESPACE="${OUTSIDE_NAMESPACE:-team-mesh-outside}" # 예: team-mesh-outside (편입 밖)
OUTSIDE_PROBE="${OUTSIDE_PROBE:-mesh-outside}"           # 예: mesh-outside
CLIENT_IDENTITY="${CLIENT_IDENTITY:-cluster.local/ns/team-mesh-check/sa/mesh-client}" # 예: 기대하는 출발 신분
SERVER_IDENTITY="${SERVER_IDENTITY:-cluster.local/ns/team-mesh-check/sa/mesh-server}" # 예: 기대하는 도착 신분
EVIDENCE="$ROOT/local-inputs/mesh-mtls-evidence.json"    # 예: 판정 근거 파일 (커밋하지 않음)
PROXY_LOG_FILE="$ROOT/local-inputs/mesh-proxy.log"       # 예: 대리자 로그 사본
VERDICT=PASS
RESULTS=()
PROXY_LOG_STATUS=NOT_COLLECTED # 예: 허용 probe가 시작되지 않았거나 응답·주소가 없어 로그를 수집하지 못함
# 이전 실행 사본은 호출자가 먼저 보존합니다. 이번 실행은 빈 파일에서 시작합니다.
umask 077
mkdir -p "$ROOT/local-inputs" || { echo 'Evidence directory could not be prepared' >&2; exit 2; }
: > "$PROXY_LOG_FILE" || { echo 'Proxy log could not be reset' >&2; exit 2; }
: > "$EVIDENCE" || { echo 'Evidence file could not be reset' >&2; exit 2; }
# 입력이 없으면 실패가 아니라 보류입니다. 시작하지 못한 것을 실패로 적지 않습니다. 현재 context 를 자동으로 쓰지 않습니다.
if [ -z "${KUBE_CONTEXT:-}" ]; then
  echo 'INCONCLUSIVE'
  echo 'Set KUBE_CONTEXT before running this gate' >&2
  exit 2
fi
k() { kubectl --context "$KUBE_CONTEXT" --request-timeout=30s "$@" < /dev/null 2> /dev/null; } # 예: 모든 조회는 명시한 context 로; 없을 때의 메시지가 출력에 섞이지 않게 함
record() {                                               # 예: record <결과> <검사 이름> <설명> — 판정 우선순위는 이 함수 한 곳에서만 정함
  RESULTS+=("$1" "$2" "$3")
  case "$1" in
    FAIL) VERDICT=FAIL ;;
    INCONCLUSIVE) [ "$VERDICT" = FAIL ] || VERDICT=INCONCLUSIVE ;;
  esac
  printf '%-13s %-17s %s\n' "$1" "$2" "$3"
}

# 1. enrolled-ns: 편입 label 이 붙은 네임스페이스 목록이 기대를 모두 포함하는지 봅니다. 전체 네임스페이스 수 0 은 조회 실패입니다.
NAMESPACE_QUERY_OK=true
if NS_ROWS=$(k get namespace -o name); then
  NS_TOTAL=$(printf '%s\n' "$NS_ROWS" | grep -c '^namespace/')
else
  NAMESPACE_QUERY_OK=false; NS_TOTAL=0
fi
if ENROLLED_ROWS=$(k get namespace -l istio.io/dataplane-mode=ambient -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); then
  FOUND_NS=$(printf '%s\n' "$ENROLLED_ROWS" | sort | tr '\n' ' ')
else
  NAMESPACE_QUERY_OK=false; FOUND_NS=''
fi
WANT_NS=$(printf '%s\n' ${ENROLLED_NAMESPACES} | sort -u | tr '\n' ' ')
MISSING_NS=""
for NS in ${WANT_NS}; do
  case " $FOUND_NS" in *" $NS "*) ;; *) MISSING_NS="${MISSING_NS:+$MISSING_NS,}$NS" ;; esac
done
if [ "$NAMESPACE_QUERY_OK" != true ] || [ "$NS_TOTAL" -eq 0 ]; then
  record INCONCLUSIVE enrolled-ns "cannot read the namespace list or ambient enrollment labels"
elif [ -z "$MISSING_NS" ]; then
  record PASS enrolled-ns "enrolled namespaces match: ${WANT_NS% }"
else
  record FAIL enrolled-ns "found:[${FOUND_NS% }] expected:[${WANT_NS% }]"
fi

# 2. strict-mode: 강제를 요구하는 네임스페이스마다 selector 없는(네임스페이스 전체) PeerAuthentication 이 정확히 1개이고 STRICT 인지 봅니다.
#    workload 예외(selector 가 있고 UNSET · STRICT 가 아닌 모드)나 포트별 모드가 있으면 유효 모드를 확정하지 않고 보류합니다.
MODE_REPORT=''
MODE_RESULT=PASS
for MESH_NS in ${STRICT_NAMESPACES}; do
  if POLICY_ROWS=$(k -n "$MESH_NS" get peerauthentication -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.selector.matchLabels}{"\t"}{.spec.mtls.mode}{"\t"}{.spec.portLevelMtls}{"\n"}{end}'); then
    # 예: 한 줄 = 이름 <TAB> selector <TAB> mode <TAB> portLevelMtls (비어 있으면 빈 칸)
    POLICY_RESULT=$(printf '%s\n' "$POLICY_ROWS" | awk -F'\t' '
      NF == 0 { next }
      $2 == "" { wide++; if ($3 == "STRICT") strict++ }
      $4 != "" { port++ }
      $2 != "" && $3 != "" && $3 != "UNSET" && $3 != "STRICT" { exception++ }
      END {
        if (wide != 1 || strict != 1) print "FAIL";
        else if (port > 0 || exception > 0) print "INCONCLUSIVE";
        else print "PASS"
      }')
  else
    POLICY_RESULT=INCONCLUSIVE
  fi
  MODE_REPORT="$MODE_REPORT $MESH_NS=$POLICY_RESULT"
  case "$POLICY_RESULT" in
    FAIL) MODE_RESULT=FAIL ;;
    PASS) ;;
    *) [ "$MODE_RESULT" = FAIL ] || MODE_RESULT=INCONCLUSIVE ;;
  esac
done
[ -n "$STRICT_NAMESPACES" ] || MODE_RESULT=INCONCLUSIVE
record "$MODE_RESULT" strict-mode "namespace-wide STRICT configuration:$MODE_REPORT"

# 3 번과 4 번은 검사 Pod 과 대상 주소가 있어야 판정할 수 있습니다. 없는 대상에 연결한 오류를 판정으로 쓰지 않습니다.
TARGET_QUERY_OK=true
if ! SERVER_IP=$(k -n "$SERVER_NAMESPACE" get svc "$SERVER_SERVICE" -o jsonpath='{.spec.clusterIP}'); then TARGET_QUERY_OK=false; fi
if ! SERVER_READY=$(k -n "$SERVER_NAMESPACE" get "deployment/$SERVER_SERVICE" -o jsonpath='{.status.readyReplicas}'); then TARGET_QUERY_OK=false; fi
if ! CLIENT_READY=$(k -n "$SERVER_NAMESPACE" get "deployment/$CLIENT_PROBE" -o jsonpath='{.status.readyReplicas}'); then TARGET_QUERY_OK=false; fi
if ! OUTSIDE_READY=$(k -n "$OUTSIDE_NAMESPACE" get "deployment/$OUTSIDE_PROBE" -o jsonpath='{.status.readyReplicas}'); then TARGET_QUERY_OK=false; fi
if ! OUTSIDE_MODE=$(k get namespace "$OUTSIDE_NAMESPACE" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}'); then TARGET_QUERY_OK=false; fi

# 3. plaintext-denied: 편입 안 된 Pod 에서 평문으로 붙으면 응답 없이 닫혀야 합니다 (probe-connect.sh: 0 도달 · 1 닫힘 · 2 보류).
if [ "$TARGET_QUERY_OK" != true ] || [ -z "$SERVER_IP" ] || [ -z "${SERVER_READY:-}" ] || [ "$SERVER_READY" = 0 ] || [ -z "${OUTSIDE_READY:-}" ] || [ "$OUTSIDE_READY" = 0 ]; then
  record INCONCLUSIVE plaintext-denied "the destination/outside probe lookup failed or is not ready"
elif [ "$OUTSIDE_MODE" = ambient ]; then
  record FAIL plaintext-denied "the outside namespace is enrolled; this is not a plaintext control"
else
  SERVER_NAMESPACE="$SERVER_NAMESPACE" SERVER_SERVICE="$SERVER_SERVICE" SERVER_PORT="$SERVER_PORT" \
    bash "$ROOT/scripts/probe-connect.sh" "$OUTSIDE_NAMESPACE" "$OUTSIDE_PROBE" > /dev/null 2>&1
  case "$?" in
    1) record PASS plaintext-denied "the plaintext connection closed without response; correlate receiver logs" ;;
    0) record FAIL plaintext-denied "the plaintext connection reached the destination" ;;
    *) record INCONCLUSIVE plaintext-denied "the connection attempt did not yield a verdict" ;;
  esac
fi

# 4. identity-logged: 허용된 신분으로 응답을 받은 연결의 출발 주소 · 포트와 같은 outbound 기록 한 줄에 양쪽 신분이 있는지 봅니다.
PROBE_START=$(date -u +'%Y-%m-%dT%H:%M:%SZ')             # 예: 요청 직전 UTC 시각 (이후 기록만 읽음)
PROBE_OUT=''
PROBE_RC=2
if [ "$TARGET_QUERY_OK" = true ] && [ -n "$SERVER_IP" ] && [ -n "${SERVER_READY:-}" ] && [ "$SERVER_READY" != 0 ] && [ -n "${CLIENT_READY:-}" ] && [ "$CLIENT_READY" != 0 ]; then
  PROBE_OUT=$(SERVER_NAMESPACE="$SERVER_NAMESPACE" SERVER_SERVICE="$SERVER_SERVICE" SERVER_PORT="$SERVER_PORT" \
    bash "$ROOT/scripts/probe-connect.sh" "$SERVER_NAMESPACE" "$CLIENT_PROBE" 2> /dev/null) # 예: REACHED: HTTP/1.0 200 OK src=172.20.10.51:45678
  PROBE_RC=$?
fi
PROBE_SRC=$(printf '%s\n' "$PROBE_OUT" | sed -n 's/.* src=\([0-9.:]*\)$/\1/p')             # 예: 172.20.10.51:45678
if [ "$PROBE_RC" -ne 0 ] || [ -z "$PROBE_SRC" ]; then
  record INCONCLUSIVE identity-logged "the allowed probe did not produce a response and source address"
else
  SERVER_FQDN="${SERVER_SERVICE}.${SERVER_NAMESPACE}.svc.cluster.local"                       # 예: mesh-server.team-mesh-check.svc.cluster.local
  EXPECTED_SRC="${CLIENT_IDENTITY#spiffe://}"
  EXPECTED_DST="${SERVER_IDENTITY#spiffe://}"
  IDENTITY_RESULT=INCONCLUSIVE
  for LOG_ATTEMPT in 1 2 3 4 5; do                       # 예: 기록 반영을 기다려 최대 5번, 1초 간격
    if k -n "$MESH_NAMESPACE" logs -l "app=$NODE_PROXY_DAEMONSET" --max-log-requests=20 --tail=-1 --since-time="$PROBE_START" > "$PROXY_LOG_FILE"; then
      PROXY_LOG_STATUS=COLLECTED
      # 예: access connection complete src.addr=… src.identity="spiffe://…/sa/mesh-client" … dst.service=… dst.identity="spiffe://…/sa/mesh-server" direction="outbound"
      # 값은 버전에 따라 따옴표가 있거나 없으므로 두 형태를 모두 찾습니다. src.addr 뒤의 공백은 포트 앞부분만 겹치는 다른 연결을 걸러 냅니다.
      MATCH=$(grep -F -e 'direction="outbound"' -e 'direction=outbound' "$PROXY_LOG_FILE" \
        | grep -F -e "src.addr=${PROBE_SRC} " -e "src.addr=\"${PROBE_SRC}\"" \
        | grep -F -e "dst.service=${SERVER_FQDN} " -e "dst.service=\"${SERVER_FQDN}\"" \
        | grep -F 'src.identity=' | grep -F 'dst.identity=' | tail -n 1)
      if [ -n "$MATCH" ]; then
        LOG_SRC=$(printf '%s\n' "$MATCH" | sed -n 's/.*src\.identity="\{0,1\}\([^" ]*\)"\{0,1\}.*/\1/p'); LOG_SRC="${LOG_SRC#spiffe://}"
        LOG_DST=$(printf '%s\n' "$MATCH" | sed -n 's/.*dst\.identity="\{0,1\}\([^" ]*\)"\{0,1\}.*/\1/p'); LOG_DST="${LOG_DST#spiffe://}"
        if [ "$LOG_SRC" = "$EXPECTED_SRC" ] && [ "$LOG_DST" = "$EXPECTED_DST" ]; then IDENTITY_RESULT=PASS; else IDENTITY_RESULT=FAIL; fi
      fi
    else
      PROXY_LOG_STATUS=QUERY_FAILED
      : > "$PROXY_LOG_FILE" || { echo 'Proxy log could not be cleared after lookup failure' >&2; break; }
    fi
    case "$IDENTITY_RESULT" in PASS|FAIL) break ;; esac
    [ "$LOG_ATTEMPT" -eq 5 ] || sleep 1
  done
  case "$IDENTITY_RESULT" in
    PASS) record PASS identity-logged "both expected identities match the successful probe connection" ;;
    FAIL) record FAIL identity-logged "the probe connection carries an unexpected identity" ;;
    *) record INCONCLUSIVE identity-logged "no complete identity record matches this probe connection" ;;
  esac
fi

# 5. proxy-per-node: 노드 이름마다 Ready 대리자 Pod가 정확히 하나 있는지 확인합니다.
# 조회 오류나 빈 목록은 보류이며, 합계가 같더라도 중복·누락이 있으면 실패입니다.
NODE_ROWS=''
PROXY_ROWS=''
if NODE_ROWS=$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') && \
  PROXY_ROWS=$(k -n "$MESH_NAMESPACE" get pods -l "app=$NODE_PROXY_DAEMONSET" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.metadata.deletionTimestamp}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}') && \
  [ -n "$NODE_ROWS" ] && [ -n "$PROXY_ROWS" ]; then
  PROXY_COVERAGE=$(printf '%s\n' "$NODE_ROWS" '__PROXY_ROWS__' "$PROXY_ROWS" | awk -F'\t' '
    $0 == "__PROXY_ROWS__" { proxies=1; next }
    !proxies && $1 != "" { nodes[$1]=1; next }
    proxies && $1 != "" && $2 == "" && $3 == "True" { ready[$1]++ }
    END {
      bad=0
      for (node in nodes) if (ready[node] != 1) bad=1
      for (node in ready) if (!(node in nodes)) bad=1
      print bad ? "FAIL" : "PASS"
    }')
  record "$PROXY_COVERAGE" proxy-per-node "each listed node must have exactly one non-terminating Ready proxy"
else
  record INCONCLUSIVE proxy-per-node "cannot read the node list or ready node proxy placement"
fi

# Python 표준 json 모듈로 모든 외부 입력과 판정 설명을 escape합니다.
# RESULTS 는 구분 문자 대신 결과·이름·설명의 연속 세 항목으로 전달합니다.
if ! python3 - "$VERDICT" "$WANT_NS" "$STRICT_NAMESPACES" "$MESH_NAMESPACE" \
  "$PROXY_LOG_STATUS" "$PROBE_START" "$PROBE_SRC" "$PROXY_LOG_FILE" "${RESULTS[@]}" > "$EVIDENCE" <<'PYJSON'
import datetime
import json
import sys
verdict, enrolled, strict, namespace, log_status, started, source, log_path, *rows = sys.argv[1:]
if len(rows) % 3:
    raise ValueError("incomplete result tuple")
evidence = {
    "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "scope": "Pod-to-pod mutual TLS boundary only. Application behaviour, ingress TLS termination and storage retention are judged elsewhere.",
    "verdict": verdict,
    "enrolled_namespaces": enrolled.split(),
    "strict_namespaces": strict.split(),
    "mesh_namespace": namespace,
    "proxy_log": {"status": log_status, "path": log_path,
                  "probe_started_at": started, "probe_source": source},
    "checks": [{"result": rows[i], "name": rows[i + 1], "detail": rows[i + 2]}
               for i in range(0, len(rows), 3)],
}
json.dump(evidence, sys.stdout, indent=2)
sys.stdout.write("\n")
PYJSON
then
  [ "$VERDICT" = FAIL ] || VERDICT=INCONCLUSIVE
  echo 'Evidence file could not be written; do not use an earlier result' >&2
fi
echo "$VERDICT"
case "$VERDICT" in
  PASS) exit 0 ;;
  FAIL) exit 1 ;;
  *) exit 2 ;;
esac
