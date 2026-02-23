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

exec "${SCRIPT_DIR}/eval_notebook.py" "$@"
