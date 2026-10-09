#!/usr/bin/env bash
# platform/environments/dev/observability/scripts/queue-smoke.sh
# 토픽 · 접근 제어와 연결 시험: 격리된 연결 시험입니다 — 임시 토픽 · 임시 사용자 · 임시 Pod 만 만들어 tls 리스너(9093, SCRAM + ACL)로 3건을 쓰고 읽은 뒤, 같은 사용자로 업무 토픽(platform-traces)에 쓰기가 거부되는지 보고, 업무 토픽의 끝 offset 이 변하지 않았음을 확인하고 모두 지웁니다.
# 원본 smoke.py(assets, 미전달)의 셸 버전입니다. Kafka 클라이언트는 Strimzi 의 Kafka 이미지(quay.io/strimzi/kafka:<STRIMZI_VERSION>-kafka-<KAFKA_VERSION>)의 bin/*.sh 를 Pod 안에서 씁니다. 판정 PASS / INCONCLUSIVE = 종료 0 / 2 (임시 자원이 남으면 INCONCLUSIVE). 결과는 local-inputs/queue-smoke-<UUID>.tsv. 현재 UID/UUID label 조회와 selector 삭제 사이 동시 변경을 원자적으로 막는 API 삭제는 아닙니다.
# 사용: KUBE_CONTEXT=<context> scripts/queue-smoke.sh
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../versions.env
source "$ROOT/versions.env" || exit 2 # 버전 파일 실패 시 생성하지 않음
# 기존 환경에서 사용할 필수 도구이며 설치를 자동으로 시도하지 않습니다.
for TOOL in kubectl jq python3; do
  command -v "$TOOL" >/dev/null 2>&1 || { printf 'INCONCLUSIVE missing tool: %s\n' "$TOOL" >&2; exit 2; }
