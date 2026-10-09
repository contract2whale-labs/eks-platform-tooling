#!/usr/bin/env bash
# platform/environments/dev/queue/scripts/check-drain.sh
# 자체 구축 큐는 브로커 Pod 안에서 localhost:9092(plain) 로, 관리형 큐는 운영자 Pod 에서 읽는 사용자 자격(Secret queue-managed-e2-reader)으로 조회합니다. 아무것도 쓰지 않습니다.
# 판정 DRAINED / NOT_DRAINED / INCONCLUSIVE = 종료 0 / 1 / 2. 조회가 실패했거나 그룹 행이 비었거나 파티션이 빠졌거나 LAG 이 숫자가 아니면 0 으로 치지 않고 INCONCLUSIVE 입니다. 기록: local-inputs/drain-<시각>.tsv (lossless_delivery_proven=false — offset 안정은 "더 안 들어옴" 의 증거이지 무손실 증명이 아님).
# 기록 파일에는 화면에 찍는 줄 외에 파티션별 끝 offset(end_offset_partition)과 그룹이 커밋한 offset(<그룹>_committed_partition)을 파티션마다 한 줄씩 더 남깁니다 — 합으로는 가려지는 파티션별 진척을 뒤에서 비교할 수 있게 합니다(트레이스 소비자의 지연 재현).
# 사용: KUBE_CONTEXT=<context> scripts/check-drain.sh --source self-managed|managed [--topic <토픽>] [--group block-builder] 
set +x
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${KUBE_CONTEXT:?Set the intended EKS context}"
SOURCE='' TOPIC='' GROUP=block-builder 
while [ $# -gt 0 ]; do case "$1" in --source) [ $# -ge 2 ] || exit 2; SOURCE="$2"; shift 2 ;; --topic) [ $# -ge 2 ] || exit 2; TOPIC="$2"; shift 2 ;; --group) [ $# -ge 2 ] || exit 2; GROUP="$2"; shift 2 ;; *) echo "Unknown argument: $1" >&2; exit 2 ;; esac; done
: "${DRAIN_APPROVED_SOURCE:?Set approved source}" "${DRAIN_APPROVED_POD_UID:?Set reviewed broker/admin Pod UID}"
: "${MANAGED_QUEUE_REQUEST_ID:?Set bounded drain request ID}" "${EXPECTED_ACCOUNT_ID:?Set account}" "${AWS_REGION:?Set region}" "${QUEUE_EKS_CLUSTER:?Set EKS cluster}"
[ "$SOURCE" = "$DRAIN_APPROVED_SOURCE" ] || exit 2
[[ "$MANAGED_QUEUE_REQUEST_ID" =~ ^[a-z0-9][a-z0-9-]{7,62}$ ]] || exit 2
[[ "$GROUP" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || exit 2
[ "$ACCOUNT" = "$EXPECTED_ACCOUNT_ID" ] || exit 2
EKS_API=$(aws eks describe-cluster --region "$AWS_REGION" --name "$QUEUE_EKS_CLUSTER" --query cluster.endpoint --output text) || exit 2
CONTEXT_API=$(kubectl config view --context "$KUBE_CONTEXT" --minify -o jsonpath='{.clusters[0].cluster.server}') || exit 2
[ -n "$EKS_API" ] && [ "$EKS_API" = "$CONTEXT_API" ] || exit 2
RUN=$(python3 -c 'import uuid; print(uuid.uuid4())') || exit 2
[[ "$RUN" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || exit 2
umask 077
mkdir -p "$ROOT/local-inputs" || exit 2
REPORT="$ROOT/local-inputs/drain-$RUN.tsv"
(set -C; : > "$REPORT") || exit 2
note() { printf '%s\t%s\n' "$1" "$2" | tee -a "$REPORT"; }
CONFIG_PENDING=no SUMMARY=''
finish() {
  local rc=$?
  trap - EXIT
  unset PASSWORD
  if [ "$CONFIG_PENDING" = yes ] && ! run sh -c 'rm -f -- "$1"' sh "$CLIENT_CONFIG" >/dev/null 2>&1; then
    note cleanup_pending "request=$MANAGED_QUEUE_REQUEST_ID pod_uid=$DRAIN_APPROVED_POD_UID file=$CLIENT_CONFIG"
    echo "INCONCLUSIVE cleanup-failed report=$REPORT"; rc=2; SUMMARY=''
  fi
  [ -z "$SUMMARY" ] || printf '%s\n' "$SUMMARY"
  exit "$rc"
}
trap finish EXIT
trap 'exit 2' INT TERM
case "$SOURCE" in
  self-managed)
    TOPIC="${TOPIC:-platform-traces}"
    BROKER=$(kubectl --context "$KUBE_CONTEXT" -n messaging get pods -l strimzi.io/cluster=platform-queue,strimzi.io/pool-name=broker-2a -o jsonpath='{.items[0].metadata.name}' 2> /dev/null) || exit 2
    [ -n "$BROKER" ] || { echo "INCONCLUSIVE broker-pod-missing"; exit 2; }
    BROKER_UID=$(kubectl --context "$KUBE_CONTEXT" -n messaging get pod "$BROKER" -o jsonpath='{.metadata.uid}') || exit 2
    [ "$BROKER_UID" = "$DRAIN_APPROVED_POD_UID" ] || exit 2
    run() {
      local current
      current=$(kubectl --context "$KUBE_CONTEXT" -n messaging get pod "$BROKER" -o jsonpath='{.metadata.uid}') || return 2
      [ "$current" = "$DRAIN_APPROVED_POD_UID" ] || return 2
      kubectl --context "$KUBE_CONTEXT" -n messaging exec "$BROKER" -c kafka -- "$@"
    }
    BOOT=localhost:9092 CFG=() ;; # 예: 추가 인자 없음 (빈 배열. 아래에서 ${CFG[@]+…} 로 전개 — macOS 기본 bash 3.2 의 set -u 는 빈 배열을 그대로 전개하면 unbound variable 로 멈춤)
  managed)

: "${EXPECTED_ACCOUNT_ID:?Set the approved account ID}"
INFRA_REPO=$(cd "$ROOT/../../../.." && pwd)
QUEUE_JSON=$(python3 "$INFRA_REPO/automation/read_platform_contract.py" --component queue --environment "${ENVIRONMENT:-dev}" --expect-account "$EXPECTED_ACCOUNT_ID") || { echo 'INCONCLUSIVE contract-query-failed'; exit 2; }
QUEUE_CLUSTER_ARN=$(printf '%s' "$QUEUE_JSON" | jq -er '.cluster_arn') || exit 2
QUEUE_CLUSTER_NAME=$(printf '%s' "$QUEUE_JSON" | jq -er '.cluster_name') || exit 2
QUEUE_BOOTSTRAP_SCRAM=$(printf '%s' "$QUEUE_JSON" | jq -er '.bootstrap_brokers_scram') || exit 2
QUEUE_KMS_KEY_ARN=$(printf '%s' "$QUEUE_JSON" | jq -er '.kms_key_arn') || exit 2
QUEUE_TOPIC=$(printf '%s' "$QUEUE_JSON" | jq -er '.topic_name') || exit 2
QUEUE_PARTITIONS=$(printf '%s' "$QUEUE_JSON" | jq -er '.partitions') || exit 2
QUEUE_REGION=${AWS_REGION:?Set the approved region}
QUEUE_WRITER_USERNAME=tempo-distributor
QUEUE_READER_USERNAME=tempo-consumer
unset QUEUE_JSON
    # shellcheck source=/dev/null
    TOPIC="${TOPIC:-$QUEUE_TOPIC}"
    : "${MANAGED_QUEUE_APPROVED_CLUSTER_ARN:?Set approved MSK ARN}"
    [ "$MANAGED_QUEUE_APPROVED_CLUSTER_ARN" = "$QUEUE_CLUSTER_ARN" ] && [ "$TOPIC" = "$QUEUE_TOPIC" ] || exit 2
    K=(kubectl --context "$KUBE_CONTEXT" -n monitoring)
    POD_UID=$("${K[@]}" get pod queue-admin -o jsonpath='{.metadata.uid}') || exit 2
    [ "$POD_UID" = "$DRAIN_APPROVED_POD_UID" ] || exit 2
    run() {
      local current
      current=$("${K[@]}" get pod queue-admin -o jsonpath='{.metadata.uid}') || return 2
      [ "$current" = "$DRAIN_APPROVED_POD_UID" ] || return 2
      "${K[@]}" exec -i queue-admin -- "$@"
    }
    CLIENT_CONFIG="/tmp/drain-reader-$RUN.properties"
    USERNAME=$("${K[@]}" get secret queue-managed-e2-reader -o go-template='{{index .data "QUEUE_USERNAME" | base64decode}}' 2>/dev/null) || exit 2
    PASSWORD=$("${K[@]}" get secret queue-managed-e2-reader -o go-template='{{index .data "QUEUE_PASSWORD" | base64decode}}' 2>/dev/null) || exit 2
    [ "$USERNAME" = tempo-consumer ] && [[ "$PASSWORD" =~ ^[A-Za-z0-9_.-]{12,64}$ ]] || exit 2
    CONFIG_PENDING=yes
    { echo 'security.protocol=SASL_SSL'; echo 'sasl.mechanism=SCRAM-SHA-512'
      printf 'sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="%s" password="%s";\n' "$USERNAME" "$PASSWORD"; } |
      run sh -c 'umask 077; cat > "$1"' sh "$CLIENT_CONFIG" || { echo "INCONCLUSIVE cannot-write-reader-properties"; exit 2; }
    unset PASSWORD
    BOOT="$QUEUE_BOOTSTRAP_SCRAM" CFG=(--command-config "$CLIENT_CONFIG") ;;
  *) echo "usage: scripts/check-drain.sh --source self-managed|managed" >&2; exit 2 ;;
esac
[[ "$TOPIC" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
inconclusive() { note inconclusive "$1"; note lossless_delivery_proven false; echo "INCONCLUSIVE $1 report=$REPORT"; exit 2; } # 예: 조회가 실패했거나 읽은 값으로 판정할 수 없을 때 (0 으로 간주하지 않음)
note source "$SOURCE"; note topic "$TOPIC"
# 1. 끝 offset 을 10초 간격으로 두 번 읽습니다. 조회 실패 · 빈 출력 · "<토픽>:<파티션>:<숫자>" 가 아닌 줄은 판정 불가입니다.
offsets() { run bin/kafka-get-offsets.sh --bootstrap-server "$BOOT" ${CFG[@]+"${CFG[@]}"} --topic "$TOPIC" 2> /dev/null | sort; }
valid_offsets() {
  [ -n "$1" ] || return 1
  printf '%s\n' "$1" | awk -F: -v topic="$TOPIC" '
    NF != 3 || $1 != topic || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ { bad=1 }
    { seen[$2]++; rows++ }
    END { if (rows != 3 || seen[0] != 1 || seen[1] != 1 || seen[2] != 1) bad=1; exit bad }'
}
BEFORE=$(offsets) || inconclusive offsets-query-failed
valid_offsets "$BEFORE" || inconclusive offsets-unreadable
INTERVAL=${DRAIN_INTERVAL_SECONDS:-10}
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || inconclusive invalid-interval
[ "$INTERVAL" = 0 ] || sleep "$INTERVAL" || inconclusive wait-failed # 예: 10 (검사는 0 으로 줄여 씀)
AFTER=$(offsets) || inconclusive offsets-query-failed
valid_offsets "$AFTER" || inconclusive offsets-unreadable
SUM=$(printf '%s\n' "$AFTER" | awk -F: '{s+=$3} END {print s+0}')
PARTITIONS=$(printf '%s\n' "$AFTER" | awk -F: '{print $2}' | sort -n | tr '\n' ' ') # 예: "0 1 2 " (토픽의 실제 파티션 = 그룹 조회에 있어야 하는 행)
[ "$BEFORE" = "$AFTER" ] && STABLE=true || STABLE=false
note end_offset_sum "$SUM"; note stable_end_offsets "$STABLE"
printf '%s\n' "$AFTER" | awk -F: '{ printf "end_offset_partition\t%s\t%s\n", $2, $3 }' >> "$REPORT" # 예: end_offset_partition<탭>1<탭>11 (기록 파일에만)
# 2. 소비자 그룹의 LAG: 조회 종료 코드, 머리글의 열 이름(GROUP · TOPIC · PARTITION · LAG), 파티션마다 한 행, 숫자인 LAG 을 모두 확인합니다.
#    조회 실패 · 없는 그룹 · 빈 출력 · 빠진 파티션 · LAG "-"(commit 한 offset 없음) 는 lag=0 이 아니라 판정 불가입니다.
DESCRIBE=$(run bin/kafka-consumer-groups.sh --bootstrap-server "$BOOT" ${CFG[@]+"${CFG[@]}"} --describe --group "$GROUP" 2>&1); DESCRIBE_RC=$?
if [ "$DESCRIBE_RC" -ne 0 ]; then printf '%s\n' "$DESCRIBE" | tail -3 >&2; inconclusive "group-describe-failed:rc=$DESCRIBE_RC"; fi
read -r ROWS MISSING NONNUMERIC LAG <<< "$(printf '%s\n' "$DESCRIBE" | awk -v g="$GROUP" -v t="$TOPIC" -v parts="$PARTITIONS" '
  $1 == "GROUP" { for (i = 1; i <= NF; i++) col[$i] = i; next }
  col["LAG"] && col["TOPIC"] && col["PARTITION"] && $1 == g && $col["TOPIC"] == t { rows++; seen[$col["PARTITION"]]++; if ($col["LAG"] ~ /^[0-9]+$/ && col["CURRENT-OFFSET"] && $col["CURRENT-OFFSET"] ~ /^[0-9]+$/) lag += $col["LAG"]; else bad++ }
  END { n = split(parts, want, " "); for (i = 1; i <= n; i++) if (seen[want[i]] != 1) missing++; printf "%d %d %d %d\n", rows, missing, bad, lag }')"
[[ "$ROWS" =~ ^[0-9]+$ && "$MISSING" =~ ^[0-9]+$ && "$NONNUMERIC" =~ ^[0-9]+$ && "$LAG" =~ ^[0-9]+$ ]] || inconclusive group-output-invalid
[ "$ROWS" -gt 0 ] || inconclusive "group-rows-missing:$GROUP"
[ "$MISSING" -eq 0 ] || inconclusive "group-partitions-missing:$MISSING"
[ "$ROWS" -eq 3 ] || inconclusive "group-partition-row-count:$ROWS"
[ "$NONNUMERIC" -eq 0 ] || inconclusive "group-lag-not-numeric:$NONNUMERIC"
printf '%s\n' "$DESCRIBE" | awk -v g="$GROUP" -v t="$TOPIC" '$1 == "GROUP" { for (i = 1; i <= NF; i++) col[$i] = i; next }
  col["CURRENT-OFFSET"] && $1 == g && $col["TOPIC"] == t && $col["CURRENT-OFFSET"] ~ /^[0-9]+$/ { printf "%s_committed_partition\t%s\t%s\n", g, $col["PARTITION"], $col["CURRENT-OFFSET"] }' >> "$REPORT"
note "${GROUP}_lag" "$LAG"; note lossless_delivery_proven false
if [ "$STABLE" = true ] && [ "$LAG" -eq 0 ]; then SUMMARY="DRAINED stable_end_offsets=true lag=0 end=$SUM report=$REPORT"; exit 0; fi
SUMMARY="NOT_DRAINED stable_end_offsets=$STABLE lag=$LAG report=$REPORT"; exit 1
