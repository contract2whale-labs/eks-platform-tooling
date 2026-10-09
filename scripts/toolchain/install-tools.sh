#!/usr/bin/env bash
# tool-versions를 먼저 읽고 실행하세요. 로컬 도구를 다운로드하고 설치합니다.
# AWS 리소스와 GitHub 저장소를 생성하지 않습니다. Bash 3.2 이상.
set -euo pipefail
DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v asdf >/dev/null
plugins="$(asdf plugin list)"
while read -r name version rest; do
  [ -n "$name" ] || continue
  case "$name" in \#*|kyverno) continue ;; esac
  if ! printf '%s\n' "$plugins" | grep -Fxq "$name"; then
    asdf plugin add "$name"
  fi
  asdf install "$name" "$version"
done < "$DIR/tool-versions"
bash "$DIR/install-kyverno.sh"
asdf reshim
printf '도구 설치가 끝났습니다. env.sh를 읽고 check-tools.sh로 버전을 확인하세요.\n'
