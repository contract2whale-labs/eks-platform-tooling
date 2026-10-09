#!/bin/sh
# 사용: sh scripts/status.sh [--resources]
# 체크포인트와 계정별 잔여 과금 자원을 확인합니다.  실제 처리는 scripts/lab/lab.sh (bash) 가 수행합니다.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec bash "$SCRIPT_DIR/lab/lab.sh" status "$@"
