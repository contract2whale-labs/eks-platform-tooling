#!/usr/bin/env bash
# platform/environments/dev/queue/scripts/check-managed-queue-compat.sh
# 호환성 확인과 네트워크 준비: 관리형 큐로 옮기기 전의 호환성 · 네트워크 확인 도구입니다 (원본 check-managed-queue-compat.py 의 셸 버전). 조회만 하며 자원을 만들지 않습니다.
# 확인 항목: 고를 수 있는 브로커 버전(3.9 · 4.0 계열) · 자체 구축 버전 · 인증 방식 · 네트워크 계약 네 값 · Security Group 규칙 양방향 · 브로커 서브넷의 AZ · 여유 주소 · 인터넷 경로 없음 · 클러스터 이름 여유.
# 판정 PASS / FAIL / INCONCLUSIVE = 종료 0 / 1 / 2. 마지막 줄: "PASS checked=<n> diff=0". 값을 적지 않는 항목(버전 목록 · 파티션 한도 · 계정 한도)은 조회 결과를 그대로 보여 줍니다.
# 사용: KUBE_CONTEXT=<context> INFRA_ROOT=<저장소> scripts/check-managed-queue-compat.sh
set -uo pipefail
: "${KUBE_CONTEXT:?Set the intended EKS context}"      # 예: contract2whale-dev-eks
: "${INFRA_ROOT:?Set INFRA_ROOT (cloud-platform-infrastructure)}"
: "${EXPECTED_ACCOUNT_ID:?Set the approved Dev account ID}" # 예: 111111111111
REGION="${AWS_REGION:-ap-northeast-2}"
NETWORK_DIR="$INFRA_ROOT/terraform/environments/dev/network/vpc" # 예: kafka_network_contract 를 내는 루트 모듈 (관리형 메시지 큐의 네트워크 경계)
QUEUE_NS="${QUEUE_NAMESPACE:-messaging}" QUEUE_CLUSTER="${QUEUE_CLUSTER:-platform-queue}"
MANAGED_NAME="${MANAGED_QUEUE_NAME:-cp-dev-traces-queue}"          # 예: cp-dev-traces-queue (modules/queue-managed 의 cluster_name)
CHECKED=0 DIFF=0 UNKNOWN=0
ok()   { CHECKED=$((CHECKED + 1)); printf 'OK    %s\n' "$*"; }
bad()  { CHECKED=$((CHECKED + 1)); DIFF=$((DIFF + 1)); printf 'DIFF  %s\n' "$*"; }
skip() { UNKNOWN=$((UNKNOWN + 1)); printf 'SKIP  %s\n' "$*"; }
query_value() {
  local DESTINATION="$1" DETAIL="$2" VALUE
  shift 2
  if ! VALUE=$("$@"); then skip "$DETAIL query failed"; return 1; fi
  printf -v "$DESTINATION" '%s' "$VALUE"
}
equal_query() {
  local DETAIL="$1" EXPECTED="$2" ACTUAL
  shift 2
  if query_value ACTUAL "$DETAIL" "$@"; then
    [ "$ACTUAL" = "$EXPECTED" ] && ok "$DETAIL=$ACTUAL" || bad "$DETAIL=$ACTUAL expected=$EXPECTED"
  fi
}
for tool in aws kubectl terraform yq; do command -v "$tool" > /dev/null || { echo "INCONCLUSIVE $tool-missing"; exit 2; }; done

# 조회를 시작하기 전에 승인 계정과 실제 호출 신원을 비교합니다.
if ! CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text); then
  echo "INCONCLUSIVE caller-identity-query-failed"; exit 2
fi
if [ "$CALLER_ACCOUNT" != "$EXPECTED_ACCOUNT_ID" ]; then
  echo "FAIL caller-account-mismatch"; exit 1
fi

# 1. 이 리전에서 고를 수 있는 브로커 버전 (값은 검증 불가 — 목록을 보여 주고 3.9 · 4.0 계열이 하나라도 있는지만 봅니다).
if VERSIONS=$(aws kafka list-kafka-versions --region "$REGION" --query 'KafkaVersions[?Status==`ACTIVE`].Version' --output text); then
  PICK=$(printf '%s\n' "$VERSIONS" | tr '\t' '\n' | grep -E '^(3\.9|4\.0)\.' | sort | tr '\n' ' ')
  [ -n "$PICK" ] && ok "managed.versions.pinned_series_available: $PICK" || bad "managed.versions: no 3.9 or 4.0 series in [$VERSIONS]"
else skip "managed.versions (aws kafka list-kafka-versions failed)"; fi

