#!/usr/bin/env bash
# platform/environments/dev/observability/scripts/check-queue.sh
# 토픽 · 접근 제어와 연결 시험: 메시지 큐 선언(53 · 54/56 · 55)과 현재 상태(운영자가 조정한 결과)를 대조합니다. 읽기 조회만 하며 자원을 만들지 않습니다 (원본 assets/관측 파이프라인/queue/check-queue.sh + Python 판정의 셸 버전).
# 사용: KUBE_CONTEXT=<context> scripts/check-queue.sh
set -uo pipefail
: "${KUBE_CONTEXT:?Set the intended EKS context}" # 예: contract2whale-dev-eks
NS="${QUEUE_NAMESPACE:-messaging}"                # 예: messaging
CLUSTER="${QUEUE_CLUSTER:-platform-queue}"        # 예: platform-queue
TOPIC="${QUEUE_TOPIC:-platform-traces}"           # 예: platform-traces
K=(kubectl --context "$KUBE_CONTEXT" -n "$NS")
CHECKED=0 DIFF=0 UNKNOWN=0
ok()   { CHECKED=$((CHECKED + 1)); printf 'OK    %s\n' "$*"; }
bad()  { CHECKED=$((CHECKED + 1)); DIFF=$((DIFF + 1)); printf 'DIFF  %s\n' "$*"; }
skip() { UNKNOWN=$((UNKNOWN + 1)); printf 'SKIP  %s\n' "$*"; }
get() { "${K[@]}" get "$@"; } # 예: get kafka platform-queue -o jsonpath=…

# 조회 종료 코드와 조회된 값의 불일치를 분리합니다.
query_value() {
  local DESTINATION="$1" DETAIL="$2" QUERY_VALUE
  shift 2
  if ! QUERY_VALUE=$(get "$@"); then skip "$DETAIL query failed"; return 1; fi
  printf -v "$DESTINATION" '%s' "$QUERY_VALUE"
}
equal_query() {
  local DETAIL="$1" EXPECTED="$2" ACTUAL
  shift 2
  if ! query_value ACTUAL "$DETAIL" "$@"; then return; fi
  [ "$ACTUAL" = "$EXPECTED" ] && ok "$DETAIL=$ACTUAL" || bad "$DETAIL=$ACTUAL expected=$EXPECTED"
}

# 1. 클러스터 선언이 조정을 마쳤고(observedGeneration = generation) Ready 인지, 토픽 자동 생성이 꺼져 있는지 봅니다.
if ! GEN=$(get kafka "$CLUSTER" -o jsonpath='{.metadata.generation}') || [ -z "$GEN" ]; then
  skip "kafka.$CLUSTER not found"
