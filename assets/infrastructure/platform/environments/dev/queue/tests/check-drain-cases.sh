#!/usr/bin/env bash
# platform/environments/dev/queue/tests/check-drain-cases.sh
# 스크립트를 임시 디렉터리에 복사해 돌리므로 기록(local-inputs/drain-*.tsv)은 저장소에 남지 않습니다.
# 사용: bash tests/check-drain-cases.sh   → "check-drain-cases: <n> OK, 0 FAIL"
set +x
set -uo pipefail
umask 077
QUEUE_TEST_REAL_PYTHON=$(command -v python3) || exit 1
[[ "$QUEUE_TEST_REAL_PYTHON" = /* ]] && [ -x "$QUEUE_TEST_REAL_PYTHON" ] || { echo 'Original Python must be an absolute executable path' >&2; exit 1; }
export QUEUE_TEST_REAL_PYTHON
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; QUEUE="$REPO/platform/environments/dev/queue"
mkdir -p "$TMP/bin" "$QUEUE" "$REPO/automation" "$REPO/terraform/environments/dev/platform/queue" || exit 1
cp -R "$ROOT/scripts" "$QUEUE/" || exit 1
cp "$ROOT/../../../../automation/read_platform_contract.py" "$REPO/automation/" || exit 1
cat > "$TMP/bin/python3" <<'FAKEPY' || exit 1
#!/usr/bin/env bash
case "$*" in
  '-c import uuid; print(uuid.uuid4())'|*/automation/read_platform_contract.py' --component queue --environment dev --expect-account 111111111111') ;;
  *) echo python3 >> "${DRAIN_FAKE_UNKNOWN:?}"; exit 97 ;;
esac
exec "${QUEUE_TEST_REAL_PYTHON:?Set the original Python path}" "$@"
FAKEPY
cat > "$TMP/bin/aws" <<'FAKEAWS' || exit 1
#!/usr/bin/env bash
case "$*" in
  'sts get-caller-identity') printf '{"Account":"111111111111"}\n' ;;
  'sts get-caller-identity --query Account --output text') echo 111111111111 ;;
  'eks describe-cluster --region ap-northeast-2 --name fixture --query cluster.endpoint --output text') echo https://fixture ;;
  *) echo aws >> "${DRAIN_FAKE_UNKNOWN:?}"; exit 97 ;;
esac
FAKEAWS
cat > "$TMP/bin/terraform" <<'FAKETF' || exit 1
#!/usr/bin/env bash
[[ "$*" = -chdir=*/terraform/environments/dev/platform/queue\ output\ -json ]] || { echo terraform >> "${DRAIN_FAKE_UNKNOWN:?}"; exit 97; }
printf '%s\n' '{"queue_managed_contract":{"sensitive":false,"value":{"cluster_arn":"arn:aws:kafka:ap-northeast-2:111111111111:cluster/fixture/id","cluster_name":"fixture","bootstrap_brokers_scram":"fixture:9096","kms_key_arn":"arn:aws:kms:ap-northeast-2:111111111111:key/fixture","topic_name":"dev-tempo-traces-epoch-2","partitions":3}}}'
FAKETF
chmod 0755 "$TMP/bin/python3" "$TMP/bin/aws" "$TMP/bin/terraform" || exit 1
# 가짜 kubectl: 브로커 Pod 이름 · 운영자 Pod 상태 · Secret 값 · exec 두 종류(kafka-get-offsets.sh · kafka-consumer-groups.sh)만 흉내 냅니다.
cat > "$TMP/bin/kubectl" <<'FAKE' || exit 1
#!/usr/bin/env bash
ARGS=" $* "
case "$ARGS" in
  ' config view --context fake --minify -o jsonpath={.clusters[0].cluster.server} ') echo https://fixture ;;
  *' -n messaging get pods -l strimzi.io/cluster=platform-queue,strimzi.io/pool-name=broker-2a -o jsonpath={.items[0].metadata.name} '*) echo platform-queue-broker-2a-3 ;;
  *' get pod queue-admin -o jsonpath={.metadata.uid} '*|*' get pod platform-queue-broker-2a-3 -o jsonpath={.metadata.uid} '*)
    [ "${DRAIN_FAKE_MODE:-}" != uid-error ] || exit 7
    echo fixture-pod-uid ;;
  *' get secret queue-managed-e2-reader -o go-template='*QUEUE_USERNAME*) echo tempo-consumer ;;
  *' get secret queue-managed-e2-reader -o go-template='*QUEUE_PASSWORD*) echo fixture-password ;;
  *kafka-get-offsets.sh*) n=$(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_DIR/calls"
    [ -f "$FAKE_DIR/offsets.$n" ] && cat "$FAKE_DIR/offsets.$n" || cat "$FAKE_DIR/offsets.1"; exit "$(cat "$FAKE_DIR/offsets.rc")" ;;
  *kafka-consumer-groups.sh*) cat "$FAKE_DIR/describe"; exit "$(cat "$FAKE_DIR/describe.rc")" ;;
  *' exec -i queue-admin -- sh -c umask 077; cat > "$1" sh /tmp/drain-reader-'*)
    cat >/dev/null; echo pending > "$FAKE_DIR/properties"
    [ "${DRAIN_FAKE_MODE:-}" != partial-write ] || exit 7 ;;
  *' exec -i queue-admin -- sh -c rm -f -- "$1" sh /tmp/drain-reader-'*)
    [ "${DRAIN_FAKE_MODE:-}" != cleanup-error ] || exit 7
    rm -f "$FAKE_DIR/properties" ;;
  *) echo kubectl >> "${DRAIN_FAKE_UNKNOWN:?}"; echo 'mock unknown kubectl' >&2; exit 97 ;;

