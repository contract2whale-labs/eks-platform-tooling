#!/usr/bin/env bash
# Record observations and a human decision; this helper never declares LIVE or PASS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -ge 2 ] || { echo "usage: incident-record.sh draft|observe|collect|finalize CASE [options]" >&2; exit 2; }
action=$1 case_id=$2; shift 2
case "$case_id" in *[!a-zA-Z0-9_-]*|'') echo "invalid case" >&2; exit 2 ;; esac
directory=""
for ((i=1;i<=$#;i++)); do
  if [ "${!i}" = --directory ]; then j=$((i+1)); directory="${!j:-}"; fi
done
if [ -z "$directory" ]; then directory="$(bash "$SCRIPT_DIR/evidence.sh" path "$case_id")"; fi
exec python3 "$SCRIPT_DIR/incident-record.py" "$action" "$case_id" --directory "$directory" "$@"
