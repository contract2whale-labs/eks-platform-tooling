#!/usr/bin/env bash
# Evidence storage verifies integrity. The engineer evaluates operational results.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "${TOOLING_PYTHON:-python3}" "$SCRIPT_DIR/evidence.py" "$@"