else
  equal_query kafka.generation "$GEN" kafka "$CLUSTER" -o jsonpath='{.status.observedGeneration}'
  equal_query kafka.ready True kafka "$CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  equal_query kafka.auto.create.topics.enable false kafka "$CLUSTER" -o jsonpath='{.spec.kafka.config.auto\.create\.topics\.enable}'
  if query_value SUPER kafka.superUsers kafka "$CLUSTER" -o jsonpath='{.spec.kafka.authorization.superUsers[*]}'; then
    [[ " $SUPER " == *" ANONYMOUS "* ]] && ok "kafka.superUsers has ANONYMOUS (plain listener)" || bad "kafka.superUsers=$SUPER"
  fi
  for L in tls:9093 plain:9092; do
    equal_query "listener.${L%%:*}" "${CLUSTER}-kafka-bootstrap.${NS}.svc.cluster.local:${L##*:}" \
      kafka "$CLUSTER" -o jsonpath="{.status.listeners[?(@.name==\"${L%%:*}\")].bootstrapServers}"
  done
  # 3. 리스너가 만든 Pod 사이 정책과 CA 시크릿 2쌍.
  if query_value POLICY networkpolicy networkpolicy "${CLUSTER}-network-policy-kafka" --ignore-not-found -o name; then
    [ -n "$POLICY" ] && ok "networkpolicy.${CLUSTER}-network-policy-kafka" || bad "networkpolicy missing"
  fi
  for S in cluster-ca cluster-ca-cert clients-ca clients-ca-cert; do
    if query_value SECRET "secret.${CLUSTER}-${S}" secret "${CLUSTER}-${S}" --ignore-not-found -o name; then
      [ -n "$SECRET" ] && ok "secret.${CLUSTER}-${S}" || bad "secret.${CLUSTER}-${S} missing"
    fi
  done
  if query_value PODS kafka.pods pods -l "strimzi.io/cluster=${CLUSTER},strimzi.io/pool-name" -o jsonpath='{range .items[*]}{.metadata.labels.strimzi\.io/pool-name}{" "}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'; then
    N=$(printf '%s\n' "$PODS" | grep -c .)
    [ "$N" = 6 ] && ok "kafka.pods=6" || bad "kafka.pods=$N"
    while read -r POOL NODE RDY; do
      [ -n "$POOL" ] || continue
      if [ -z "$NODE" ]; then bad "pod.$POOL node missing"; continue; fi
      if ! ZONE=$(kubectl --context "$KUBE_CONTEXT" get node "$NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'); then
        skip "pod.$POOL node zone query failed"; continue
      fi
      [ "$RDY" = True ] && [ "$ZONE" = "ap-northeast-${POOL##*-}" ] && ok "pod.$POOL ready zone=$ZONE" || bad "pod.$POOL ready=$RDY zone=$ZONE"
    done <<< "$PODS"
  fi
fi

# 5. 업무 토픽: Ready · 파티션 3 · 복제 3 · 12시간 보존.
if ! TREADY=$(get kafkatopic "$TOPIC" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') || [ -z "$TREADY" ]; then
  skip "kafkatopic.$TOPIC not found or not reconciled"
else
  [ "$TREADY" = True ] && ok "topic.ready" || bad "topic.ready=$TREADY"
  equal_query topic.partitions 3 kafkatopic "$TOPIC" -o jsonpath='{.spec.partitions}'
  equal_query topic.replicas 3 kafkatopic "$TOPIC" -o jsonpath='{.spec.replicas}'
  equal_query topic.retention.ms 43200000 kafkatopic "$TOPIC" -o jsonpath='{.spec.config.retention\.ms}'

fi

# 사용자 상태와 ACL의 실제 대상·동작·그룹 패턴을 검사합니다.
# 같은 개수의 규칙이어도 다른 토픽이나 wildcard allow이면 실패합니다.
rule() {
  printf '%s' "$USER_JSON" | jq -e --arg rt "$1" --arg rn "$2" --arg pat "$3" --arg op "$4" --arg kind "$5" '
    any(.spec.authorization.acls[]?;
      .resource.type == $rt and (.resource.name // "") == $rn and
      (.resource.patternType // "literal") == $pat and (.type // "allow") == $kind and
      (.operations | index($op)) != null)' >/dev/null
}
for NAME in tempo-distributor tempo-consumer; do
  if ! USER_JSON=$(get kafkauser "$NAME" -o json) || [ -z "$USER_JSON" ]; then
    skip "kafkauser.$NAME query failed"; continue
  fi
  if ! printf '%s' "$USER_JSON" | jq -e 'type == "object" and (.spec.authorization.acls | type == "array")' >/dev/null; then
    skip "kafkauser.$NAME invalid query payload"; continue
  fi
  printf '%s' "$USER_JSON" | jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' >/dev/null \
    && ok "user.$NAME ready" || bad "user.$NAME not Ready"
  rule topic "$TOPIC" literal Describe allow && ok "user.$NAME topic Describe" || bad "user.$NAME topic Describe missing"
  if [ "$NAME" = tempo-distributor ]; then
    rule topic "$TOPIC" literal Write allow && ok "user.$NAME topic Write" || bad "user.$NAME topic Write missing"
  else
    rule topic "$TOPIC" literal Read allow && ok "user.$NAME topic Read" || bad "user.$NAME topic Read missing"
    for GROUP in block-builder metrics-generator; do
      rule group "$GROUP" literal Read allow && ok "user.$NAME group $GROUP" || bad "user.$NAME group $GROUP missing"
    done
    for ZONE in a b c; do
      rule group "platform-tempo-live-store-zone-$ZONE" prefix Read allow \
        && ok "user.$NAME live-store zone-$ZONE prefix" || bad "user.$NAME live-store zone-$ZONE prefix missing"
    done
    for OP in Write Delete; do
      rule topic '*' literal "$OP" deny && ok "user.$NAME deny $OP" || bad "user.$NAME deny $OP missing"
    done
  fi
  rule topic '*' literal Create deny && rule cluster '' literal Create deny \
    && ok "user.$NAME deny topic creation" || bad "user.$NAME creation deny missing"
  printf '%s' "$USER_JSON" | jq -e '
    all(.spec.authorization.acls[]?; (.type // "allow") != "allow" or
      ((.resource.name // "") != "*" and .resource.type != "cluster"))' >/dev/null \
    && ok "user.$NAME no wildcard allow" || bad "user.$NAME overbroad allow"
  if query_value KEYS "secret.$NAME credential keys" secret "$NAME" -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}'; then
    [[ " $KEYS " == *" password "* && " $KEYS " == *" sasl.jaas.config "* ]] \
      && ok "secret.$NAME credential keys present" || bad "secret.$NAME credential keys missing"
  fi
done

echo 'SCOPE DECLARATION_AND_CURRENT_RECONCILIATION_ONLY'
if [ "$DIFF" -gt 0 ]; then echo "FAIL checked=$CHECKED diff=$DIFF skipped=$UNKNOWN"; exit 1
elif [ "$UNKNOWN" -gt 0 ]; then echo "INCONCLUSIVE checked=$CHECKED diff=0 skipped=$UNKNOWN"; exit 2
else echo "PASS checked=$CHECKED diff=0"; exit 0; fi
