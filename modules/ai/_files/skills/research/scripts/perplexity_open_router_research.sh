#!/bin/zsh
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/perplexity_open_router_research.sh) or with: zsh scripts/perplexity_open_router_research.sh"
  exit 1
fi
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
