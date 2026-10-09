#!/usr/bin/env bash
set -euo pipefail
DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/../gitops-lifecycle.py" "${1:?up or down required}" platform-queue
