#!/usr/bin/env bash
# 사용: bash "$TOOLING_ROOT/scripts/lab/set-env.sh" KEY VALUE
# 개인 설정 파일(work/lab.env)의 KEY 값을 바꾸거나 추가합니다. 파일 권한은 600 으로 유지합니다.
set -euo pipefail
[ $# -eq 2 ] || { echo "사용법: set-env.sh KEY VALUE" >&2; exit 2; }
file="${LAB_ENV_FILE:-${TOOLING_ROOT:?TOOLING_ROOT 를 먼저 export 하세요}/work/lab.env}"
key="$1"
value="$2"
[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "잘못된 키 이름: $key" >&2; exit 2; }
case "$value" in
  *'"'* | *'$'* | *'`'* | *\\*) echo "값에 따옴표 · \$ · 백틱 · 역슬래시를 넣을 수 없습니다: $key" >&2; exit 2 ;;
esac
[ -f "$file" ] || { echo "설정 파일이 없습니다: $file (PLATFORM-1 STEP 3)" >&2; exit 2; }
tmp="$(mktemp "$file.XXXXXX")"
awk -v k="$key" -v v="$value" '
  index($0, k "=") == 1 { if (!done) print k "=\"" v "\""; done = 1; next }
  { print }
  END { if (!done) print k "=\"" v "\"" }
' "$file" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$file"
printf 'SET\t%s\n' "$key"
