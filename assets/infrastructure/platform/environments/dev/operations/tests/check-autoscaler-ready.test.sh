#!/usr/bin/env bash
# platform/environments/dev/operations/tests/check-autoscaler-ready.test.sh — 자동 확장 준비 검사(scripts/check-autoscaler-ready.sh) 회귀 테스트 19개 (스케줄링 대기와 자동 확장 상한).
# 가짜 aws · kubectl(tests/fake)의 JSON 으로 (yq v4 · jq 필요) 드리프트 · 시작 조건 · 조회 실패를 봅니다. AWS · 클러스터 호출 없음. 계정 ID 는 공개 예시 값.
# 실행: bash platform/environments/dev/operations/tests/check-autoscaler-ready.test.sh — 마지막 "Ran 19 tests" · "OK" 가 정상.
set -euo pipefail
cd "$(dirname "$0")/.."
T_RUN=0; T_FAIL=0; T_NAME=""; T_OUT=""; T_CODE=0
T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ca-ready-test.XXXXXX")"
trap 'rm -rf "$T_TMP"' EXIT
t_begin() { T_NAME="$1"; T_RUN=$((T_RUN + 1)); T_CASE_FAILED=0; }
t_fail() { T_CASE_FAILED=1; printf 'FAIL: %s — %s\n' "$T_NAME" "$1" >&2; }
t_end() { if [ "$T_CASE_FAILED" = 1 ]; then T_FAIL=$((T_FAIL + 1)); printf '%s ... FAIL\n' "$T_NAME"; else printf '%s ... ok\n' "$T_NAME"; fi; }
t_exit() {
  expected="$1"; shift
  set +e
  T_OUT="$("$@" 2> "$T_TMP/stderr")"; T_CODE=$?
  set -e
  [ "$T_CODE" = "$expected" ] || t_fail "exit $T_CODE (expected $expected); stdout=$(printf '%s' "$T_OUT" | tail -3 | tr '\n' ' ')"
}
t_out_contains() { case "$T_OUT" in *"$1"*) ;; *) t_fail "stdout does not contain '$1'" ;; esac; }
t_summary() {
  printf -- '----------------------------------------------------------------------\nRan %d tests\n\n' "$T_RUN"
  if [ "$T_FAIL" = 0 ]; then printf 'OK\n'; exit 0; else printf 'FAILED (failures=%d)\n' "$T_FAIL"; exit 1; fi
}

# 테스트 프로세스 안에서만 실제 AWS 설정·credential 경로와 metadata 인증을 차단합니다.
FAKE_BIN_DIR="$PWD/tests/fake"
[ -x "$FAKE_BIN_DIR/aws" ] && [ -x "$FAKE_BIN_DIR/kubectl" ] || { printf '%s\n' 'TEST_ISOLATION_ERROR: executable fake aws/kubectl required' >&2; exit 2; }
export PATH="$FAKE_BIN_DIR:$PATH" KUBE_CONTEXT=fixture-dev
hash -r
[ "$(command -v aws)" = "$FAKE_BIN_DIR/aws" ] && [ "$(command -v kubectl)" = "$FAKE_BIN_DIR/kubectl" ] || { printf '%s\n' 'TEST_ISOLATION_ERROR: fake command resolution mismatch' >&2; exit 2; }
: > "$T_TMP/aws-config"
: > "$T_TMP/aws-credentials"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_WEB_IDENTITY_TOKEN_FILE AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
export AWS_CONFIG_FILE="$T_TMP/aws-config" AWS_SHARED_CREDENTIALS_FILE="$T_TMP/aws-credentials" AWS_EC2_METADATA_DISABLED=true
G=contract2whale-dev-eks-app
reset() { # 예: 정상 기준 — min 2 · max 3(승인 랩 입력) · desired 2, 노드 2대 Ready, Pending 0
  rm -rf "$T_TMP/c"; mkdir -p "$T_TMP/c"; export FAKE_DIR="$T_TMP/c" FAKE_LOG="$T_TMP/c/calls.log"; unset FAKE_FAIL 2> /dev/null || true; : > "$FAKE_LOG"
  echo 111111111111 > "$FAKE_DIR/account.txt"
  set_sizes 2 3 2 2 3 2
  printf '{"Activities":[{"StatusCode":"Successful"}]}' > "$FAKE_DIR/activities.json"
  echo 1 > "$FAKE_DIR/ca-ready.txt"
  printf 'autoscalerStatus: Running\nclusterWide:\n  health:\n    status: Healthy\n' > "$FAKE_DIR/ca-status.txt"
  nodes 2
  printf '{"items":[]}' > "$FAKE_DIR/pending.json"
  printf 'CLUSTER_NAME=contract2whale-dev-eks\nNODEGROUP=%s\nEXPECTED_ACCOUNT=111111111111\nAPPROVED_MIN=2\nAPPROVED_MAX=3\nPOD_CPU_MILLI=250\nPOD_MEMORY_MI=64\n' "$G" > "$FAKE_DIR/approved.env"
}
set_sizes() { # 예: set_sizes <eks min> <eks max> <eks desired> <asg min> <asg max> <asg desired>
  printf '{"nodegroup":{"status":"%s","scalingConfig":{"minSize":%s,"maxSize":%s,"desiredSize":%s},"resources":{"autoScalingGroups":[{"name":"eks-app-asg"}]}}}' "${NG_STATUS:-ACTIVE}" "$1" "$2" "$3" > "$FAKE_DIR/nodegroup.json"
  printf '{"AutoScalingGroups":[{"MinSize":%s,"MaxSize":%s,"DesiredCapacity":%s,"Tags":[{"Key":"k8s.io/cluster-autoscaler/enabled","Value":"true"},{"Key":"k8s.io/cluster-autoscaler/contract2whale-dev-eks","Value":"owned"}]}]}' "$4" "$5" "$6" > "$FAKE_DIR/asg.json"
}
nodes() { # 예: nodes <Ready 노드 수> — allocatable 1930m · 7068548Ki
  local i items=""
  for i in $(seq 1 "$1"); do items="$items${items:+,}{\"status\":{\"allocatable\":{\"cpu\":\"1930m\",\"memory\":\"7068548Ki\"},\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"; done
  printf '{"items":[%s]}' "$items" > "$FAKE_DIR/nodes.json"
}
check() { t_exit "$1" bash scripts/check-autoscaler-ready.sh --approved "$FAKE_DIR/approved.env" --mode "$2"; }

