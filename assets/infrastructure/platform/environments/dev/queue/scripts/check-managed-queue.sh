#!/usr/bin/env bash
# platform/environments/dev/queue/scripts/check-managed-queue.sh
# 병렬 설정과 연결 시험: 병렬 Tempo release(epoch 2) 가 계약(structured Terraform diagnostic output)대로 관리형 큐를 바라보고 준비되었는지 대조합니다 (원본 check_tempo.py + selection.py 판정의 셸 버전). 읽기 조회만 합니다.
# 판정 PASS / FAIL / INCONCLUSIVE = 종료 0 / 1 / 2 ("PASS checked=<n> diff=0"). 업무 trace 경로는 판정하지 않습니다 (trace-probe.sh).
# 사용: KUBE_CONTEXT=<context> scripts/check-managed-queue.sh  [--release platform-tempo-e2]
set +x
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMPO_E2_RELEASE=platform-tempo-e2
RELEASE=$TEMPO_E2_RELEASE
TEMPO_MANAGED_IMAGE_VERSION=main-6047d8b-1995-1
QUEUE_ADMIN_USERNAME=queue-admin
: "${KUBE_CONTEXT:?Set the intended EKS context}"
: "${EXPECTED_ACCOUNT_ID:?Set the approved account ID}"
: "${APPROVED_GIT_REVISION:?Set full approved Tempo source SHA}"
[[ "$APPROVED_GIT_REVISION" =~ ^[0-9a-f]{40}$ ]] || exit 2
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

while [ $# -gt 0 ]; do case "$1" in --release) [ $# -ge 2 ] || exit 2; RELEASE="$2"; shift 2 ;; *) echo "Unknown argument: $1" >&2; exit 2 ;; esac; done
[[ "$RELEASE" =~ ^platform-tempo-e[23]$ ]] || exit 2
# shellcheck source=/dev/null

NS=monitoring; K=(kubectl --context "$KUBE_CONTEXT" -n "$NS")
CHECKED=0 DIFF=0 UNKNOWN=0
ok()   { CHECKED=$((CHECKED + 1)); printf 'OK    %s\n' "$*"; }
bad()  { CHECKED=$((CHECKED + 1)); DIFF=$((DIFF + 1)); printf 'DIFF  %s\n' "$*"; }
skip() { UNKNOWN=$((UNKNOWN + 1)); printf 'SKIP  %s\n' "$*"; }
get() { "${K[@]}" get "$@" 2> /dev/null; }
query_value() { # API 오류를 실제 응답 차이와 구분합니다.
  local label=$1; shift
  VALUE=''
  if ! VALUE=$("$@" 2>/dev/null); then skip "$label query-failed"; return 2; fi
}
equal_query() {
  local label=$1 expected=$2; shift 2
  query_value "$label" "$@" || return 0
  [ -n "$VALUE" ] && [ "$VALUE" != null ] || { skip "$label unparsed-or-missing"; return 0; }
  [ "$VALUE" = "$expected" ] && ok "$label" || bad "$label differs"
}

equal_query argocd.operation-phase Succeeded kubectl --context "$KUBE_CONTEXT" -n argocd get application "${RELEASE}-${ENVIRONMENT:-dev}" -o jsonpath='{.status.operationState.phase}'
equal_query argocd.source-revision "$APPROVED_GIT_REVISION" kubectl --context "$KUBE_CONTEXT" -n argocd get application "${RELEASE}-${ENVIRONMENT:-dev}" -o jsonpath='{.status.operationState.syncResult.revision}'

# 1. release 상태와 렌더된 설정(ConfigMap) 의 큐 부분: 주소 · 토픽 · 인증 · TLS · 자동 생성 · 파티션, 비밀번호는 자리(${QUEUE_PASSWORD}) 그대로.
equal_query "argocd.$RELEASE" Synced:Healthy kubectl --context "$KUBE_CONTEXT" -n argocd get application "${RELEASE}-${ENVIRONMENT:-dev}" -o jsonpath='{.status.sync.status}:{.status.health.status}'
if query_value configmap get configmap "${RELEASE}-config" -o jsonpath='{.data.tempo\.yaml}'; then
  CFG=$VALUE
  if [ -z "$CFG" ]; then bad 'configmap config empty'; else
    q() { printf '%s\n' "$CFG" | yq -r "$1"; }
    equal_query config.kafka.address "$QUEUE_BOOTSTRAP_SCRAM" q '.ingest.kafka.address'
    equal_query config.kafka.topic "$QUEUE_TOPIC" q '.ingest.kafka.topic'
    equal_query config.kafka.sasl_mechanism SCRAM-SHA-512 q '.ingest.kafka.sasl_mechanism'
    equal_query config.kafka.tls_enabled true q '.ingest.kafka.tls_enabled'
    equal_query config.kafka.auto_create false q '.ingest.kafka.auto_create_topic_enabled'
    equal_query config.kafka.partitions "$QUEUE_PARTITIONS" q '.ingest.kafka.auto_create_topic_default_partitions'
    equal_query config.kafka.password-placeholder '${QUEUE_PASSWORD}' q '.ingest.kafka.sasl_password'
    if query_value config.s3.prefix q '.storage.trace.s3.prefix'; then
      if [ -z "$VALUE" ] || [ "$VALUE" = null ]; then skip config.s3.prefix-unparsed; else [[ "$VALUE" == */traces-epoch-2 ]] && ok config.s3.prefix || bad config.s3.prefix; fi
    fi
  fi
fi

WL=''
if query_value workloads get deploy,sts -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=tempo" -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/component}{" "}{.spec.replicas}{" "}{.status.readyReplicas}{" "}{.spec.template.spec.serviceAccountName}{" "}{.spec.template.spec.containers[0].image}{"\n"}{end}'; then
  WL=$VALUE
  [ -n "$WL" ] || bad 'Tempo workloads empty'
fi
while read -r COMP WANT READY SA IMAGE; do
  [ -n "$COMP" ] || continue
  [ "${READY:-0}" = "$WANT" ] && ok "ready.$COMP=$READY/$WANT" || bad "ready.$COMP=${READY:-0}/$WANT"
  case "$COMP" in
    block-builder) [ "$SA" = platform-tempo-block-builder ] && ok "sa.block-builder=$SA" || bad "sa.block-builder=$SA" ;;
    querier | backend-scheduler) [ "$SA" = platform-tempo-querier ] && ok "sa.$COMP=$SA" || bad "sa.$COMP=$SA" ;;
    backend-worker) [ "$SA" = platform-tempo-backend-worker ] && ok "sa.backend-worker=$SA" || bad "sa.backend-worker=$SA" ;;
    distributor) [ "${IMAGE##*:}" = "$TEMPO_MANAGED_IMAGE_VERSION" ] && ok "image.distributor=${IMAGE##*:}" || bad "image.distributor=${IMAGE##*:} (want $TEMPO_MANAGED_IMAGE_VERSION)" ;;
  esac