done
# 예: versions.env의 STRIMZI_VERSION=1.2.0, KAFKA_VERSION=4.3.1
: "${KUBE_CONTEXT:?Set the intended EKS context}"  # 예: contract2whale-dev-eks
NS="${QUEUE_NAMESPACE:-messaging}" CLUSTER="${QUEUE_CLUSTER:-platform-queue}" TOPIC="${QUEUE_TOPIC:-platform-traces}"
for VALUE in "$NS" "$CLUSTER" "$TOPIC"; do
  [[ "$VALUE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && [ "${#VALUE}" -le 63 ] || {
    printf 'INCONCLUSIVE invalid queue name\n' >&2; exit 2;
  }
done
RUN_ID=$(python3 -c 'import uuid; print(uuid.uuid4())') || exit 2
[[ "$RUN_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || exit 2
ID="smoke-$RUN_ID" # 예: smoke-550e8400-e29b-41d4-a716-446655440000
OWNER_LABEL="platform.example/queue-smoke-run=$RUN_ID"
IMAGE="quay.io/strimzi/kafka:${STRIMZI_VERSION}-kafka-${KAFKA_VERSION}" # 예: quay.io/strimzi/kafka:1.2.0-kafka-4.3.1 (운영자 STRIMZI_KAFKA_IMAGES 와 같은 이미지)
BOOTSTRAP="${CLUSTER}-kafka-bootstrap.${NS}.svc.cluster.local:9093"     # 예: tls 리스너
K=(kubectl --context "$KUBE_CONTEXT" -n "$NS")
umask 077
mkdir -p "$ROOT/local-inputs" || exit 2
REPORT="$ROOT/local-inputs/queue-smoke-$RUN_ID.tsv"
(set -C; : > "$REPORT") || { printf 'INCONCLUSIVE report already exists or cannot be created\n' >&2; exit 2; }
RESULT=PASS; PENDING=''
OWNED_KINDS=() OWNED_UIDS=()
note() {
  printf '%s\t%s\n' "$1" "$2"
  printf '%s\t%s\n' "$1" "$2" >> "$REPORT" || { RESULT=INCONCLUSIVE; return 1; }
}
fail() { RESULT=INCONCLUSIVE; note FAIL "$*"; }

# 성공한 빈 조회만 부재입니다. 조회 실패와 기존 객체는 생성 허가가 아닙니다.
for KIND in kafkatopic kafkauser pod; do
  if ! FOUND=$("${K[@]}" get "$KIND" "$ID" --ignore-not-found -o json); then
    fail "preflight query failed: $KIND/$ID"; exit 2
  fi
  if [ -n "$FOUND" ]; then fail "already exists: $KIND/$ID"; exit 2; fi
done

create_owned() { # stdin의 선언 하나만 create. 응답 UID를 얻지 못한 객체는 임의 인수/삭제하지 않습니다.
  local KIND="$1" CREATED RESOURCE_UID
  if ! CREATED=$("${K[@]}" create -f - -o json); then
    PENDING="$PENDING $KIND/$ID:create-unconfirmed"
    fail "create failed or response unavailable: $KIND/$ID"; return 2
  fi
  if ! RESOURCE_UID=$(printf '%s' "$CREATED" | jq -er --arg id "$ID" --arg ns "$NS" --arg run "$RUN_ID" '
    select(.metadata.name == $id and .metadata.namespace == $ns and
      .metadata.labels["platform.example/queue-smoke-run"] == $run) |
    .metadata.uid | select(type == "string" and length > 0)'); then
    PENDING="$PENDING $KIND/$ID:uid-unconfirmed"
    fail "create response ownership unavailable: $KIND/$ID"; return 2
  fi
  OWNED_KINDS+=("$KIND"); OWNED_UIDS+=("$RESOURCE_UID")
  note created "$KIND/$ID uid=$RESOURCE_UID" || return 2
}
cleanup() {
  local INDEX KIND CURRENT RESOURCE_UID
  for ((INDEX=${#OWNED_KINDS[@]}-1; INDEX>=0; INDEX--)); do
    KIND="${OWNED_KINDS[$INDEX]}"; RESOURCE_UID="${OWNED_UIDS[$INDEX]}"
    if ! CURRENT=$("${K[@]}" get "$KIND" "$ID" --ignore-not-found -o json); then
      PENDING="$PENDING $KIND/$ID:query-failed"; continue
    fi
    [ -n "$CURRENT" ] || continue
    if ! printf '%s' "$CURRENT" | jq -e --arg uid "$RESOURCE_UID" --arg run "$RUN_ID" '
      .metadata.uid == $uid and .metadata.labels["platform.example/queue-smoke-run"] == $run' >/dev/null; then
      PENDING="$PENDING $KIND/$ID:ownership-changed"; continue
    fi
    # UUID selector로 이번 실행만 제한합니다. API의 원자 UID 조건 삭제는 아닙니다.
    if ! "${K[@]}" delete "$KIND" -l "$OWNER_LABEL" --field-selector "metadata.name=$ID" --ignore-not-found --wait=true --timeout=120s; then
      PENDING="$PENDING $KIND/$ID:delete-failed"; continue
    fi
    if ! CURRENT=$("${K[@]}" get "$KIND" "$ID" --ignore-not-found -o json); then
      PENDING="$PENDING $KIND/$ID:post-delete-query-failed"
    elif [ -n "$CURRENT" ]; then
      PENDING="$PENDING $KIND/$ID:still-present"
    fi
  done
  if [ -n "$PENDING" ]; then RESULT=INCONCLUSIVE; note cleanup_pending "$PENDING"
  else note cleanup_pending none; fi
}
on_exit() {
  local ORIGINAL_EXIT="$?"
  trap - EXIT
  [ "$ORIGINAL_EXIT" = 0 ] || RESULT=INCONCLUSIVE
  cleanup
  note result "$RESULT"
  printf 'ISOLATED_KAFKA_SMOKE_%s; business_trace_path_not_tested; report=%s\n' "$RESULT" "$REPORT"
  [ "$ORIGINAL_EXIT" = 0 ] && [ "$RESULT" = PASS ] && exit 0
  exit 2
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# 1. 임시 토픽(파티션 1 · 복제 3) 와 임시 사용자(임시 토픽 읽기 · 쓰기, 업무 토픽 Describe 만) 를 만들고 Ready 를 기다립니다.
create_owned kafkatopic <<YAML || exit 2
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata: {name: $ID, namespace: $NS, labels: {strimzi.io/cluster: $CLUSTER, platform-managed: queue, platform.example/queue-smoke-run: $RUN_ID}}
spec: {partitions: 1, replicas: 3, config: {min.insync.replicas: '2', retention.ms: '600000'}}
YAML
create_owned kafkauser <<YAML || exit 2
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata: {name: $ID, namespace: $NS, labels: {strimzi.io/cluster: $CLUSTER, platform-managed: queue, platform.example/queue-smoke-run: $RUN_ID}}
spec:
  authentication: {type: scram-sha-512}
  authorization:
    type: simple
    acls:
      - {resource: {type: topic, name: $ID, patternType: literal}, operations: [Describe, Read, Write], host: '*', type: allow}
      - {resource: {type: group, name: $ID, patternType: literal}, operations: [Describe, Read], host: '*', type: allow}
      - {resource: {type: topic, name: $TOPIC, patternType: literal}, operations: [Describe], host: '*', type: allow}
YAML
"${K[@]}" wait --for=condition=Ready "kafkatopic/$ID" "kafkauser/$ID" --timeout=180s > /dev/null || { fail "temporary topic/user not Ready"; exit 2; }
note temporary_resources "kafkatopic/$ID kafkauser/$ID (Ready)"

# 2. 시험 Pod: 사용자 시크릿(sasl.jaas.config) 과 클러스터 CA(ca.p12 · ca.password) 를 붙여 client.properties 를 만들고 쓰기 3건 → 읽기 → 업무 토픽 쓰기 시도 → 업무 토픽 끝 offset 을 두 번 읽습니다.
create_owned pod <<YAML || exit 2
apiVersion: v1
kind: Pod
metadata: {name: $ID, namespace: $NS, labels: {app: queue-smoke, platform.example/queue-smoke-run: $RUN_ID}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  activeDeadlineSeconds: 600
  securityContext: {runAsNonRoot: true, runAsUser: 1001, runAsGroup: 0, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: client
      image: $IMAGE
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 100m, memory: 512Mi}, limits: {memory: 1Gi}}
      command: [sh, -c]
      args:
        - |
          set -eu
          cat > /tmp/client.properties <<EOP
          security.protocol=SASL_SSL
          sasl.mechanism=SCRAM-SHA-512
          sasl.jaas.config=\$(cat /creds/sasl.jaas.config)
          ssl.truststore.location=/ca/ca.p12
          ssl.truststore.password=\$(cat /ca/ca.password)
          ssl.truststore.type=PKCS12
          EOP
          B=$BOOTSTRAP
          bin/kafka-get-offsets.sh --bootstrap-server \$B --command-config /tmp/client.properties --topic $TOPIC > /tmp/offset-before
          test -s /tmp/offset-before
          echo "OFFSET_BEFORE \$(awk -F: '{s+=\$3} END {print s+0}' /tmp/offset-before)"
          printf 'one\ntwo\nthree\n' | bin/kafka-console-producer.sh --bootstrap-server \$B --producer.config /tmp/client.properties --topic $ID > /dev/null
          bin/kafka-console-consumer.sh --bootstrap-server \$B --consumer.config /tmp/client.properties --topic $ID --group $ID --from-beginning --max-messages 3 --timeout-ms 60000 > /tmp/consumed
          echo "CONSUMED \$(wc -l < /tmp/consumed | tr -d ' ')"
          if printf 'denied\n' | bin/kafka-console-producer.sh --bootstrap-server \$B --producer.config /tmp/client.properties --topic $TOPIC 2>&1 | grep -q 'TopicAuthorizationException'; then echo 'BUSINESS_WRITE DENIED'; else echo 'BUSINESS_WRITE NOT_DENIED'; fi
          bin/kafka-get-offsets.sh --bootstrap-server \$B --command-config /tmp/client.properties --topic $TOPIC > /tmp/offset-after
          test -s /tmp/offset-after
          echo "OFFSET_AFTER \$(awk -F: '{s+=\$3} END {print s+0}' /tmp/offset-after)"
      volumeMounts:
        - {name: creds, mountPath: /creds, readOnly: true}
        - {name: ca, mountPath: /ca, readOnly: true}
  volumes:
    - name: creds
      secret: {secretName: $ID}
    - name: ca
      secret: {secretName: ${CLUSTER}-cluster-ca-cert}
YAML
for _ in $(seq 1 60); do
  PHASE=$("${K[@]}" get pod "$ID" -o jsonpath='{.status.phase}') || { fail "probe phase query failed"; exit 2; } # 예: Succeeded
  case "$PHASE" in Succeeded | Failed) break ;; esac
  sleep 5
done
[ "${PHASE:-}" = Succeeded ] || { fail "probe pod phase=${PHASE:-unknown}"; "${K[@]}" logs "$ID" 2> /dev/null | tail -20; exit 2; }
LOG=$("${K[@]}" logs "$ID") || { fail "probe log query failed"; exit 2; }
BEFORE=$(printf '%s\n' "$LOG" | awk '$1=="OFFSET_BEFORE"{print $2}'); AFTER=$(printf '%s\n' "$LOG" | awk '$1=="OFFSET_AFTER"{print $2}')
CONSUMED=$(printf '%s\n' "$LOG" | awk '$1=="CONSUMED"{print $2}'); DENIED=$(printf '%s\n' "$LOG" | awk '$1=="BUSINESS_WRITE"{print $2}')
[ "$CONSUMED" = 3 ] && note produced_consumed 3 || fail "consumed=$CONSUMED (want 3)"
[ "$DENIED" = DENIED ] && note business_topic_write DENIED || fail "business topic write=$DENIED (want DENIED)"
[[ "$BEFORE" =~ ^[0-9]+$ && "$AFTER" =~ ^[0-9]+$ ]] && [ "$BEFORE" = "$AFTER" ] && note business_offsets_changed false || fail "business offsets before=$BEFORE after=$AFTER"
note tempo_topic_written false
# EXIT에서 현재 UID/UUID label을 다시 조회하고 정리 결과까지 판정합니다.
[ "$RESULT" = PASS ] && exit 0 || exit 2
