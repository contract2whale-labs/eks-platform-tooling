#!/usr/bin/env bash
# 공개 템플릿의 조직 토큰을 실제 GITHUB_ORG로 바꿉니다. 첫 커밋 전에 실행합니다.
# 사용: GITHUB_ORG를 lab.env에서 읽은 뒤 bash "$TOOLING_ROOT/scripts/toolchain/render-github.sh" "$INFRA_ROOT"
# README.md, CODEOWNERS, GitOps YAML만 처리합니다. Terraform의 입력값은 terraform.tfvars에서 별도로 전달합니다.
set -euo pipefail
[[ $# == 1 && -d "$1" ]] || { echo '사용법: render-github.sh <저장소 디렉터리>' >&2; exit 2; }
: "${GITHUB_ORG:?work/lab.env에 GITHUB_ORG를 설정하고 env.sh를 source 하세요}"
[[ "$GITHUB_ORG" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ && ${#GITHUB_ORG} -le 39 ]] || { echo '잘못된 GitHub 조직 이름' >&2; exit 2; }
find "$1" -type d \( -name .git -o -name node_modules -o -name .terraform \) -prune -o \
  -type f \( -name README.md -o -name CODEOWNERS -o -name '*.yaml' -o -name '*.yml' \) -print0 |
  while IFS= read -r -d '' file; do
    if grep -q '__GITHUB_ORG__' "$file"; then
      tmp="$(mktemp)"
      sed "s/__GITHUB_ORG__/$GITHUB_ORG/g" "$file" > "$tmp"
      cat "$tmp" > "$file"
      rm -f "$tmp"
      echo "조직 적용: $file"
    fi
  done
echo "완료: GITHUB_ORG=$GITHUB_ORG (git diff로 변경 내용을 확인하세요)"
