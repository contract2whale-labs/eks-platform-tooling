#!/usr/bin/env bash
# platform/environments/dev/queue/scripts/queue-smoke-managed.sh
# reader 자격의 거부 시험입니다. ACL 오류 시 업무 토픽 쓰기가 성공할 수 있으므로 원본 보존·1건 변경 위험을 승인하고 배타 창에서 실행합니다. 실패한 시험의 기록을 지우거나 토픽 데이터를 되돌리지 않습니다.
# 승인된 negative probe: ACL 오류 시 업무 토픽에 한 건이 쓰일 위험을 명시적으로 승인해야 합니다.
# 시험 4 + 불변 1: 토픽 Describe(파티션 3) · 허용되지 않은 그룹으로 읽기 거부 · 업무 토픽 쓰기 거부 · 틀린 비밀번호 거부 · 끝 offset 불변. 운영자 Pod(queue-admin) 와 Secret queue-managed-e2-reader 가 있어야 합니다.
# 판정 PASS / INCONCLUSIVE = 종료 0 / 2. 결과: local-inputs/queue-smoke-managed-<시각>.tsv
# 사용: 승인된 배타 작업 창 + MANAGED_QUEUE_REQUEST_ID/APPROVED_TOPIC/APPROVED_POD_UID/ALLOW_BUSINESS_NEGATIVE_PROBE 입력으로 실행합니다. 
set +x # Secret 값과 stdin을 xtrace로 출력하지 않습니다.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${KUBE_CONTEXT:?Set the intended EKS context}"
: "${EXPECTED_ACCOUNT_ID:?Set the approved account ID}"
INFRA_REPO=$(cd "$ROOT/../../../.." && pwd)
QUEUE_JSON=$(python3 "$INFRA_REPO/automation/read_platform_contract.py" --component queue --environment "${ENVIRONMENT:-dev}" --expect-account "$EXPECTED_ACCOUNT_ID") || { echo 'INCONCLUSIVE contract-query-failed'; exit 2; }
QUEUE_CLUSTER_ARN=$(printf '%s' "$QUEUE_JSON" | jq -er '.cluster_arn') || { echo 'INCONCLUSIVE contract-parse-failed'; exit 2; }
QUEUE_CLUSTER_NAME=$(printf '%s' "$QUEUE_JSON" | jq -er '.cluster_name') || { echo 'INCONCLUSIVE contract-parse-failed'; exit 2; }
QUEUE_BOOTSTRAP_SCRAM=$(printf '%s' "$QUEUE_JSON" | jq -er '.bootstrap_brokers_scram') || { echo 'INCONCLUSIVE contract-parse-failed'; exit 2; }
QUEUE_KMS_KEY_ARN=$(printf '%s' "$QUEUE_JSON" | jq -er '.kms_key_arn') || { echo 'INCONCLUSIVE contract-parse-failed'; exit 2; }
QUEUE_TOPIC=$(printf '%s' "$QUEUE_JSON" | jq -er '.topic_name') || { echo 'INCONCLUSIVE contract-parse-failed'; exit 2; }
QUEUE_PARTITIONS=$(printf '%s' "$QUEUE_JSON" | jq -er '.partitions') || { echo 'INCONCLUSIVE contract-parse-failed'; exit 2; }
QUEUE_REGION=${AWS_REGION:?Set the approved region}
QUEUE_WRITER_USERNAME=tempo-distributor
QUEUE_READER_USERNAME=tempo-consumer
unset QUEUE_JSON

# shellcheck source=/dev/null

