#!/bin/sh
# 사용: sh scripts/down.sh <CHAPTER>
# 완료한 챕터까지 만든 자원을 역순으로 삭제합니다 (보존 대상 제외).  실제 처리는 scripts/lab/lab.sh (bash) 가 수행합니다.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec bash "$SCRIPT_DIR/lab/lab.sh" down "$@"