t_begin "test_ready_in_drift_mode"
reset; check 0 drift; t_out_contains 'AUTOSCALER_READY mode=drift'; t_out_contains 'max=3 (approved 3)'; t_end

t_begin "test_ready_in_start_mode"
reset; check 0 start; t_out_contains 'AUTOSCALER_READY mode=start'; t_out_contains 'headroom max-desired=1'; t_out_contains 'fits node allocatable'; t_end

t_begin "test_max_lowered_at_runtime_is_drift"
reset; set_sizes 2 2 2 2 2 2; check 1 drift; t_out_contains 'DRIFT      max=2 but approved 3'; t_out_contains 'AUTOSCALER_NOT_READY'; t_end

t_begin "test_min_drift_is_reported"
reset; set_sizes 1 3 2 1 3 2; check 1 drift; t_out_contains 'DRIFT      min=1 but approved 2'; t_end

t_begin "test_desired_at_max_is_not_drift_but_blocks_a_drill_start"
reset; set_sizes 2 3 3 2 3 3; nodes 3; check 0 drift
check 1 start; t_out_contains 'desired=3 is not the approved min 2'; t_out_contains 'no headroom: max=3 desired=3'; t_end

t_begin "test_asg_not_yet_propagated"
reset; set_sizes 2 3 2 2 4 2; check 1 drift; t_out_contains 'differs from EKS 2/3/2'; t_end

t_begin "test_missing_discovery_tag"
reset; sed -i.bak 's/"Value":"owned"/"Value":"shared"/' "$FAKE_DIR/asg.json"; check 1 drift; t_out_contains 'tag k8s.io/cluster-autoscaler/contract2whale-dev-eks=owned missing'; t_end

t_begin "test_autoscaler_not_ready_or_unhealthy"
reset; echo 0 > "$FAKE_DIR/ca-ready.txt"; check 1 drift; t_out_contains 'cluster-autoscaler ready=0'
reset; printf 'clusterWide:\n  health:\n    status: Unhealthy\nnodeGroups:\n  - name: x\n    health:\n      status: Healthy\n' > "$FAKE_DIR/ca-status.txt"; check 1 drift; t_out_contains 'clusterWide=Unhealthy'
reset; : > "$FAKE_DIR/ca-status.txt"; check 2 drift; t_out_contains 'ca-status-parse-failed'; t_end

t_begin "test_nodegroup_updating"
reset; export NG_STATUS=UPDATING; set_sizes 2 3 2 2 3 2; unset NG_STATUS; check 1 drift; t_out_contains 'status=UPDATING'; t_end

