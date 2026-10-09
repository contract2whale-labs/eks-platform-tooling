#!/usr/bin/env bash
# 승인 PR·Argo sync 뒤 실제 상태를 읽기 검증합니다. source 또는 클러스터를 변경하지 않습니다.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INFRA_REPO=$(cd "$ROOT/../../../.." && pwd)
exec python3 "$INFRA_REPO/automation/verify_trace_transition.py" --revision "${APPROVED_GIT_REVISION:?Set the reviewed Git revision}" collection "$@"
