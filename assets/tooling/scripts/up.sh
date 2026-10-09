#!/bin/sh
# 사용: sh scripts/up.sh <CHAPTER>
# 마지막으로 삭제(down)한 챕터까지 자원을 순서대로 재생성합니다.  실제 처리는 scripts/lab/lab.sh (bash) 가 수행합니다.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec bash "$SCRIPT_DIR/lab/lab.sh" up "$@"
