#! /bin/zsh

set -euo pipefail

# Absolute directory of this script, even when sourced or symlinked
SCRIPT_DIR="${0:A:h}"

timeout="5m"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

exec gtimeout "$timeout" "${SCRIPT_DIR}/perplexity_open_router_research.py" "${args[@]}"