NS=monitoring POD=queue-admin; K=(kubectl --context "$KUBE_CONTEXT" -n "$NS")
: "${MANAGED_QUEUE_REQUEST_ID:?Set approved operation request ID}"
: "${MANAGED_QUEUE_APPROVED_TOPIC:?Set topic from that approval}"
: "${MANAGED_QUEUE_APPROVED_POD_UID:?Set Pod UID from reviewed sync}"
: "${QUEUE_EKS_CLUSTER:?Set approved EKS cluster}"
: "${MANAGED_QUEUE_APPROVED_CLUSTER_ARN:?Set approved MSK ARN}"
: "${MANAGED_QUEUE_ALLOW_BUSINESS_NEGATIVE_PROBE:?Explicitly approve possible one-record business-topic write with request ID}"
[[ "$MANAGED_QUEUE_REQUEST_ID" =~ ^[a-z0-9][a-z0-9-]{7,62}$ ]] || exit 2
[ "$MANAGED_QUEUE_APPROVED_TOPIC" = "$QUEUE_TOPIC" ] && [ "$MANAGED_QUEUE_ALLOW_BUSINESS_NEGATIVE_PROBE" = "$MANAGED_QUEUE_REQUEST_ID" ] || exit 2
[ "$MANAGED_QUEUE_APPROVED_CLUSTER_ARN" = "$QUEUE_CLUSTER_ARN" ] || exit 2
EKS_API=$(aws eks describe-cluster --region "$QUEUE_REGION" --name "$QUEUE_EKS_CLUSTER" --query cluster.endpoint --output text) || exit 2
CONTEXT_API=$(kubectl config view --context "$KUBE_CONTEXT" --minify -o jsonpath='{.clusters[0].cluster.server}') || exit 2
[ -n "$EKS_API" ] && [ "$EKS_API" = "$CONTEXT_API" ] || exit 2
RUN=$(python3 -c 'import uuid; print(uuid.uuid4())') || exit 2
[[ "$RUN" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || exit 2
READER_CONFIG="/tmp/reader-$RUN.properties" WRONG_CONFIG="/tmp/wrong-$RUN.properties"
PHASE=$("${K[@]}" get pod "$POD" -o jsonpath='{.status.phase}') || exit 2
POD_UID=$("${K[@]}" get pod "$POD" -o jsonpath='{.metadata.uid}') || exit 2
[ "$PHASE" = Running ] && [ -n "$POD_UID" ] && [ "$POD_UID" = "$MANAGED_QUEUE_APPROVED_POD_UID" ] || exit 2
umask 077
mkdir -p "$ROOT/local-inputs" || exit 2
REPORT="$ROOT/local-inputs/queue-smoke-managed-$RUN.tsv"
(set -C; : > "$REPORT") || exit 2
RESULT=PASS CONFIG_PENDING=no
note() { printf '%s\t%s\n' "$1" "$2" | tee -a "$REPORT"; }
fail() { RESULT=INCONCLUSIVE; note FAIL "$*"; }
pod() {
  local current
  current=$("${K[@]}" get pod "$POD" -o jsonpath='{.metadata.uid}') || return 2
  [ "$current" = "$POD_UID" ] || return 2
  "${K[@]}" exec -i "$POD" -- "$@"
}
cleanup() {
  if [ "$CONFIG_PENDING" = yes ]; then
    pod sh -c 'rm -f -- "$1" "$2"' sh "$READER_CONFIG" "$WRONG_CONFIG" >/dev/null 2>&1 || return 2
  fi
}
finish() {
  local rc=$?
  trap - EXIT
  unset PASSWORD OUT
  if ! cleanup; then RESULT=INCONCLUSIVE; rc=2; note cleanup_pending "request=$MANAGED_QUEUE_REQUEST_ID pod_uid=$POD_UID reader=$READER_CONFIG wrong=$WRONG_CONFIG"; fi
  [ "$rc" = 0 ] && [ "$RESULT" = PASS ] || { RESULT=INCONCLUSIVE; rc=2; }
  note result "$RESULT"
  echo "MANAGED_QUEUE_SMOKE_${RESULT}; trace_delivery_not_tested; report=$REPORT"
  exit "$rc"
}
trap finish EXIT
trap 'exit 2' INT TERM
USERNAME=$("${K[@]}" get secret queue-managed-e2-reader -o go-template='{{index .data "QUEUE_USERNAME" | base64decode}}' 2>/dev/null) || { fail reader-secret-query-failed; exit 2; }
PASSWORD=$("${K[@]}" get secret queue-managed-e2-reader -o go-template='{{index .data "QUEUE_PASSWORD" | base64decode}}' 2>/dev/null) || { fail reader-secret-query-failed; exit 2; }
[ "$USERNAME" = tempo-consumer ] && [[ "$PASSWORD" =~ ^[A-Za-z0-9_.-]{12,64}$ ]] || { fail reader-secret-invalid; exit 2; }

props() { # 예: props <password> → 클라이언트 설정 파일 내용 (stdin 으로 Pod 에 전달; 화면 · 파일에 남기지 않음)
  echo 'security.protocol=SASL_SSL'; echo 'sasl.mechanism=SCRAM-SHA-512'
  printf 'sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="%s" password="%s";\n' "$USERNAME" "$1"
}
CONFIG_PENDING=yes # 부분 쓰기 실패에도 이번 UUID 경로만 정리합니다.
props "$PASSWORD" | pod sh -c 'umask 077; cat > "$1"' sh "$READER_CONFIG" || { fail reader-config-write; exit 2; }
props "not-the-password-$RUN" | pod sh -c 'umask 077; cat > "$1"' sh "$WRONG_CONFIG" || { fail wrong-config-write; exit 2; }
unset PASSWORD

B="$QUEUE_BOOTSTRAP_SCRAM" T="$QUEUE_TOPIC" G="smoke-$RUN"

OFF1=$(pod bin/kafka-get-offsets.sh --bootstrap-server "$B" --command-config "$READER_CONFIG" --topic "$T" 2> /dev/null) || { fail initial-offset-query; exit 2; }
[ -n "$OFF1" ] || { fail initial-offset-empty; exit 2; }
while IFS=: read -r actual_topic partition offset; do
  [ "$actual_topic" = "$T" ] && [[ "$partition" =~ ^[0-9]+$ ]] && [[ "$offset" =~ ^[0-9]+$ ]] || { fail initial-offset-invalid; exit 2; }
done <<< "$OFF1"
SEEN_PARTITIONS=''
while IFS=: read -r actual_topic partition offset; do
  case "$partition" in 0|1|2) ;; *) fail initial-partition-invalid; exit 2 ;; esac
  [[ " $SEEN_PARTITIONS " != *" $partition "* ]] || { fail initial-partition-duplicate; exit 2; }
  SEEN_PARTITIONS="$SEEN_PARTITIONS $partition"