esac
FAKE
chmod 0755 "$TMP/bin/kubectl" || exit 1
cat > "$TMP/bin/jq" <<'FAKEJQ' || exit 1
#!/usr/bin/env bash
[ "$#" = 2 ] && [ "$1" = -er ] || exit 97
case "$2" in .cluster_arn|.cluster_name|.bootstrap_brokers_scram|.kms_key_arn|.topic_name|.partitions) ;; *) echo jq >> "${DRAIN_FAKE_UNKNOWN:?}"; exit 97 ;; esac
exec "$QUEUE_TEST_REAL_PYTHON" -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1][1:]])' "$2"
FAKEJQ
cat > "$TMP/bin/sleep" <<'NOSLEEP' || exit 1
#!/usr/bin/env bash
echo sleep >> "${DRAIN_FAKE_UNKNOWN:?}"; exit 97
NOSLEEP
chmod 0755 "$TMP/bin/jq" "$TMP/bin/sleep" || exit 1
export DRAIN_FAKE_UNKNOWN="$TMP/unknown-calls"
: > "$DRAIN_FAKE_UNKNOWN"
for tool in python3 aws terraform kubectl jq sleep; do
  [ -x "$TMP/bin/$tool" ] && [ "$(PATH="$TMP/bin:/usr/bin:/bin" command -v "$tool")" = "$TMP/bin/$tool" ] || { echo "Mock resolution failed: $tool" >&2; exit 1; }
