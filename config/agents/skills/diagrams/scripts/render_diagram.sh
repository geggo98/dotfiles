#!/bin/zsh
set -eEuo pipefail
die() {
  echo >&2 "ERROR: $*"
  exit 1
}
# e= & exit preserves the original exit code
# trap - ... prevents multiple cleanup() calls
# To only run on error instead of always, replace both EXITs with ERR
trap 'e=$?; trap - EXIT; cleanup; exit $e' EXIT
cleanup() {
  : # Delete this line and place cleanup code here.
}

SCRIPT_DIR="${0:A:h}"

timeout="5m"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

exec gtimeout "$timeout" "${SCRIPT_DIR}/render_diagram.py" "${args[@]}"
