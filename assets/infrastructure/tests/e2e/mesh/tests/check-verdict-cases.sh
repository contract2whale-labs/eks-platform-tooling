#!/usr/bin/env bash
# tests/e2e/mesh/tests/check-verdict-cases.sh
# 서비스 메시 · STRICT와 workload 신원을 단계별로 검증하기: "확인하지 못한 것을 통과로 적지 않는다" 를 가짜 kubectl 로 고정합니다. 클러스터 호출 없음.
#   probe-connect.sh     : 검사가 실제로 낸 판정 줄이 있을 때만 0(REACHED) · 1(CLOSED), kubectl 자체의 실패(Forbidden · stream 오류 · 빈 출력)는 2
#   check-mesh-compat.sh : 노드 조회가 실패하면 "taint 0종 전부 견딤" 이 아니라 INCONCLUSIVE
# 사용: bash tests/check-verdict-cases.sh   → "check-verdict-cases: 10 OK, 0 FAIL"
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d) || exit 1; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" || exit 1
cat > "$WORK/bin/kubectl" <<'FAKE' || exit 1
#!/usr/bin/env bash
# 가짜 kubectl: FAKE_EXEC(검사 실행 결과) · FAKE_NODES(노드 조회 결과)로 응답을 고릅니다.
args="$*"
case "$args" in
  *" get svc "*) echo 10.100.12.34 ;;
  *" exec "*)
    case "${FAKE_EXEC:-}" in
      reached) echo 'REACHED: HTTP/1.0 200 OK src=10.0.1.5:40000'; exit 0 ;;
      closed) echo 'CLOSED: EOF without response; inspect receiver ztunnel logs'; exit 1 ;;
      timeout) echo 'INCONCLUSIVE: TimeoutError'; exit 2 ;;
      forbidden) echo 'Error from server (Forbidden): pods "mesh-outside" is forbidden: cannot create resource "pods/exec"' >&2; exit 1 ;;
      stream) echo 'error: unable to upgrade connection: container not found' >&2; exit 1 ;;
      empty) exit 1 ;;
    esac ;;
  *" version"*) echo 'Server Version: v1.36.3-eks-abc' ;;
  *" get daemonset -A "*) echo 'kube-system/aws-node' ;;
  *" get crd "*) exit 0 ;;
  *" get nodes "*)
    case "${FAKE_NODES:-}" in
      none) echo 'node/ip-10-0-1-10' ;;
      known) printf 'node/ip-10-0-1-10\n%s\n' "$FAKE_TAINT" ;;
      unknown) printf 'node/ip-10-0-1-10\nteam=blocked:NoSchedule\n' ;;
      failed) echo 'Unable to connect to the server: net/http: request canceled' >&2; exit 1 ;;
    esac ;;
esac
FAKE
chmod +x "$WORK/bin/kubectl" || exit 1
[ -x "$WORK/bin/kubectl" ] && [ "$(PATH="$WORK/bin:$PATH" command -v kubectl)" = "$WORK/bin/kubectl" ] || { echo 'Mock kubectl resolution failed' >&2; exit 1; }
ok=0; bad=0
check() { # 예: check <이름> <기대 종료 코드> <출력에 있어야 할 글자> <명령…>
  local name=$1 want=$2 text=$3; shift 3
  local out rc; out=$(PATH="$WORK/bin:$PATH" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -q -- "$text"; then ok=$((ok + 1)); printf 'OK    %s\n' "$name"
  else bad=$((bad + 1)); printf 'FAIL  %s (rc=%s want=%s) %s\n' "$name" "$rc" "$want" "$(printf '%s' "$out" | tail -n 1 | cut -c1-120)"; fi
}
probe() { KUBE_CONTEXT=fake bash "$ROOT/scripts/probe-connect.sh" team-mesh-outside mesh-outside; }
compat() { bash "$ROOT/scripts/check-mesh-compat.sh" --context fake; }

FAKE_EXEC=reached   check 'probe.reached          판정 줄 REACHED · 종료 0' 0 '^REACHED: ' probe
FAKE_EXEC=closed    check 'probe.closed           판정 줄 CLOSED · 종료 1' 1 '^CLOSED: ' probe
FAKE_EXEC=timeout   check 'probe.timeout          판정 줄 INCONCLUSIVE · 종료 2' 2 '^INCONCLUSIVE: ' probe
FAKE_EXEC=forbidden check 'probe.exec-forbidden   kubectl 종료 1 이지만 판정 줄이 없어 종료 2' 2 'did not run to a verdict' probe
FAKE_EXEC=stream    check 'probe.stream-failure   exec stream 실패도 종료 2' 2 'did not run to a verdict' probe
FAKE_EXEC=empty     check 'probe.empty-output     빈 출력 · 종료 1 도 종료 2' 2 'did not run to a verdict' probe
FAKE_NODES=none     check 'compat.no-taint        taint 없음 → PASS' 0 'MESH_COMPAT_PASS' compat
FAKE_NODES=known FAKE_TAINT=workload=kafka:NoSchedule check 'compat.known-taint     견디는 taint → PASS' 0 'MESH_COMPAT_PASS' compat
FAKE_NODES=unknown  check 'compat.unknown-taint   견디지 못하는 taint → FAIL' 1 'MESH_COMPAT_FAIL' compat
FAKE_NODES=failed   check 'compat.node-query-fail 노드 조회 실패 → INCONCLUSIVE (0종 PASS 아님)' 2 'MESH_COMPAT_INCONCLUSIVE' compat
echo "check-verdict-cases: $ok OK, $bad FAIL"; [ "$bad" -eq 0 ]