done
mkdir -p "$TMP/home" || exit 1
export HOME="$TMP/home" AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true KUBECONFIG=/dev/null
export QUEUE_EKS_CLUSTER=fixture MANAGED_QUEUE_REQUEST_ID=approved-drain-001 DRAIN_APPROVED_POD_UID=fixture-pod-uid
export MANAGED_QUEUE_APPROVED_CLUSTER_ARN=arn:aws:kafka:ap-northeast-2:111111111111:cluster/fixture/id
OK=0 FAIL=0
HEADER='GROUP           TOPIC             PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG             CONSUMER-ID     HOST            CLIENT-ID'
row() { printf '%-15s %-17s %-10s %-15s %-15s %-15s %-15s %-15s %s\n' block-builder "$1" "$2" "$3" "$4" "$5" - - -; } # 예: row <토픽> <파티션> <현재> <끝> <LAG>
# 예: run_case <이름> <source> <토픽> <기대 종료 코드> <기대 판정 줄 앞부분> — offsets.1 · (offsets.2) · describe · 두 rc 파일은 호출 전에 $FAKE_DIR 에 둡니다.
run_case() {
  local name="$1" source="$2" want_rc="$4" want="$5" out rc
  out=$(PATH="$TMP/bin:/usr/bin:/bin" DRAIN_APPROVED_SOURCE="$source" FAKE_DIR="$FAKE_DIR" EXPECTED_ACCOUNT_ID=111111111111 AWS_REGION=ap-northeast-2 KUBE_CONTEXT=fake DRAIN_INTERVAL_SECONDS=0 bash "$QUEUE/scripts/check-drain.sh" --source "$source" 2> /dev/null | tail -1); rc=${PIPESTATUS[0]}
  out=${out%% report=*}
  if [ "$rc" = "$want_rc" ] && [ "$out" = "$want" ]; then OK=$((OK + 1)); printf 'OK    %-28s exit=%s %s\n' "$name" "$rc" "$out"; else FAIL=$((FAIL + 1)); printf 'FAIL  %-28s want=exit=%s %s got=exit=%s %s\n' "$name" "$want_rc" "$want" "$rc" "$out"; fi
}
fixture() { # 예: fixture <토픽> → 파티션 3 · 끝 offset 10 · 11 · 10 · LAG 0 의 정상 조회를 새 디렉터리에 만듭니다
  FAKE_DIR=$(mktemp -d "$TMP/case.XXXXXX") || exit 1; echo 0 > "$FAKE_DIR/offsets.rc"; echo 0 > "$FAKE_DIR/describe.rc"
  printf '%s:0:10\n%s:1:11\n%s:2:10\n' "$1" "$1" "$1" > "$FAKE_DIR/offsets.1"
  { echo; echo "$HEADER"; row "$1" 0 10 10 0; row "$1" 1 11 11 0; row "$1" 2 10 10 0; } > "$FAKE_DIR/describe"
}
T=platform-traces
fixture $T; run_case lag-zero self-managed $T 0 'DRAINED stable_end_offsets=true lag=0 end=31'
fixture $T; { echo; echo "$HEADER"; row $T 0 10 10 0; row $T 1 4 11 7; row $T 2 10 10 0; } > "$FAKE_DIR/describe"
run_case lag-positive self-managed $T 1 'NOT_DRAINED stable_end_offsets=true lag=7'
fixture $T; printf '%s:0:10\n%s:1:12\n%s:2:10\n' $T $T $T > "$FAKE_DIR/offsets.2"
run_case offsets-moving self-managed $T 1 'NOT_DRAINED stable_end_offsets=false lag=0'
fixture $T; echo 'Error: Executing consumer group command failed due to Timed out waiting for a node assignment.' > "$FAKE_DIR/describe"; echo 1 > "$FAKE_DIR/describe.rc"
run_case describe-failed self-managed $T 2 'INCONCLUSIVE group-describe-failed:rc=1'
fixture $T; echo "Error: Consumer group 'block-builder' does not exist." > "$FAKE_DIR/describe"
run_case group-missing self-managed $T 2 'INCONCLUSIVE group-rows-missing:block-builder'
fixture $T; : > "$FAKE_DIR/describe"
run_case describe-empty self-managed $T 2 'INCONCLUSIVE group-rows-missing:block-builder'
fixture $T; { echo; echo "$HEADER"; row $T 0 10 10 0; row $T 2 10 10 0; } > "$FAKE_DIR/describe"
run_case partition-missing self-managed $T 2 'INCONCLUSIVE group-partitions-missing:1'
fixture $T; { echo; echo "$HEADER"; row $T 0 10 10 0; row $T 1 - 11 -; row $T 2 10 10 0; } > "$FAKE_DIR/describe"
run_case lag-not-numeric self-managed $T 2 'INCONCLUSIVE group-lag-not-numeric:1'
fixture $T; echo 1 > "$FAKE_DIR/offsets.rc"
run_case offsets-failed self-managed $T 2 'INCONCLUSIVE offsets-query-failed'
M=dev-tempo-traces-epoch-2
fixture $M; run_case managed-lag-zero managed $M 0 'DRAINED stable_end_offsets=true lag=0 end=31'
for mode in self-managed managed; do
  [ "$mode" = managed ] && topic="$M" || topic="$T"
  fixture "$topic"; row "$topic" 3 10 10 0 >> "$FAKE_DIR/describe"
  run_case "$mode-extra-partition" "$mode" "$topic" 2 'INCONCLUSIVE group-partition-row-count:4'
  fixture "$topic"; row "$topic" 0 10 10 0 >> "$FAKE_DIR/describe"
  run_case "$mode-duplicate-partition" "$mode" "$topic" 2 'INCONCLUSIVE group-partitions-missing:1'
  fixture "$topic"
  { echo "$HEADER"; row "$topic" 0 10 10 0; row "$topic" 1 11 11 0; row "$topic" 3 10 10 0; } > "$FAKE_DIR/describe"
  run_case "$mode-wrong-partition" "$mode" "$topic" 2 'INCONCLUSIVE group-partitions-missing:1'