done <<< "$OFF1"
PARTS=$(printf '%s\n' "$OFF1" | grep -c "^${T}:")
[ "$PARTS" = 3 ] || { fail "partitions=$PARTS (want 3)"; exit 2; }
note reader_three_partitions PASS
OUT=$(pod bin/kafka-console-consumer.sh --bootstrap-server "$B" --consumer.config "$READER_CONFIG" --topic "$T" --group "$G" --max-messages 1 --timeout-ms 20000 2>&1); PROBE_RC=$? # 비정상 종료와 해당 거부 문구를 함께 확인합니다.
if [ "$PROBE_RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -q 'GroupAuthorizationException'; then note reader_unlisted_group_denied PASS; else fail "unlisted group $G was not denied"; fi
# 3. 읽기 사용자로 업무 토픽에 쓰기 → TopicAuthorizationException (원본 reader_write_denied).
OUT=$(printf 'denied\n' | pod bin/kafka-console-producer.sh --bootstrap-server "$B" --producer.config "$READER_CONFIG" --topic "$T" 2>&1); PROBE_RC=$?
if [ "$PROBE_RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -q 'TopicAuthorizationException'; then note reader_write_denied PASS; else fail "reader write to $T was not denied"; fi
# 4. 틀린 비밀번호 → 인증 실패 (원본 invalid_scram_denied).
OUT=$(pod bin/kafka-get-offsets.sh --bootstrap-server "$B" --command-config "$WRONG_CONFIG" --topic "$T" 2>&1); PROBE_RC=$?
if [ "$PROBE_RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qiE 'SaslAuthenticationException|Authentication failed'; then note invalid_scram_denied PASS; else fail "wrong password was not rejected"; fi
# 5. 끝 offset 불변 (이 시험이 업무 토픽에 아무것도 쓰지 않았음).
OFF2=$(pod bin/kafka-get-offsets.sh --bootstrap-server "$B" --command-config "$READER_CONFIG" --topic "$T" 2> /dev/null) || { fail final-offset-query; exit 2; }
[ -n "$OFF1" ] && [ "$OFF1" = "$OFF2" ] && note business_offsets_changed false || fail "offsets changed or unreadable"
note trace_delivery_proven false
[ "$RESULT" = PASS ] && exit 0
exit 2