# 2. 자체 구축 버전과 별도 SCRAM 리스너 준비를 조회합니다. 실제 Tempo/MSK 연결은 후속 smoke가 확인합니다.
K=(kubectl --context "$KUBE_CONTEXT" -n "$QUEUE_NS")
if SELF_VERSION=$("${K[@]}" get kafka "$QUEUE_CLUSTER" -o jsonpath='{.spec.kafka.version}') && [ -n "$SELF_VERSION" ]; then
  ok "self-managed.version=$SELF_VERSION"
  equal_query self-managed.tls_listener.auth scram-sha-512 "${K[@]}" get kafka "$QUEUE_CLUSTER" -o jsonpath='{.spec.kafka.listeners[?(@.name=="tls")].authentication.type}'
  equal_query self-managed.users 'tempo-distributor=True tempo-consumer=True ' "${K[@]}" get kafkauser tempo-distributor tempo-consumer -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status} {end}'
else skip "self-managed.kafka $QUEUE_CLUSTER not found in $QUEUE_NS"; fi

# 3. 네트워크 계약 네 값 (관리형 메시지 큐의 네트워크 경계 출력).
if CONTRACT=$(terraform -chdir="$NETWORK_DIR" output -json kafka_network_contract) && [ -n "$CONTRACT" ]; then
  # 파싱 실패에서 부분 값이나 이전 값을 사용해 EC2를 호출하지 않습니다.
  if ! PORT=$(printf '%s' "$CONTRACT" | yq -er '.broker_port') ||
     ! BROKER_SG=$(printf '%s' "$CONTRACT" | yq -er '.broker_security_group_id') ||
     ! CLIENT_SG=$(printf '%s' "$CONTRACT" | yq -er '.client_security_group_id') ||
     ! AZ_COUNT=$(printf '%s' "$CONTRACT" | yq -er '.broker_subnet_ids_by_az | length') ||
     ! SUBNETS=$(printf '%s' "$CONTRACT" | yq -er '.broker_subnet_ids_by_az | to_entries | sort_by(.key) | .[].value' | tr '\n' ' '); then
    skip 'contract parsing failed'
  elif [[ ! "$BROKER_SG" =~ ^sg-[0-9a-f]+$ || ! "$CLIENT_SG" =~ ^sg-[0-9a-f]+$ ]] || [ "$AZ_COUNT" != 3 ] || [ "$PORT" != 9096 ]; then
    bad 'contract invalid broker/client SG, AZ count or port; EC2 checks not run'
  else
  SUBNET_IDS_VALID=true
  for SID in $SUBNETS; do [[ "$SID" =~ ^subnet-[0-9a-f]+$ ]] || SUBNET_IDS_VALID=false; done
  if [ "$SUBNET_IDS_VALID" != true ] || [ -z "$SUBNETS" ]; then
    bad 'contract subnet IDs invalid; EC2 checks not run'
  else
  [ "$PORT" = 9096 ] && ok "contract.broker_port=9096" || bad "contract.broker_port=$PORT"
  [ "$AZ_COUNT" = 3 ] && ok "contract.broker_subnets=3" || bad "contract.broker_subnets=$AZ_COUNT"
  [[ "$BROKER_SG" =~ ^sg-[0-9a-f]+$ ]] && ok "contract.broker_security_group_id=$BROKER_SG" || bad "contract.broker_security_group_id=$BROKER_SG"
  [[ "$CLIENT_SG" =~ ^sg-[0-9a-f]+$ ]] && ok "contract.client_security_group_id=$CLIENT_SG" || bad "contract.client_security_group_id=$CLIENT_SG"
  # 4. Security Group 규칙 양방향 (출발지 · 목적지가 CIDR 이 아니라 Security Group 참조).
  equal_query sg.broker.ingress_9096_from_client_sg 1 aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$BROKER_SG" \
    --query "SecurityGroupRules[?IsEgress==\`false\` && IpProtocol=='tcp' && FromPort==\`9096\` && ToPort==\`9096\` && ReferencedGroupInfo.GroupId=='${CLIENT_SG}'] | length(@)" --output text
  equal_query sg.client.egress_9096_to_broker_sg 1 aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$CLIENT_SG" \
    --query "SecurityGroupRules[?IsEgress==\`true\` && IpProtocol=='tcp' && FromPort==\`9096\` && ToPort==\`9096\` && ReferencedGroupInfo.GroupId=='${BROKER_SG}'] | length(@)" --output text
  equal_query sg.broker.cidr_rules 0 aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$BROKER_SG" \
    --query 'SecurityGroupRules[?CidrIpv4!=`null` || CidrIpv6!=`null`] | length(@)' --output text
  # shellcheck disable=SC2086
  if SUB=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids $SUBNETS --query 'Subnets[].[AvailabilityZone,AvailableIpAddressCount,SubnetId]' --output text); then
    AZS=$(printf '%s\n' "$SUB" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
    [ "$AZS" = 3 ] && ok "subnets.distinct_az=3" || bad "subnets.distinct_az=$AZS"
    MINFREE=$(printf '%s\n' "$SUB" | awk 'NR==1||$2<m{m=$2} END{print m+0}')
    [ "$MINFREE" -ge 3 ] && ok "subnets.min_free_addresses=$MINFREE" || bad "subnets.min_free_addresses=$MINFREE (want >= 3: broker ENI per subnet + 여유)"
    # shellcheck disable=SC2086
    SUBNET_CSV=$(printf '%s,' $SUBNETS | sed 's/,$//') # 예: subnet-0a…,subnet-0b…,subnet-0c… (필터 값은 쉼표로 구분하고 값끼리는 OR)
    # 명시 연결이 있는 서브넷 수부터 셉니다. 암시적 main 연결은 이 필터가 돌려주지 않으므로, 셋 다 잡히지 않으면 기본 경로 판정을 하지 않습니다.
    if RT_SUBNETS=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=association.subnet-id,Values=$SUBNET_CSV" \
      --query 'RouteTables[].Associations[].SubnetId' --output text); then
      COVERED=0
      # shellcheck disable=SC2086
      for SID in $SUBNETS; do printf '%s\n' $RT_SUBNETS | grep -qx "$SID" && COVERED=$((COVERED + 1)); done
      if [ "$COVERED" != "$AZ_COUNT" ]; then
        skip "subnets.default_route unverified (explicit route table for $COVERED of $AZ_COUNT subnets; inspect VPC main association)"
      else
        equal_query subnets.default_routes_ipv4_ipv6 0 aws ec2 describe-route-tables --region "$REGION" --filters "Name=association.subnet-id,Values=$SUBNET_CSV" \
          --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0` || DestinationIpv6CidrBlock==`::/0`] | [] | length(@)' --output text
      fi
    else skip "subnets.default_route query failed"; fi
  else skip "subnets (aws ec2 describe-subnets failed)"; fi
  fi # valid subnet IDs
  fi # validated parsed contract