done
fixture $T; { echo; echo "$HEADER"; row $T 0 10 10 0; row $T 1 4 11 7; row $T 2 10 10 0; } > "$FAKE_DIR/describe"
rm -rf "$QUEUE/local-inputs" # 예: 같은 초에 만든 앞 검사의 기록 파일과 섞이지 않게 비움
PATH="$TMP/bin:/usr/bin:/bin" DRAIN_APPROVED_SOURCE=self-managed FAKE_DIR="$FAKE_DIR" EXPECTED_ACCOUNT_ID=111111111111 AWS_REGION=ap-northeast-2 KUBE_CONTEXT=fake DRAIN_INTERVAL_SECONDS=0 bash "$QUEUE/scripts/check-drain.sh" --source self-managed > "$FAKE_DIR/stdout" 2> /dev/null
want=$(printf 'end_offset_partition\t0\t10\nend_offset_partition\t1\t11\nend_offset_partition\t2\t10\nblock-builder_committed_partition\t0\t10\nblock-builder_committed_partition\t1\t4\nblock-builder_committed_partition\t2\t10')
got=$(grep -hE '^(end_offset_partition|block-builder_committed_partition)' "$QUEUE/local-inputs"/drain-*.tsv)
if [ "$got" = "$want" ] && ! grep -q '_partition' "$FAKE_DIR/stdout"; then OK=$((OK + 1)); printf 'OK    %-28s rows=6 stdout=unchanged\n' report-partition-rows
else FAIL=$((FAIL + 1)); printf 'FAIL  %-28s got=%s\n' report-partition-rows "$(printf '%s' "$got" | tr '\t\n' ' ;')"; fi
for DRAIN_FAKE_MODE in partial-write cleanup-error uid-error; do
  export DRAIN_FAKE_MODE
  fixture $M
  out=$(PATH="$TMP/bin:/usr/bin:/bin" DRAIN_APPROVED_SOURCE=managed FAKE_DIR="$FAKE_DIR" EXPECTED_ACCOUNT_ID=111111111111 AWS_REGION=ap-northeast-2 KUBE_CONTEXT=fake DRAIN_INTERVAL_SECONDS=0 bash "$QUEUE/scripts/check-drain.sh" --source managed 2>/dev/null); rc=$?
  if [ "$rc" = 2 ] && ! printf '%s' "$out" | grep -q '^DRAINED'; then OK=$((OK+1)); else FAIL=$((FAIL+1)); fi
  [ "$DRAIN_FAKE_MODE" = cleanup-error ] || [ ! -f "$FAKE_DIR/properties" ] || FAIL=$((FAIL+1))
done
unset DRAIN_FAKE_MODE
[ ! -s "$DRAIN_FAKE_UNKNOWN" ] || { echo "unknown mock calls" >&2; FAIL=$((FAIL+1)); }
echo "check-drain-cases: $OK OK, $FAIL FAIL"
[ "$FAIL" = 0 ]
