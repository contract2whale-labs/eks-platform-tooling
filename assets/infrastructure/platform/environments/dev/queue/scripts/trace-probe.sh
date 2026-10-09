#!/usr/bin/env bash
# platform/environments/dev/queue/scripts/trace-probe.sh
# send 는 trace id(16진수 32자리)를 만들어 local-inputs/trace-probe-<id>.tsv 에 남기고, query 는 아직 저장되지 않은 HTTP 404만 재시도하며 조회·인증 오류는 INCONCLUSIVE로 중단합니다 (--mode blocks 는 S3 블록에서만 찾는 querier 경로 — 블록 생성까지 수 분).
# 사용: KUBE_CONTEXT=<context> scripts/trace-probe.sh send --endpoint http://collection-gateway.observability:4318 [--id <hex32>]
#       KUBE_CONTEXT=<context> scripts/trace-probe.sh query --endpoint http://platform-tempo-active-query.monitoring:3200 --id <hex32> [--mode blocks] [--timeout 1800]
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${KUBE_CONTEXT:?Set the intended EKS context}"
ACTION="${1:-}"; shift || true
ENDPOINT='' ID='' MODE=live TIMEOUT=1800 NS="${PROBE_NAMESPACE:-observability}" IMAGE="${PROBE_IMAGE:-curlimages/curl:8.14.1}"
while [ $# -gt 0 ]; do case "$1" in --endpoint) ENDPOINT="$2"; shift 2 ;; --id) ID="$2"; shift 2 ;; --mode) MODE="$2"; shift 2 ;; --timeout) TIMEOUT="$2"; shift 2 ;; *) echo "Unknown argument: $1" >&2; exit 2 ;; esac; done
[ -n "$ENDPOINT" ] || { echo "usage: trace-probe.sh send|query --endpoint <url> [--id <hex32>] [--mode blocks]" >&2; exit 2; }
mkdir -p "$ROOT/local-inputs"
curl_pod() { # 예: curl_pod <curl 인자…> → 임시 Pod 에서 curl 실행 (끝나면 삭제)
  kubectl --context "$KUBE_CONTEXT" -n "$NS" run "trace-probe-$(date +%s)-$RANDOM" --image="$IMAGE" --restart=Never --rm -i --quiet \
    --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}}}}' -- "$@"
}
check_response() {
  python3 -c '
import base64,json,sys
try:
    data=json.load(sys.stdin)
    if not isinstance(data,dict): raise ValueError("response is not an object")
    if sys.argv[1]=="send":
        partial=data.get("partialSuccess",{})
        if not isinstance(partial,dict): raise ValueError("invalid partialSuccess")
        rejected=int(partial.get("rejectedSpans",0))
        if rejected<0: raise ValueError("negative rejectedSpans")
        if rejected or partial.get("errorMessage"):
            print("OTLP partial rejection",file=sys.stderr); sys.exit(1)
    else:
        wanted=sys.argv[2]
        def matches(value):
            if isinstance(value,dict):
                candidate=value.get("traceId")
                if isinstance(candidate,str):
                    if candidate.lower()==wanted: return True
                    try:
                        if base64.b64decode(candidate,validate=True).hex()==wanted: return True
                    except (ValueError,TypeError): pass
                return any(matches(v) for v in value.values())
            return isinstance(value,list) and any(matches(v) for v in value)
        if not matches(data): raise ValueError("requested trace ID absent from response")
except (ValueError,TypeError,OverflowError) as exc:
    print(str(exc),file=sys.stderr); sys.exit(2)
' "$1" "$ID"
}
case "$ACTION" in
  send)
    ID="${ID:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
    [[ "$ID" =~ ^[0-9a-f]{32}$ ]] || { echo "trace id must be 32 hex characters" >&2; exit 2; }
    SPAN=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'); NOW=$(date +%s)000000000; END=$((NOW + 5000000))
    BODY="{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"platform-trace-probe\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"trace-probe\"},\"spans\":[{\"traceId\":\"${ID}\",\"spanId\":\"${SPAN}\",\"name\":\"probe\",\"kind\":1,\"startTimeUnixNano\":\"${NOW}\",\"endTimeUnixNano\":\"${END}\",\"status\":{}}]}]}]}"
    SEND_ERROR=$(mktemp)
    if ! RESPONSE=$(curl_pod curl -sS -w '\n%{http_code}' -X POST "${ENDPOINT%/}/v1/traces" -H 'Content-Type: application/json' -d "$BODY" 2> "$SEND_ERROR"); then
      echo "TRACE_SEND_INCONCLUSIVE id=$ID reason=transport_or_kubernetes_error last_http=${CODE:-none}" >&2
      cat "$SEND_ERROR" >&2
      rm -f "$SEND_ERROR"
      exit 2
    fi
    rm -f "$SEND_ERROR"
    CODE=${RESPONSE##*$'\n'}; RESPONSE_BODY=${RESPONSE%$'\n'*}
    [ "$CODE" = 200 ] || { echo "TRACE_SEND_FAILED http=$CODE endpoint=$ENDPOINT"; exit 1; }
    printf '%s' "$RESPONSE_BODY" | check_response send
    RESPONSE_EXIT=$?
    [ "$RESPONSE_EXIT" = 0 ] || { echo "TRACE_SEND_RESPONSE_FAILED id=$ID http=$CODE" >&2; exit "$RESPONSE_EXIT"; }
    printf 'id\t%s\nsent_at\t%s\nendpoint\t%s\n' "$ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ENDPOINT" > "$ROOT/local-inputs/trace-probe-$ID.tsv"
    echo "TRACE_SENT id=$ID http=200 record=$ROOT/local-inputs/trace-probe-$ID.tsv" ;;
  query)
    [[ "$ID" =~ ^[0-9a-f]{32}$ ]] || { echo "--id <hex32> is required" >&2; exit 2; }
    case "$MODE" in live) URL="${ENDPOINT%/}/api/traces/$ID" ;; blocks) URL="${ENDPOINT%/}/querier/api/traces/$ID?mode=blocks" ;; *) echo "mode must be live or blocks" >&2; exit 2 ;; esac
    DEADLINE=$(( $(date +%s) + TIMEOUT )); ATTEMPT=0
    while :; do
      ATTEMPT=$((ATTEMPT + 1))
      QUERY_ERROR=$(mktemp)
      if ! RESPONSE=$(curl_pod curl -sS -w '\n%{http_code}' "$URL" 2> "$QUERY_ERROR"); then
        echo "TRACE_QUERY_INCONCLUSIVE id=$ID mode=$MODE reason=transport_or_kubernetes_error last_http=${CODE:-none}" >&2
        cat "$QUERY_ERROR" >&2
        rm -f "$QUERY_ERROR"
        exit 2
      fi
      rm -f "$QUERY_ERROR"
      CODE=${RESPONSE##*$'\n'}; RESPONSE_BODY=${RESPONSE%$'\n'*}
      case "$CODE" in
        200)
          printf '%s' "$RESPONSE_BODY" | check_response query || { echo "TRACE_QUERY_INCONCLUSIVE id=$ID mode=$MODE reason=response_body" >&2; exit 2; }
          break ;;
        404) # 조회에 성공했지만 아직 이 표본이 없을 때만 기다립니다.
          [ "$(date +%s)" -lt "$DEADLINE" ] || { echo "TRACE_NOT_FOUND id=$ID mode=$MODE attempts=$ATTEMPT last_http=404"; exit 1; }
          sleep 10
          ;;
        *) echo "TRACE_QUERY_INCONCLUSIVE id=$ID mode=$MODE reason=http_response last_http=${CODE:-none}" >&2; exit 2 ;;
      esac
    done
    printf 'found_%s_at\t%s\nattempts_%s\t%s\n' "$MODE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$ATTEMPT" >> "$ROOT/local-inputs/trace-probe-$ID.tsv"
    echo "TRACE_FOUND id=$ID mode=$MODE attempts=$ATTEMPT endpoint=$ENDPOINT" ;;
  *) echo "usage: trace-probe.sh send|query …" >&2; exit 2 ;;
esac