done <<< "$WL"

for S in queue-managed-e2-writer queue-managed-e2-reader; do
  if query_value "secret.$S" get secret "$S" --ignore-not-found -o name; then
    [ -n "$VALUE" ] && ok "secret.$S" || bad "secret.$S absent"
  fi
done
equal_query envFrom.distributor 'queue-managed-e2-reader queue-managed-e2-writer ' get deploy "${RELEASE}-distributor" -o jsonpath='{range .spec.template.spec.containers[0].envFrom[*]}{.secretRef.name}{" "}{end}'
equal_query envFrom.block-builder 'queue-managed-e2-reader ' get sts "${RELEASE}-block-builder" -o jsonpath='{range .spec.template.spec.containers[0].envFrom[*]}{.secretRef.name}{" "}{end}'
if query_value args get deploy "${RELEASE}-distributor" -o jsonpath='{.spec.template.spec.containers[0].args}'; then
  [[ "$VALUE" == *'-config.expand-env=true'* ]] && ok args.expand-env || bad args.expand-env
fi
if query_value networkpolicy get networkpolicy tempo-managed-queue-egress -o jsonpath='{.spec.egress[?(@.ports[0].port==9096)].to[*].ipBlock.cidr}'; then
  BLOCKS=$(printf '%s' "$VALUE" | wc -w | tr -d ' ')
  [ "$BLOCKS" = 3 ] && ok networkpolicy.broker-subnets || bad networkpolicy.broker-subnets
fi

if STATE=$(aws kafka describe-cluster-v2 --region "$QUEUE_REGION" --cluster-arn "$QUEUE_CLUSTER_ARN" --query 'ClusterInfo.State' --output text 2> /dev/null); then
  [ "$STATE" = ACTIVE ] && ok "msk.$QUEUE_CLUSTER_NAME=ACTIVE" || bad "msk.$QUEUE_CLUSTER_NAME=$STATE"
else skip "msk state (aws kafka describe-cluster-v2 failed)"; fi
if query_value active-query get service platform-tempo-active-query -o jsonpath='{.metadata.labels.platform\.example/active-trace-backend}'; then
  printf 'INFO active-query backend=%s; compare with approved selector\n' "$VALUE"
fi

if [ "$UNKNOWN" -ne 0 ]; then echo "INCONCLUSIVE checked=$CHECKED diff=$DIFF skipped=$UNKNOWN"; exit 2; fi
if [ "$DIFF" -ne 0 ]; then echo "FAIL checked=$CHECKED diff=$DIFF"; exit 1; fi
echo "PASS checked=$CHECKED diff=0"; exit 0
