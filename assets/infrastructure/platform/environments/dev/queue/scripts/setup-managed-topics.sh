#!/usr/bin/env bash
# platform/environments/dev/queue/scripts/setup-managed-topics.sh
# 권한 모델과 토픽 사전 생성: 관리형 큐에 토픽을 만들고 권한을 겁니다. 자체 구축 큐의 토픽 · 접근 제어 선언(gitops/platform/kafka/overlays/dev의 KafkaTopic · KafkaUser)과 같은 값을 명령으로 옮긴 것입니다 (원본 setup-managed-topics.sh + queue_client.py 의 셸 · kubectl · aws CLI 버전).
# 관리 자격(queue-admin)은 이 스크립트가 돌아가는 동안에만 존재합니다: 시크릿 생성 → 클러스터 연결 → 운영자 Pod 로 전달 → 토픽 · ACL → 대조 → 임시 토픽 왕복 → 연결 해제 · 삭제. Kafka 의 관리자 ACL 은 다음 실행(재실행 · 복귀)을 위해 남깁니다.
# 판정 PASS / FAIL / INCONCLUSIVE = 종료 0 / 1 / 2 ("PASS checked=<n> diff=0"). 여러 번 실행해도 결과가 같습니다 (--if-not-exists · ACL add 는 멱등).
# 사용: 승인된 배타 작업 창에서 MANAGED_QUEUE_REQUEST_ID와 MANAGED_QUEUE_APPROVED_CLUSTER_ARN을 지정합니다.
# 재시도 전 cleanup_pending의 임시 Secret/topic/Pod 파일을 승인 범위에서 확인합니다. 기존 reader/writer Secret·업무 토픽 데이터는 정리하지 않습니다.
set +x # 비밀번호 생성·stdin 전달을 xtrace로 노출하지 않습니다.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMPO_E2_RELEASE=platform-tempo-e2
TEMPO_MANAGED_IMAGE_VERSION=main-6047d8b-1995-1
QUEUE_ADMIN_USERNAME=queue-admin
: "${KUBE_CONTEXT:?Set the intended EKS context}"
: "${EXPECTED_ACCOUNT_ID:?Set the approved account ID}"
: "${MANAGED_QUEUE_REQUEST_ID:?Set the approved bounded operation request ID}"
: "${MANAGED_QUEUE_APPROVED_CLUSTER_ARN:?Set the cluster ARN from that approval}"
: "${MANAGED_QUEUE_APPROVED_POD_UID:?Set the queue-admin Pod UID from the reviewed sync}"
: "${QUEUE_EKS_CLUSTER:?Set the EKS cluster from the queue diagnostic coordinates}"
[[ "$MANAGED_QUEUE_REQUEST_ID" =~ ^[a-z0-9][a-z0-9-]{7,62}$ ]] || exit 2
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

hold() { echo "INCONCLUSIVE $1"; exit 2; } # 예: 재료가 없으면 아무것도 만들지 않고 보류로 끝냅니다
# shellcheck source=/dev/null

for name in QUEUE_REGION QUEUE_CLUSTER_ARN QUEUE_CLUSTER_NAME QUEUE_BOOTSTRAP_SCRAM QUEUE_KMS_KEY_ARN QUEUE_TOPIC QUEUE_PARTITIONS QUEUE_WRITER_USERNAME QUEUE_READER_USERNAME; do
  [ -n "${!name:-}" ] || hold "contract-key-empty:$name"
