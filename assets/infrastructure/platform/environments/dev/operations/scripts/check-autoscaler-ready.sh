#!/usr/bin/env bash
# platform/environments/dev/operations/scripts/check-autoscaler-ready.sh
# 스케줄링 대기와 자동 확장 상한: 관리형 노드 그룹의 실제 크기 설정이 승인한 입력과 같은지(드리프트), Cluster Autoscaler 가 그 그룹을 늘릴 수 있는 상태인지 봅니다.
# 누군가의 수동 변경을 막는 권한 제어가 아니라, 수요를 만들기 전 · 배포 전에 드리프트를 먼저 찾는 읽기 전용 검사입니다. 쓰기 호출은 없습니다.
#   --mode drift (기본)  계정 · context · 그룹 ACTIVE · EKS 와 ASG 의 min/max/desired 일치 · 탐색 태그 2개 · CA Ready · 승인 min/max 와 실제 값 대조
#   --mode start         위 항목 + 드릴 시작 조건(desired = 승인 min, max ≥ desired + 1, 진행 중인 ASG 활동 없음, Ready 노드 수 = desired,
#                        Unschedulable Pending 0, 실험 Pod 하나의 requests 가 그룹 노드의 allocatable 안)
# desired = max 는 확장이 끝난 탄력 그룹의 정상 상태일 수 있어 drift 모드에서는 결함으로 세지 않습니다.
# 승인 입력(--approved): CLUSTER_NAME NODEGROUP EXPECTED_ACCOUNT APPROVED_MIN APPROVED_MAX [POD_CPU_MILLI POD_MEMORY_MI] 를 KEY=VALUE 로 적은 파일 (비밀 없음)
# 사용: KUBE_CONTEXT=<context> bash scripts/check-autoscaler-ready.sh --approved <file> [--mode drift|start]   (필요 도구: aws · kubectl · jq · yq v4)
# 출력: OK · DRIFT · NOT_READY 줄들 + AUTOSCALER_READY / AUTOSCALER_NOT_READY / AUTOSCALER_UNKNOWN 한 줄
# 종료: 0 READY · 1 NOT_READY(드리프트 포함) · 2 UNKNOWN(조회 실패 · 다른 계정 · 인자)
set -uo pipefail

APPROVED="" MODE=drift
while [ $# -gt 0 ]; do
  case "$1" in
    --approved) [ $# -ge 2 ] || { echo "AUTOSCALER_UNKNOWN reason=missing-value:$1"; exit 2; }; APPROVED="$2"; shift 2 ;;
    --mode) [ $# -ge 2 ] || { echo "AUTOSCALER_UNKNOWN reason=missing-value:$1"; exit 2; }; MODE="$2"; shift 2 ;;
    *) echo "AUTOSCALER_UNKNOWN reason=unknown-argument:$1"; exit 2 ;;
  esac
