#!/usr/bin/env bash
# scripts/toolchain/install-kyverno.sh — kyverno CLI 를 GitHub Release 바이너리 + SHA-256 대조로 설치 (asdf 플러그인이 없는 도구)
# 사용: bash scripts/toolchain/install-kyverno.sh [설치 디렉터리]   (기본 ~/.local/bin; PATH 에 있어야 함 — scripts/toolchain/env.sh 가 앞에 넣음)
# 버전은 scripts/toolchain/tool-versions 의 kyverno 줄에서 읽습니다. 체크섬은 릴리스의 checksums.txt 에서 가져와 대조하며, 다르면 설치하지 않습니다.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)                    # 예: <TOOLING_ROOT>/scripts/toolchain
VERSION=$(awk '$1 == "kyverno" { print $2 }' "$DIR/tool-versions") # 예: 1.19.0
[ -n "$VERSION" ] || { echo "kyverno version not found in $DIR/tool-versions" >&2; exit 2; }
DEST="${1:-$HOME/.local/bin}"                                       # 예: ~/.local/bin
case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) echo "unsupported OS: $(uname -s)" >&2; exit 2 ;; esac
case "$(uname -m)" in arm64 | aarch64) ARCH=arm64 ;; x86_64 | amd64) ARCH=x86_64 ;; *) echo "unsupported arch: $(uname -m)" >&2; exit 2 ;; esac
FILE="kyverno-cli_v${VERSION}_${OS}_${ARCH}.tar.gz"                 # 예: kyverno-cli_v1.19.0_darwin_arm64.tar.gz
BASE="https://github.com/kyverno/kyverno/releases/download/v${VERSION}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -sSfL -o "$TMP/$FILE" "$BASE/$FILE"                            # 예: 릴리스 바이너리 (약 100 MB)
curl -sSfL -o "$TMP/checksums.txt" "$BASE/checksums.txt"            # 예: 릴리스가 서명한 체크섬 목록
EXPECTED=$(awk -v f="$FILE" '$2 == f { print $1 }' "$TMP/checksums.txt")
[ -n "$EXPECTED" ] || { echo "no checksum for $FILE in checksums.txt" >&2; exit 2; }
ACTUAL=$(shasum -a 256 "$TMP/$FILE" | awk '{ print $1 }')
[ "$ACTUAL" = "$EXPECTED" ] || { echo "CHECKSUM MISMATCH for $FILE: expected $EXPECTED got $ACTUAL" >&2; exit 1; } # 예: 다르면 설치하지 않음
mkdir -p "$DEST" && tar -xzf "$TMP/$FILE" -C "$TMP" kyverno && install -m 0755 "$TMP/kyverno" "$DEST/kyverno"
echo "INSTALLED kyverno $VERSION -> $DEST/kyverno (sha256 $ACTUAL)"     # 예: INSTALLED kyverno 1.19.0 -> /Users/ops/.local/bin/kyverno (sha256 6f4bd96c…)