done
for TOOL in aws kubectl jq python3; do command -v "$TOOL" > /dev/null || hold "missing-tool:$TOOL"; done
[ "$QUEUE_CLUSTER_ARN" = "$MANAGED_QUEUE_APPROVED_CLUSTER_ARN" ] || hold approved-cluster-mismatch
[[ "$QUEUE_CLUSTER_ARN" == "arn:aws:kafka:$QUEUE_REGION:$EXPECTED_ACCOUNT_ID:cluster/$QUEUE_CLUSTER_NAME/"* ]] || hold cluster-identity-boundary
[[ "$QUEUE_KMS_KEY_ARN" == "arn:aws:kms:$QUEUE_REGION:$EXPECTED_ACCOUNT_ID:key/"* ]] || hold key-identity-boundary
[[ "$QUEUE_CLUSTER_NAME" =~ ^[a-zA-Z0-9-]+$ ]] || hold cluster-name-invalid
[ "$QUEUE_PARTITIONS" = 3 ] || hold partitions-invalid
EKS_API=$(aws eks describe-cluster --region "$QUEUE_REGION" --name "$QUEUE_EKS_CLUSTER" --query cluster.endpoint --output text) || hold eks-identity-query-failed
CONTEXT_API=$(kubectl config view --context "$KUBE_CONTEXT" --minify -o jsonpath='{.clusters[0].cluster.server}') || hold context-query-failed
[ -n "$EKS_API" ] && [ "$EKS_API" = "$CONTEXT_API" ] || hold kube-context-boundary
NS=monitoring POD=queue-admin
K=(kubectl --context "$KUBE_CONTEXT" -n "$NS")
POD_PHASE=$("${K[@]}" get pod "$POD" -o jsonpath='{.status.phase}') || hold client-pod-query-failed
[ "$POD_PHASE" = Running ] || hold client-pod-not-running
POD_UID=$("${K[@]}" get pod "$POD" -o jsonpath='{.metadata.uid}') || hold client-pod-uid-query-failed
[ -n "$POD_UID" ] && [ "$POD_UID" = "$MANAGED_QUEUE_APPROVED_POD_UID" ] || hold client-pod-uid-boundary
ADMIN_USER=queue-admin # 승인된 기존 관리 principal; ACL은 기존 정책대로 유지합니다.
RUN_ID=$(python3 -c 'import uuid; print(uuid.uuid4())') || hold uuid-generation-failed
[[ "$RUN_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || hold invalid-run-id
CLIENT_CONFIG="/tmp/queue-admin-$RUN_ID.properties"
SMOKE="smoke-$RUN_ID"
ADMIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))') || hold password-generation-failed
[[ "$ADMIN_PASSWORD" =~ ^[A-Za-z0-9_.-]{12,64}$ ]] || hold admin-password-charset
[ "$QUEUE_WRITER_USERNAME" = tempo-distributor ] && [ "$QUEUE_READER_USERNAME" = tempo-consumer ] || hold fixed-principals-required
LITERAL_GROUPS=(block-builder metrics-generator)
PREFIX_GROUPS=("${TEMPO_E2_RELEASE}-live-store-zone-a" "${TEMPO_E2_RELEASE}-live-store-zone-b" "${TEMPO_E2_RELEASE}-live-store-zone-c")
TOTAL=0 DIFF=0
same() { TOTAL=$((TOTAL + 1)); if [ "$2" = "$3" ]; then printf 'OK    %-34s %s\n' "$1" "$3"; else printf 'DIFF  %-34s expected=%s actual=%s\n' "$1" "$2" "$3"; DIFF=$((DIFF + 1)); fi; }
pod() {
  local CURRENT_POD_UID
  CURRENT_POD_UID=$("${K[@]}" get pod "$POD" -o jsonpath='{.metadata.uid}') || return 2
  [ "$CURRENT_POD_UID" = "$POD_UID" ] || return 2
  "${K[@]}" exec -i "$POD" -- "$@"
}
kt()  { pod bin/kafka-topics.sh --bootstrap-server "$QUEUE_BOOTSTRAP_SCRAM" --command-config "$CLIENT_CONFIG" "$@"; }
acl() { pod bin/kafka-acls.sh --bootstrap-server "$QUEUE_BOOTSTRAP_SCRAM" --command-config "$CLIENT_CONFIG" "$@" > /dev/null 2>&1; }
umask 077
mkdir -p "$ROOT/local-inputs" || hold report-directory-failed
REPORT="$ROOT/local-inputs/managed-topics-$RUN_ID.txt"
(set -C; : > "$REPORT") || hold report-collision
WORK='' ADMIN_SECRET_ARN='' CREATE_PENDING=no SMOKE_CREATED=no SMOKE_PENDING=no CONFIG_PENDING=no
ADMIN_SECRET_NAME="AmazonMSK_${QUEUE_CLUSTER_NAME}_${ADMIN_USER}_${RUN_ID}"
cleanup() {
  local failed=0 CURRENT LEFT DELETED
  if [ "$SMOKE_CREATED" = yes ]; then
    kt --delete --topic "$SMOKE" >/dev/null 2>&1 || failed=1
  elif [ "$SMOKE_PENDING" = yes ]; then
    failed=1 # 생성 응답이 불명인 토픽은 인수·삭제하지 않습니다.
  fi
  if [ "$CONFIG_PENDING" = yes ]; then
    pod sh -c 'rm -f -- "$1"' sh "$CLIENT_CONFIG" >/dev/null 2>&1 || failed=1
  fi
  # 현재 생성 응답에서 확정한 ARN만 대상입니다. 다른 이름·태그·키이면 정리하지 않습니다.
  if [ -n "$ADMIN_SECRET_ARN" ]; then
    if ! CURRENT=$(aws secretsmanager describe-secret --region "$QUEUE_REGION" --secret-id "$ADMIN_SECRET_ARN" --output json 2>/dev/null); then
      failed=1
    elif ! printf '%s' "$CURRENT" | jq -e --arg arn "$ADMIN_SECRET_ARN" --arg name "$ADMIN_SECRET_NAME" --arg run "$RUN_ID" --arg request "$MANAGED_QUEUE_REQUEST_ID" --arg key "$QUEUE_KMS_KEY_ARN" '
      .ARN == $arn and .Name == $name and .KmsKeyId == $key and
      any(.Tags[]?; .Key == "platform-queue-run" and .Value == $run) and
      any(.Tags[]?; .Key == "platform-queue-request" and .Value == $request)' >/dev/null; then
      failed=1
    else
      if ! LEFT=$(aws kafka batch-disassociate-scram-secret --region "$QUEUE_REGION" --cluster-arn "$QUEUE_CLUSTER_ARN" --secret-arn-list "$ADMIN_SECRET_ARN" --query 'length(UnprocessedScramSecrets)' --output text 2>/dev/null) || [ "$LEFT" != 0 ]; then
        failed=1
      elif ! DELETED=$(aws secretsmanager delete-secret --region "$QUEUE_REGION" --secret-id "$ADMIN_SECRET_ARN" --force-delete-without-recovery --query ARN --output text 2>/dev/null) || [ "$DELETED" != "$ADMIN_SECRET_ARN" ]; then
        failed=1
      fi
    fi
  elif [ "$CREATE_PENDING" = yes ]; then
    failed=1 # 생성 실패·응답 불명에서는 기존 Secret을 인수하지 않습니다.
  fi
  if [ -n "$WORK" ]; then rm -rf -- "$WORK" || failed=1; fi
  if [ "$failed" != 0 ]; then
    printf 'CLEANUP_INCOMPLETE request=%s run=%s admin_secret_name=%s admin_secret_arn=%s smoke_topic=%s client_config=%s\n' "$MANAGED_QUEUE_REQUEST_ID" "$RUN_ID" "$ADMIN_SECRET_NAME" "$ADMIN_SECRET_ARN" "$SMOKE" "$CLIENT_CONFIG" >&2
    return 2
  fi
  printf 'cleanup complete request=%s run=%s; temporary credential removal requested\n' "$MANAGED_QUEUE_REQUEST_ID" "$RUN_ID"
}
finish() {
  local rc=$?
  trap - EXIT
  unset ADMIN_PASSWORD MANAGED_QUEUE_ADMIN_PASSWORD
  cleanup || rc=2
  case "$rc" in
    0) printf 'PASS checked=%s diff=0 report=%s\n' "$TOTAL" "$REPORT" ;;
    1) printf 'FAIL checked=%s diff=%s report=%s\n' "$TOTAL" "$DIFF" "$REPORT" ;;
    *) printf 'INCONCLUSIVE request=%s run=%s report=%s\n' "$MANAGED_QUEUE_REQUEST_ID" "$RUN_ID" "$REPORT" ;;
  esac
  exit "$rc"
}
trap finish EXIT
trap 'exit 2' INT TERM