done
unknown() { echo "AUTOSCALER_UNKNOWN reason=$1"; exit 2; }
case "$MODE" in drift | start) ;; *) unknown "mode-must-be-drift-or-start" ;; esac
[ -n "${KUBE_CONTEXT:-}" ] || unknown "kube-context-missing" # 예: 대상 context 를 꼭 지정 (현재 context 로 넘어가지 않음)
[ -f "$APPROVED" ] || unknown "approved-input-missing"
val() { awk -F= -v k="$1" '$1 == k { v = substr($0, index($0, "=") + 1); sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }' "$APPROVED"; }
is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; }
CLUSTER="$(val CLUSTER_NAME)" NG="$(val NODEGROUP)" ACCOUNT="$(val EXPECTED_ACCOUNT)" AMIN="$(val APPROVED_MIN)" AMAX="$(val APPROVED_MAX)"
[ -n "$CLUSTER" ] && [ -n "$NG" ] && is_uint "$ACCOUNT" && is_uint "$AMIN" && is_uint "$AMAX" || unknown "approved-input-incomplete"
[ "$AMIN" -le "$AMAX" ] || unknown "approved-min-above-max"
K=(kubectl --context "$KUBE_CONTEXT")
PROBLEMS=0
ok() { printf 'OK         %s\n' "$*"; }
drift() { printf 'DRIFT      %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
notready() { printf 'NOT_READY  %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }

# 1. 대상: 계정 · 클러스터 API
actual_account="$(aws sts get-caller-identity --query Account --output text 2> /dev/null)" || unknown "sts-failed"
[ "$actual_account" = "$ACCOUNT" ] || unknown "account-mismatch:$actual_account"
ok "account=$actual_account"
"${K[@]}" get --raw=/readyz > /dev/null 2>&1 || unknown "cluster-api-unreachable:$KUBE_CONTEXT"
ok "context=$KUBE_CONTEXT"

# 2. EKS 관리형 노드 그룹과 그 ASG
ng_json="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" --output json 2> /dev/null)" || unknown "describe-nodegroup-failed:$NG"
status="$(printf '%s' "$ng_json" | jq -er '.nodegroup.status | select(type == "string" and length > 0)')" || unknown "nodegroup-status-parse-failed"
min="$(printf '%s' "$ng_json" | jq -er '.nodegroup.scalingConfig.minSize | select(type == "number")')" || unknown "nodegroup-min-parse-failed"
max="$(printf '%s' "$ng_json" | jq -er '.nodegroup.scalingConfig.maxSize | select(type == "number")')" || unknown "nodegroup-max-parse-failed"
desired="$(printf '%s' "$ng_json" | jq -er '.nodegroup.scalingConfig.desiredSize | select(type == "number")')" || unknown "nodegroup-desired-parse-failed"
asg_count="$(printf '%s' "$ng_json" | jq -er '.nodegroup.resources.autoScalingGroups | select(type == "array") | length')" || unknown "nodegroup-asg-count-parse-failed"
[ "$asg_count" = 1 ] || unknown "nodegroup-asg-count-must-be-one:$asg_count"
asg="$(printf '%s' "$ng_json" | jq -er '.nodegroup.resources.autoScalingGroups[0].name | select(type == "string" and length > 0)')" || unknown "nodegroup-asg-parse-failed"
is_uint "$min" && is_uint "$max" && is_uint "$desired" && [ -n "$asg" ] || unknown "nodegroup-fields-missing"
[ "$status" = ACTIVE ] && ok "nodegroup=$NG status=ACTIVE" || notready "nodegroup=$NG status=$status (update or repair in progress)"
asg_json="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" --output json 2> /dev/null)" || unknown "describe-asg-failed:$asg"
asg_count="$(printf '%s' "$asg_json" | jq -er '.AutoScalingGroups | select(type == "array") | length')" || unknown "asg-response-parse-failed"
[ "$asg_count" = 1 ] || unknown "asg-not-found:$asg"
amin="$(printf '%s' "$asg_json" | jq -er '.AutoScalingGroups[0].MinSize | select(type == "number")')" || unknown "asg-amin-parse-failed"
amax="$(printf '%s' "$asg_json" | jq -er '.AutoScalingGroups[0].MaxSize | select(type == "number")')" || unknown "asg-amax-parse-failed"
adesired="$(printf '%s' "$asg_json" | jq -er '.AutoScalingGroups[0].DesiredCapacity | select(type == "number")')" || unknown "asg-adesired-parse-failed"
[ "$amin/$amax/$adesired" = "$min/$max/$desired" ] && ok "asg=$asg min/max/desired=$min/$max/$desired (same as EKS)" || notready "asg=$asg min/max/desired=$amin/$amax/$adesired differs from EKS $min/$max/$desired (change still propagating)"
for tag in "k8s.io/cluster-autoscaler/enabled=true" "k8s.io/cluster-autoscaler/$CLUSTER=owned"; do
  observed_tag="$(printf '%s' "$asg_json" | jq -r --arg k "${tag%%=*}" '.AutoScalingGroups[0].Tags | select(type == "array") | .[] | select(.Key == $k) | .Value')" || unknown "asg-tags-parse-failed"
  if [ "$observed_tag" = "${tag#*=}" ]; then ok "tag $tag"; else notready "tag $tag missing (Cluster Autoscaler cannot discover this group)"; fi
done

# 3. 승인 입력과 실제 값 (드리프트)
[ "$min" = "$AMIN" ] && ok "min=$min (approved $AMIN)" || drift "min=$min but approved $AMIN"
[ "$max" = "$AMAX" ] && ok "max=$max (approved $AMAX)" || drift "max=$max but approved $AMAX (Cluster Autoscaler never scales above max)"

