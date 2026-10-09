#!/usr/bin/env bash
# modules/delivery/examples/tests/check-resign.sh — resign 워크플로의 run 스크립트를 가짜 cosign 으로 돌려 "승인된 digest 만 재서명된다" 를 고정합니다 (증적과 복구).
# 워크플로 YAML 에서 run: 본문을 yq 로 꺼내 그대로 실행합니다(복사본을 두지 않으므로 워크플로를 고치면 이 검사도 같이 움직입니다). AWS · GitHub · 레지스트리 호출 없음.
# 사용: bash modules/delivery/examples/tests/check-resign.sh   → "check-resign: 6 OK, 0 FAIL"
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WF="$HERE/../github-actions-resign.yml"
WORK=$(mktemp -d) || exit 2; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" || exit 2
cat > "$WORK/bin/cosign" <<'FAKE' || exit 2
#!/usr/bin/env bash
# 가짜 cosign: 호출을 $CALLS 에 남기고, FAKE_PREVIOUS 에 따라 이전 키 검증의 성패를 정합니다.
echo "$*" >> "$CALLS"
case "$1:$*" in
  verify:*delivery-signing-previous*) [ "${FAKE_PREVIOUS:-ok}" != no-signature ] ;;
  verify-attestation:*delivery-signing-previous*) [ "${FAKE_PREVIOUS:-ok}" = ok ] ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/bin/cosign" || exit 2
[ -x "$WORK/bin/cosign" ] || exit 2
step() { yq -r ".jobs.resign.steps[] | select(.name == \"$1\") | .run" "$WF"; }
VALIDATE=$(step 'Validate the digest input')
REQUIRE=$(step "Require the previous key's signature and attestation (approved image only)")
SIGN=$(step "Add the current key's signature and attestation, then verify")
GOOD="sha256:$(printf '%064d' 0)"
ok=0; bad=0
pass() { ok=$((ok + 1)); printf 'OK    %s\n' "$1"; }; fail() { bad=$((bad + 1)); printf 'FAIL  %s\n' "$1"; }
run_all() { # 예: run_all <digest> → 러너처럼 단계마다 bash -e 로, 앞 단계가 실패하면 뒤 단계는 돌지 않음
  export CALLS="$WORK/calls" GITHUB_ENV="$WORK/env" IMAGE_REPOSITORY=111111111111.dkr.ecr.ap-northeast-2.amazonaws.com/commerce-web
  export SIGNING_KEY=alias/delivery-signing PREVIOUS_KEY=alias/delivery-signing-previous DIGEST="$1" PATH="$WORK/bin:$PATH"
  hash -r
  [ "$(command -v cosign)" = "$WORK/bin/cosign" ] || { printf 'Mock cosign resolution mismatch\n' >&2; return 2; }
  : > "$CALLS"; : > "$GITHUB_ENV"
  bash -e -c "$VALIDATE" > /dev/null 2>&1 || return 2
  export REF="${IMAGE_REPOSITORY}@${DIGEST}"
  bash -e -c "$REQUIRE" > /dev/null 2>&1 || return 3
  bash -e -c "$SIGN" > /dev/null 2>&1 || return 4
}
signs() { grep -cE '^(sign|attest) ' "$WORK/calls"; }

FAKE_PREVIOUS=ok run_all "$GOOD"; rc=$?
[ "$rc" = 0 ] && [ "$(signs)" = 2 ] && grep -q '^verify --key awskms:///alias/delivery-signing ' "$WORK/calls" && pass 'approved.resigned         이전 키 서명 · attestation 확인 → 새 서명 2건 → 새 키 단독 검증' || fail "approved.resigned (rc=$rc signs=$(signs))"
FAKE_PREVIOUS=no-signature run_all "$GOOD"; rc=$?
[ "$rc" = 3 ] && [ "$(signs)" = 0 ] && pass 'unsigned.rejected         이전 키 서명이 없으면 서명 호출 0회' || fail "unsigned.rejected (rc=$rc signs=$(signs))"
FAKE_PREVIOUS=no-attestation run_all "$GOOD"; rc=$?
[ "$rc" = 3 ] && [ "$(signs)" = 0 ] && pass 'no-attestation.rejected   attestation 이 없어도 서명 호출 0회' || fail "no-attestation.rejected (rc=$rc signs=$(signs))"
FAKE_PREVIOUS=ok run_all "sha256:short"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$WORK/env" ] && [ ! -s "$WORK/calls" ] && pass 'digest.malformed          형식이 틀리면 환경 파일을 쓰기 전에 거절' || fail "digest.malformed (rc=$rc)"
FAKE_PREVIOUS=ok run_all "$(printf '%s\nREF=evil' "$GOOD")"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$WORK/env" ] && pass 'digest.newline            개행이 든 입력은 환경 파일을 쓰기 전에 거절' || fail "digest.newline (rc=$rc env=$(wc -l < "$WORK/env"))"
[ "$(yq -r '.on | keys | join(",")' "$WF")" = workflow_dispatch ] && pass 'trigger.manual-only       수동 실행만 (push · tags 없음)' || fail 'trigger.manual-only'
echo "check-resign: $ok OK, $bad FAIL"; [ "$bad" -eq 0 ]