# 1. UUID별 새 Secret만 create합니다. 동명 인수·put-secret-value·조회 오류 뒤 create fallback은 없습니다.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/queue-admin.XXXXXX") || hold tmpdir
printf '{"username":"%s","password":"%s"}\n' "$ADMIN_USER" "$ADMIN_PASSWORD" > "$WORK/secret.json" || hold private-file-write-failed
CREATE_PENDING=yes
CREATED_ARN=$(aws secretsmanager create-secret --region "$QUEUE_REGION" --name "$ADMIN_SECRET_NAME" --kms-key-id "$QUEUE_KMS_KEY_ARN" \
  --secret-string "file://$WORK/secret.json" --tags "Key=platform-queue-run,Value=$RUN_ID" "Key=platform-queue-request,Value=$MANAGED_QUEUE_REQUEST_ID" --query ARN --output text 2>/dev/null) || hold admin-secret-create-unconfirmed
[[ "$CREATED_ARN" == "arn:aws:secretsmanager:$QUEUE_REGION:$EXPECTED_ACCOUNT_ID:secret:$ADMIN_SECRET_NAME-"* ]] || hold admin-secret-response-unconfirmed
ADMIN_SECRET_ARN="$CREATED_ARN"; CREATE_PENDING=no
printf 'temporary identity request=%s run=%s admin_secret_name=%s admin_secret_arn=%s\n' "$MANAGED_QUEUE_REQUEST_ID" "$RUN_ID" "$ADMIN_SECRET_NAME" "$ADMIN_SECRET_ARN" >> "$REPORT" || hold report-write-failed
LEFT=$(aws kafka batch-associate-scram-secret --region "$QUEUE_REGION" --cluster-arn "$QUEUE_CLUSTER_ARN" --secret-arn-list "$ADMIN_SECRET_ARN" --query 'length(UnprocessedScramSecrets)' --output text 2>/dev/null) || hold admin-secret-associate-query-failed
[ "$LEFT" = 0 ] || hold admin-secret-associate-incomplete