# 4. Cluster Autoscaler
ready="$("${K[@]}" -n kube-system get deployment cluster-autoscaler -o jsonpath='{.status.readyReplicas}' 2> /dev/null)" || unknown "ca-deployment-lookup-failed"
is_uint "$ready" && [ "$ready" -ge 1 ] && ok "cluster-autoscaler ready=$ready" || notready "cluster-autoscaler ready=${ready:-0}"
ca_status="$("${K[@]}" -n kube-system get configmap cluster-autoscaler-status -o jsonpath='{.data.status}' 2> /dev/null)" || unknown "ca-status-lookup-failed"
ca_health="$(printf '%s' "$ca_status" | yq -er '.clusterWide.health.status | select(tag == "!!str" and length > 0)' 2> /dev/null)" || unknown "ca-status-parse-failed"
[ "$ca_health" = Healthy ] && ok "cluster-autoscaler-status clusterWide=Healthy" || notready "cluster-autoscaler-status clusterWide=${ca_health:-missing}"

# 5. 드릴 시작 조건 (start 모드만)
if [ "$MODE" = start ]; then
  [ "$desired" = "$AMIN" ] && ok "desired=$desired equals approved min" || notready "desired=$desired is not the approved min $AMIN (scale-in not finished)"
  [ "$max" -ge $((desired + 1)) ] && ok "headroom max-desired=$((max - desired))" || notready "no headroom: max=$max desired=$desired"
  act="$(aws autoscaling describe-scaling-activities --auto-scaling-group-name "$asg" --max-items 10 --output json 2> /dev/null)" || unknown "describe-activities-failed"
  busy="$(printf '%s' "$act" | jq '[.Activities[] | select(.StatusCode != "Successful" and .StatusCode != "Failed" and .StatusCode != "Cancelled")] | length')" || unknown "activities-parse-failed"
  [ "$busy" = 0 ] && ok "no scaling activity in progress" || notready "$busy scaling activities in progress"
  nodes_json="$("${K[@]}" get nodes -l "eks.amazonaws.com/nodegroup=$NG" -o json 2> /dev/null)" || unknown "nodes-lookup-failed"
  rn="$(printf '%s' "$nodes_json" | jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')" || unknown "nodes-parse-failed"
  [ "$rn" = "$desired" ] && ok "ready nodes=$rn" || notready "ready nodes=$rn but desired=$desired"
  pend="$("${K[@]}" get pods -A --field-selector=status.phase=Pending -o json 2> /dev/null | jq '[.items[] | select(any(.status.conditions[]?; .type == "PodScheduled" and .status == "False" and .reason == "Unschedulable"))] | length')" || unknown "pods-lookup-failed"
  [ "$pend" = 0 ] && ok "unschedulable pending pods=0" || notready "unschedulable pending pods=$pend (find their cause before adding demand)"
  cpu="$(val POD_CPU_MILLI)" mem="$(val POD_MEMORY_MI)"
  if is_uint "$cpu" && is_uint "$mem"; then
    fit="$(printf '%s' "$nodes_json" | jq --argjson c "$cpu" --argjson m "$mem" '
      def milli: if test("m$") then (.[:-1] | tonumber) else (tonumber * 1000) end;
      def mi: if test("Ki$") then (.[:-2] | tonumber / 1024) elif test("Mi$") then (.[:-2] | tonumber) elif test("Gi$") then (.[:-2] | tonumber * 1024) else (tonumber / 1048576) end;
      [.items[] | (.status.allocatable.cpu | milli) >= $c and (.status.allocatable.memory | mi) >= $m] | all')" || unknown "node-allocatable-parse-failed"
    [ "$fit" = true ] && ok "one experiment Pod (cpu ${cpu}m, memory ${mem}Mi) fits node allocatable" || notready "one experiment Pod (cpu ${cpu}m, memory ${mem}Mi) does not fit node allocatable"
  else
    unknown "pod-requests-missing-in-approved-input"
  fi
fi

if [ "$PROBLEMS" -eq 0 ]; then echo "AUTOSCALER_READY mode=$MODE nodegroup=$NG min/max/desired=$min/$max/$desired"; exit 0; fi
echo "AUTOSCALER_NOT_READY mode=$MODE nodegroup=$NG problems=$PROBLEMS"; exit 1
