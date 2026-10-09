#!/usr/bin/env bash
# tests/e2e/core/scripts/check-network.sh
# 한정된 진단 Deployment를 같은 실행에서 준비·검사·정리합니다. 지속 정책은 Argo 소유입니다.
# 사용: --scenario core (기본) | api-egress | collection-gateway
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCENARIO=core
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario) SCENARIO=${2:?Supply a scenario}; shift 2 ;;
    *) echo 'Usage: check-network.sh [--scenario core|api-egress|collection-gateway]' >&2; exit 2 ;;
  esac
done
case "$SCENARIO" in core|api-egress|collection-gateway) ;; *) echo 'Unknown network scenario' >&2; exit 2 ;; esac
: "${KUBE_CONTEXT:?Set the intended EKS context}"
: "${PROBE_IMAGE:?Set an approved Python 3 image pinned with @sha256 digest}"
[[ "$PROBE_IMAGE" =~ @sha256:[a-f0-9]{64}$ ]] || { echo 'Image digest required' >&2; exit 2; }
WORK=$(mktemp -d)
RUN_ID=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
CREATION_STARTED=false
cleanup() {
  result=$?; clean=true
  if [ "$CREATION_STARTED" = true ]; then
    if ! kubectl --context "$KUBE_CONTEXT" -n team-platform-check delete deployment,service -l "platform.example/probe-run=$RUN_ID" --ignore-not-found; then
      echo 'NETWORK_CLEANUP_INCOMPLETE: inspect remaining diagnostic workloads before another run' >&2
      clean=false; [ "$result" -ne 0 ] || result=2
    fi
    if [ "$SCENARIO" != core ] && ! kubectl --context "$KUBE_CONTEXT" -n observability delete deployment -l "platform.example/probe-run=$RUN_ID" --ignore-not-found; then
      echo 'NETWORK_CLEANUP_INCOMPLETE: inspect diagnostic control workload' >&2
      clean=false; [ "$result" -ne 0 ] || result=2
    fi
  fi
  rm -rf "$WORK"
  if [ "$result" = 0 ] && [ "$clean" = true ]; then
    echo "NETWORK_SCENARIO_PASS scenario=$SCENARIO cleanup=complete"
  else
    echo "NETWORK_SCENARIO_STOP scenario=$SCENARIO exit=$result cleanup=$clean" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
cp "$ROOT/checks/network-probes.yaml" "$ROOT/checks/kustomization.yaml" "$WORK/"
if [ "$SCENARIO" != core ]; then
  cp "$ROOT/checks/port-control.yaml" "$WORK/"
  (cd "$WORK" && kustomize edit add resource port-control.yaml)
fi
(cd "$WORK" && kustomize edit set image "platform-probe=$PROBE_IMAGE")
(cd "$WORK" && kustomize edit add label "platform.example/probe-run:$RUN_ID")
kustomize build "$WORK" > "$WORK/rendered-network-probes.yaml"
# Refuse stale probes and lookup failures. create also refuses a competing run
# that creates the same name after this check; cleanup selects only this run.
for object in deployment/policy-server deployment/policy-client deployment/policy-denied service/policy-server; do
  existing=$(kubectl --context "$KUBE_CONTEXT" -n team-platform-check get "$object" --ignore-not-found -o name) || exit 2
  [ -z "$existing" ] || { echo "NETWORK_EXISTING_OBJECT: $existing; inspect ownership before another run" >&2; exit 2; }
done
if [ "$SCENARIO" != core ]; then
  existing=$(kubectl --context "$KUBE_CONTEXT" -n observability get deployment/network-port-control --ignore-not-found -o name) || exit 2
  [ -z "$existing" ] || { echo "NETWORK_EXISTING_OBJECT: $existing; inspect ownership before another run" >&2; exit 2; }
fi
CREATION_STARTED=true
kubectl --context "$KUBE_CONTEXT" create -f "$WORK/rendered-network-probes.yaml"
for deployment in policy-server policy-client policy-denied; do
  kubectl --context "$KUBE_CONTEXT" -n team-platform-check rollout status "deployment/$deployment" --timeout=180s
done
if [ "$SCENARIO" != core ]; then
  kubectl --context "$KUBE_CONTEXT" -n observability rollout status deployment/network-port-control --timeout=180s
fi
# Python stdlib만 사용합니다. DNS/refused/CLI 실패는 정책 차단의 성공이 아닙니다.
PROBE_CODE='import socket,sys,urllib.request
mode,host,port,label=sys.argv[1:]; port=int(port)
try:
 if mode=="dns":
  addresses=sorted({item[4][0] for item in socket.getaddrinfo(host,None)})
  if not addresses: raise OSError("no addresses")
  print("DNS_ALLOWED label="+label+" addresses="+",".join(addresses)); sys.exit(0)
 if mode=="http":
  status=urllib.request.urlopen("http://"+host+":"+str(port),timeout=5).status
  if status!=200:
   print("PROBE_FAILED label="+label+" http="+str(status)); sys.exit(1)
  print("HTTP_ALLOWED label="+label+" status=200"); sys.exit(0)
 address=socket.getaddrinfo(host,port,type=socket.SOCK_STREAM)[0]
 sock=socket.socket(address[0],address[1],address[2]); sock.settimeout(5)
 try:
  sock.connect(address[4])
 except TimeoutError:
  if mode=="deny":
   print("TCP_BLOCKED label="+label+" reason=timeout"); sys.exit(0)
  print("PROBE_FAILED label="+label+" reason=timeout"); sys.exit(1)
 finally: sock.close()
 if mode=="deny":
  print("PROBE_FAILED label="+label+" reason=unexpected_connection"); sys.exit(1)
 print("TCP_ALLOWED label="+label+" port="+str(port))
except (OSError,urllib.error.URLError) as error:
 print("PROBE_INCONCLUSIVE label="+label+" reason="+type(error).__name__,file=sys.stderr); sys.exit(2)'
probe() {
  local namespace=$1 deployment=$2 mode=$3 host=$4 port=$5 label=$6 output rc expected
  case "$mode" in dns) expected=DNS_ALLOWED ;; http) expected=HTTP_ALLOWED ;; allow) expected=TCP_ALLOWED ;; deny) expected=TCP_BLOCKED ;; esac
  if output=$(kubectl --context "$KUBE_CONTEXT" -n "$namespace" exec "deployment/$deployment" -- python3 -c "$PROBE_CODE" "$mode" "$host" "$port" "$label" 2>&1); then rc=0; else rc=$?; fi
  printf '%s\n' "$output"
  if [ "$rc" = 0 ] && [[ "$output" == "$expected label=$label "* ]]; then return 0; fi
  if [ "$rc" = 1 ] && [[ "$output" == "PROBE_FAILED label=$label "* ]]; then return 1; fi
  echo "NETWORK_PROBE_INCONCLUSIVE label=$label command_exit=$rc" >&2; return 2
}
service_ip() {
  local namespace=$1 service=$2 ports=$3 data
  data=$(kubectl --context "$KUBE_CONTEXT" -n "$namespace" get service "$service" -o json) || return 2
  printf '%s' "$data" | python3 -c 'import ipaddress,json,sys
try:
 service=json.load(sys.stdin); address=service["spec"]["clusterIP"]; ipaddress.ip_address(address)
 required={int(x) for x in sys.argv[1].split(",")}
 actual={entry["port"] for entry in service["spec"]["ports"] if entry.get("protocol","TCP")=="TCP"}
 if not required<=actual: raise ValueError("required Service ports are missing")
 print(address)
except (KeyError,TypeError,ValueError) as error:
 print("SERVICE_INCONCLUSIVE: "+str(error),file=sys.stderr); sys.exit(2)' "$ports"
}
probe team-platform-check policy-client http policy-server 8080 core-http
SERVER_IP=$(service_ip team-platform-check policy-server 8080)
probe team-platform-check policy-denied deny "$SERVER_IP" 8080 core-denied
case "$SCENARIO" in
  api-egress)
    API_IP=$(service_ip default kubernetes 443)
    probe team-platform-check policy-client dns kubernetes.default.svc 0 api-dns
    probe observability network-port-control allow "$API_IP" 443 api-control
    probe team-platform-check policy-client deny "$API_IP" 443 api-denied
    ;;
  collection-gateway)
    GATEWAY_IP=$(service_ip observability collection-gateway 4317,4318,8888)
    probe team-platform-check policy-client dns collection-gateway.observability.svc.cluster.local 0 gateway-dns
    probe team-platform-check policy-client allow "$GATEWAY_IP" 4317 gateway-4317
    probe team-platform-check policy-client allow "$GATEWAY_IP" 4318 gateway-4318
    probe observability network-port-control allow "$GATEWAY_IP" 8888 gateway-metrics-control
    probe team-platform-check policy-client deny "$GATEWAY_IP" 8888 gateway-metrics-denied
    ;;
esac