# 2. 운영자 Pod 에 클라이언트 설정을 stdin 으로 넣고(파일만, 0600) MSK 의 주기적 동기화를 기다립니다 (최대 5분).
CONFIG_PENDING=yes
{
  echo 'security.protocol=SASL_SSL'
  echo 'sasl.mechanism=SCRAM-SHA-512'
  printf 'sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="%s" password="%s";\n' "$ADMIN_USER" "$ADMIN_PASSWORD"
} | pod sh -c 'umask 077; cat > "$1"' sh "$CLIENT_CONFIG" || hold client-config-write-failed
rm -f "$WORK/secret.json" || hold private-file-remove-failed
unset ADMIN_PASSWORD MANAGED_QUEUE_ADMIN_PASSWORD
READY=no
for _ in $(seq 1 30); do
  if kt --list > "$WORK/topics-before.txt" 2> /dev/null; then READY=yes; break; fi
  sleep 10 || hold authentication-wait-failed
done
[ "$READY" = yes ] || hold admin-authentication-not-ready

# 3. 관리자 ACL 을 먼저 남겨야 뒤의 제한 규칙을 적용한 뒤에도 CreateAcls 를 실행할 수 있습니다.
acl --add --allow-principal "User:${ADMIN_USER}" --operation All --cluster     || hold admin-cluster-acl-failed
acl --add --allow-principal "User:${ADMIN_USER}" --operation All --topic '*'   || hold admin-topic-acl-failed
acl --add --allow-principal "User:${ADMIN_USER}" --operation All --group '*'   || hold admin-group-acl-failed

# 4. 토픽: 값은 자체 구축 큐의 토픽 선언(gitops/platform/kafka/overlays/dev/topic.yaml)과 같습니다.
kt --create --if-not-exists --topic "$QUEUE_TOPIC" --partitions "$QUEUE_PARTITIONS" --replication-factor 3 \
  --config min.insync.replicas=2 --config retention.ms=43200000 --config retention.bytes=-1 --config segment.bytes=268435456 \
  --config cleanup.policy=delete --config compression.type=producer --config max.message.bytes=16000000 > /dev/null 2>&1 || hold topic-create-failed