else skip "contract (terraform output kafka_network_contract failed in $NETWORK_DIR — apply 관리형 메시지 큐의 네트워크 경계 first)"; fi

# 6. 동명 자원은 ACTIVE만으로 인수하지 않습니다. queue State의 ARN과 같아야 합니다.
if CLUSTERS=$(aws kafka list-clusters-v2 --region "$REGION" --cluster-name-filter "$MANAGED_NAME" \
  --query "ClusterInfoList[?ClusterName=='${MANAGED_NAME}'].[ClusterArn,State]" --output text); then
  if [ -z "$CLUSTERS" ]; then
    ok "managed.cluster_name_absent ($MANAGED_NAME)"
  elif [ "$(printf '%s\n' "$CLUSTERS" | grep -c .)" != 1 ]; then
    bad "managed.cluster_name has multiple matches ($MANAGED_NAME)"
  else
    read -r LIVE_ARN LIVE_STATE <<< "$CLUSTERS"
    if [[ ! "$LIVE_ARN" == "arn:aws:kafka:$REGION:$EXPECTED_ACCOUNT_ID:cluster/$MANAGED_NAME/"* ]] || [ -z "$LIVE_STATE" ]; then
      skip 'managed.cluster identity response unavailable or unexpected'
    elif ! OWNED_ARN=$(terraform -chdir="$INFRA_ROOT/terraform/environments/dev/platform/queue" output -raw cluster_arn); then
      skip 'managed.cluster exists but queue State ownership could not be verified; no adoption'
    elif [ "$OWNED_ARN" != "$LIVE_ARN" ]; then
      bad 'managed.cluster ARN differs from queue State; no adoption'
    elif [ "$LIVE_STATE" != ACTIVE ]; then
      bad "managed.owned_cluster state=$LIVE_STATE expected=ACTIVE"
    else
      ok 'managed.cluster ACTIVE and ARN matches queue State (read-only verification)'
    fi
  fi
else skip 'managed.clusters query failed'; fi
if query_value TOTAL managed.cluster_count aws kafka list-clusters-v2 --region "$REGION" --query 'length(ClusterInfoList)' --output text; then
  printf 'INFO  managed.clusters_in_account=%s (quota는 별도 조회)\n' "$TOTAL"
fi

if [ "$DIFF" -ne 0 ]; then echo "FAIL checked=$CHECKED diff=$DIFF"; exit 1; fi
if [ "$UNKNOWN" -ne 0 ]; then echo "INCONCLUSIVE checked=$CHECKED diff=0 skipped=$UNKNOWN"; exit 2; fi
echo "PASS checked=$CHECKED diff=0"; exit 0