t_begin "test_existing_pending_pods_block_start"
reset; printf '{"items":[{"status":{"conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable"}]}}]}' > "$FAKE_DIR/pending.json"
check 0 drift; check 1 start; t_out_contains 'unschedulable pending pods=1'; t_end

t_begin "test_activity_in_progress_or_node_not_ready_blocks_start"
reset; printf '{"Activities":[{"StatusCode":"InProgress"}]}' > "$FAKE_DIR/activities.json"; check 1 start; t_out_contains '1 scaling activities in progress'
reset; nodes 1; check 1 start; t_out_contains 'ready nodes=1 but desired=2'; t_end

t_begin "test_pod_too_large_for_a_node"
reset; sed -i.bak 's/POD_CPU_MILLI=250/POD_CPU_MILLI=2500/' "$FAKE_DIR/approved.env"; check 1 start; t_out_contains 'does not fit node allocatable'; t_end

t_begin "test_wrong_account_or_lookup_failure_is_unknown"
reset; echo 222222222222 > "$FAKE_DIR/account.txt"; check 2 drift; t_out_contains 'account-mismatch:222222222222'
reset; export FAKE_FAIL=nodegroup; check 2 drift; t_out_contains 'describe-nodegroup-failed'
reset; export FAKE_FAIL=api; check 2 drift; t_out_contains 'cluster-api-unreachable'; t_end

t_begin "test_incomplete_approved_input_is_unknown"
reset; sed -i.bak '/APPROVED_MAX/d' "$FAKE_DIR/approved.env"; check 2 drift; t_out_contains 'approved-input-incomplete'
grep -q 'aws ' "$FAKE_LOG" && t_fail "AWS was called before the input was validated"; t_end

t_begin "test_missing_value_or_context_is_unknown"
reset; t_exit 2 bash scripts/check-autoscaler-ready.sh --approved "$FAKE_DIR/approved.env" --mode; t_out_contains 'missing-value:--mode'
reset; t_exit 2 env -u KUBE_CONTEXT bash scripts/check-autoscaler-ready.sh --approved "$FAKE_DIR/approved.env"; t_out_contains 'kube-context-missing'
grep -q 'aws ' "$FAKE_LOG" && t_fail "AWS was called before the arguments were validated"; t_end

t_begin "test_status_lookup_and_yaml_parse_failure_are_unknown"
reset; export FAKE_FAIL=ca-status; check 2 drift; t_out_contains 'ca-status-lookup-failed'
reset; printf 'clusterWide: [' > "$FAKE_DIR/ca-status.txt"; check 2 drift; t_out_contains 'ca-status-parse-failed'; t_end

t_begin "test_malformed_existing_json_responses_are_unknown"
reset; printf '{' > "$FAKE_DIR/nodegroup.json"; check 2 drift; t_out_contains 'nodegroup-status-parse-failed'
reset; printf '{' > "$FAKE_DIR/asg.json"; check 2 drift; t_out_contains 'asg-response-parse-failed'
reset; printf '{' > "$FAKE_DIR/activities.json"; check 2 start; t_out_contains 'activities-parse-failed'
reset; printf '{' > "$FAKE_DIR/nodes.json"; check 2 start; t_out_contains 'nodes-parse-failed'
reset; printf '{' > "$FAKE_DIR/pending.json"; check 2 start; t_out_contains 'pods-lookup-failed'; t_end

t_begin "test_zero_asg_candidates_is_unknown"
reset; jq '.nodegroup.resources.autoScalingGroups = []' "$FAKE_DIR/nodegroup.json" > "$FAKE_DIR/nodegroup-next.json"; mv "$FAKE_DIR/nodegroup-next.json" "$FAKE_DIR/nodegroup.json"
check 2 drift; t_out_contains 'nodegroup-asg-count-must-be-one:0'
grep -q 'aws .*autoscaling ' "$FAKE_LOG" && t_fail "autoscaling API was called with zero ASG candidates"; t_end

t_begin "test_multiple_asg_candidates_is_unknown"
reset; jq '.nodegroup.resources.autoScalingGroups = [{"name":"eks-app-asg"},{"name":"eks-other-asg"}]' "$FAKE_DIR/nodegroup.json" > "$FAKE_DIR/nodegroup-next.json"; mv "$FAKE_DIR/nodegroup-next.json" "$FAKE_DIR/nodegroup.json"
check 2 start; t_out_contains 'nodegroup-asg-count-must-be-one:2'
grep -q 'aws .*autoscaling ' "$FAKE_LOG" && t_fail "autoscaling API was called with multiple ASG candidates"; t_end

t_summary