# 5. 권한: 자체 구축 쪽 접근 제어 선언(gitops/platform/kafka/overlays/dev/kafkauser-tempo-*.yaml)의 규칙을 같은 순서로 옮긴 것입니다 (쓰기 4 · 읽기 2 + 그룹 5×2 + 거부 4 = 20).
acl --add --allow-principal "User:${QUEUE_WRITER_USERNAME}" --operation Write --operation Describe --topic "$QUEUE_TOPIC" || hold acl-writer-allow-failed
acl --add --deny-principal  "User:${QUEUE_WRITER_USERNAME}" --operation Create --topic '*'                                 || hold acl-writer-deny-topic-failed
acl --add --deny-principal  "User:${QUEUE_WRITER_USERNAME}" --operation Create --cluster                                   || hold acl-writer-deny-cluster-failed
acl --add --allow-principal "User:${QUEUE_READER_USERNAME}" --operation Read --operation Describe --topic "$QUEUE_TOPIC"   || hold acl-reader-allow-failed
for group in "${LITERAL_GROUPS[@]}"; do
  acl --add --allow-principal "User:${QUEUE_READER_USERNAME}" --operation Read --operation Describe --group "$group" || hold "acl-group-failed:$group"
done
for group in "${PREFIX_GROUPS[@]}"; do
  acl --add --allow-principal "User:${QUEUE_READER_USERNAME}" --operation Read --operation Describe --group "$group" --resource-pattern-type prefixed || hold "acl-group-prefix-failed:$group"
done
acl --add --deny-principal "User:${QUEUE_READER_USERNAME}" --operation Write --operation Create --operation Delete --topic '*' || hold acl-reader-deny-topic-failed
acl --add --deny-principal "User:${QUEUE_READER_USERNAME}" --operation Create --cluster                                       || hold acl-reader-deny-cluster-failed

# 6. 만든 결과를 자체 구축 쪽 값과 대조합니다 (토픽 설정 + ACL의 실제 접근 경계 + 격리 왕복).
DESC=$(kt --describe --topic "$QUEUE_TOPIC" 2> /dev/null) || hold topic-describe-failed
pick() { printf '%s\n' "$DESC" | grep -o "$1" | head -1 | tr -d ' ' | cut -d"$2" -f2; }
# 출력 필드가 없거나 해석되지 않으면 실제 설정 차이로 단정하지 않습니다.
for FIELD in 'PartitionCount: [0-9]*' 'ReplicationFactor: [0-9]*' 'min\.insync\.replicas=[0-9]*' 'retention\.ms=[0-9]*' 'max\.message\.bytes=[0-9]*' 'retention\.bytes=-*[0-9]*' 'segment\.bytes=[0-9]*' 'cleanup\.policy=[a-z]*' 'compression\.type=[a-z]*'; do
  printf '%s\n' "$DESC" | grep -q "$FIELD" || hold topic-output-not-understood
