#!/usr/bin/env bash
# data/tests/lib.sh — 셸 테스트 공통 (각 *.test.sh 가 source; delivery/tests/lib.sh 와 같은 최소 테스트 러너(runner), 데이터베이스 운영자 이미지와 읽기 전용 진단). unittest 대신 쓰는 최소 테스트 러너: 케이스 이름 · 기대 종료 코드 · 출력 문자열 대조, 마지막에 "Ran N tests" 와 OK / FAILED.
# 사용 예: t_begin "case name"; t_exit 2 bash data/operator/operator-check.sh; t_out_contains "REJECTED"; t_end
# 모든 케이스는 로컬 파일 · 가짜 CLI(tests/fake) 만 씁니다. AWS · 클러스터 호출은 없습니다.
T_RUN=0; T_FAIL=0; T_NAME=""; T_OUT=""; T_CODE=0
T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/data-test.XXXXXX")" # 예: 케이스별 작업 파일 (끝나면 삭제)
trap 'rm -rf "$T_TMP"' EXIT

t_begin() { T_NAME="$1"; T_RUN=$((T_RUN + 1)); T_CASE_FAILED=0; }                    # 예: 케이스 시작
t_fail() { T_CASE_FAILED=1; printf 'FAIL: %s — %s\n' "$T_NAME" "$1" >&2; }            # 예: 이유와 함께 실패 표시
t_end() { if [ "$T_CASE_FAILED" = 1 ]; then T_FAIL=$((T_FAIL + 1)); printf '%s ... FAIL\n' "$T_NAME"; else printf '%s ... ok\n' "$T_NAME"; fi; }

# 명령을 실행해 종료 코드와 stdout 을 보관하고 기대 코드와 비교합니다 (set -e 영향 없이).
t_exit() { # 예: t_exit 0 bash data/operator/bootstrap.sh
  expected="$1"; shift
  set +e
  T_OUT="$("$@" 2> "$T_TMP/stderr")"; T_CODE=$?
  set -e
  [ "$T_CODE" = "$expected" ] || t_fail "exit $T_CODE (expected $expected); stdout=$T_OUT; stderr=$(tail -3 "$T_TMP/stderr" | tr '\n' ' ')"
}
t_out_contains() { case "$T_OUT" in *"$1"*) ;; *) t_fail "stdout does not contain '$1': $T_OUT" ;; esac; }   # 예: 결과 문자열 확인
t_out_lacks() { case "$T_OUT" in *"$1"*) t_fail "stdout unexpectedly contains '$1': $T_OUT" ;; esac; }       # 예: 없어야 하는 문자열
t_json() { [ "$(printf '%s' "$T_OUT" | jq -r "$1")" = "$2" ] || t_fail "jq $1 = $(printf '%s' "$T_OUT" | jq -r "$1") (expected $2)"; } # 예: t_json .result PASS
t_file_contains() { grep -q -- "$2" "$1" || t_fail "file $1 lacks '$2'"; }                                   # 예: 호출 기록 확인
t_file_lacks() { ! grep -q -- "$2" "$1" || t_fail "file $1 unexpectedly has '$2'"; }                         # 예: 없어야 하는 호출

t_summary() { # 예: 마지막에 호출 — unittest 형식의 요약 (실패가 있으면 종료 1)
  printf -- '----------------------------------------------------------------------\nRan %d tests\n\n' "$T_RUN"
  if [ "$T_FAIL" = 0 ]; then printf 'OK\n'; exit 0; else printf 'FAILED (failures=%d)\n' "$T_FAIL"; exit 1; fi
}