done
PARTITIONS=$(pick 'PartitionCount: [0-9]*' ':') || hold topic-output-not-understood
REPLICATION=$(pick 'ReplicationFactor: [0-9]*' ':') || hold topic-output-not-understood
MIN_INSYNC=$(pick 'min\.insync\.replicas=[0-9]*' '=') || hold topic-output-not-understood
RETENTION_MS=$(pick 'retention\.ms=[0-9]*' '=') || hold topic-output-not-understood
MAX_BYTES=$(pick 'max\.message\.bytes=[0-9]*' '=') || hold topic-output-not-understood
RETENTION_BYTES=$(pick 'retention\.bytes=-*[0-9]*' '=') || hold topic-output-not-understood
SEGMENT_BYTES=$(pick 'segment\.bytes=[0-9]*' '=') || hold topic-output-not-understood
CLEANUP_POLICY=$(pick 'cleanup\.policy=[a-z]*' '=') || hold topic-output-not-understood
COMPRESSION=$(pick 'compression\.type=[a-z]*' '=') || hold topic-output-not-understood
[[ "$PARTITIONS" =~ ^[0-9]+$ && "$REPLICATION" =~ ^[0-9]+$ && "$MIN_INSYNC" =~ ^[0-9]+$ && "$RETENTION_MS" =~ ^[0-9]+$ && "$MAX_BYTES" =~ ^[0-9]+$ && "$RETENTION_BYTES" =~ ^-?[0-9]+$ && "$SEGMENT_BYTES" =~ ^[0-9]+$ && -n "$CLEANUP_POLICY" && -n "$COMPRESSION" ]] || hold topic-output-not-understood
same 'topic.partitions' "$QUEUE_PARTITIONS" "$PARTITIONS"
same 'topic.replication' 3 "$REPLICATION"
same 'topic.min.insync' 2 "$MIN_INSYNC"
same 'topic.retention.ms' 43200000 "$RETENTION_MS"
same 'topic.max.message.bytes' 16000000 "$MAX_BYTES"
same 'topic.retention.bytes' -1 "$RETENTION_BYTES"
same 'topic.segment.bytes' 268435456 "$SEGMENT_BYTES"
same 'topic.cleanup.policy' delete "$CLEANUP_POLICY"
same 'topic.compression.type' producer "$COMPRESSION"
ACLS=$(pod bin/kafka-acls.sh --bootstrap-server "$QUEUE_BOOTSTRAP_SCRAM" --command-config "$CLIENT_CONFIG" --list 2> /dev/null) || hold acl-list-failed
ACL_RC=0
printf '%s\n' "$ACLS" | python3 "$ROOT/scripts/verify-managed-acls.py" \
  --topic "$QUEUE_TOPIC" --writer "$QUEUE_WRITER_USERNAME" --reader "$QUEUE_READER_USERNAME" \
  --release "$TEMPO_E2_RELEASE" || ACL_RC=$?
case "$ACL_RC" in 0|1) ;; *) hold acl-output-not-understood ;; esac
same 'acl.semantic_boundary' 0 "$ACL_RC"
{ printf '%s\n' "$DESC"; printf '%s\n' "$ACLS"; } >> "$REPORT" || hold report-write-failed # 예: 시크릿 없는 조회 결과만 기록 (사양 · 문서 대조용)

# 7. 격리 왕복: 임시 토픽(1파티션)에 관리자로 3건 쓰고 읽은 뒤 지웁니다 — TLS · SASL 경로가 실제로 통하는지만 봅니다 (업무 토픽에는 쓰지 않음).
SMOKE_PENDING=yes
kt --create --topic "$SMOKE" --partitions 1 --replication-factor 3 --config min.insync.replicas=2 > /dev/null 2>&1 || hold smoke-topic-create-failed
SMOKE_CREATED=yes; SMOKE_PENDING=no
printf 'one\ntwo\nthree\n' | pod bin/kafka-console-producer.sh --bootstrap-server "$QUEUE_BOOTSTRAP_SCRAM" --producer.config "$CLIENT_CONFIG" --topic "$SMOKE" > /dev/null 2>&1 || hold smoke-produce-failed
CONSUMED=$(pod bin/kafka-console-consumer.sh --bootstrap-server "$QUEUE_BOOTSTRAP_SCRAM" --consumer.config "$CLIENT_CONFIG" --topic "$SMOKE" --group "$SMOKE" --from-beginning --max-messages 3 --timeout-ms 60000 2> /dev/null | grep -c .) || hold smoke-consume-failed
kt --delete --topic "$SMOKE" > /dev/null 2>&1 || hold "smoke-topic-delete-failed:$SMOKE"
SMOKE_CREATED=no
same 'smoke.isolated_roundtrip' 3 "$CONSUMED"

# 8. EXIT trap이 실패 시에도 정리하고, 정리 결과 뒤에 최종 판정을 출력합니다.
[ "$DIFF" -eq 0 ] && exit 0
exit 1
