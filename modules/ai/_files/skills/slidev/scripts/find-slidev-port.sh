#!/bin/zsh
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/find-slidev-port.sh) or with: zsh scripts/find-slidev-port.sh"
  exit 1
fi
set -euo pipefail

# Absolute directory of this script, even when sourced or symlinked
SCRIPT_DIR="${0:A:h}"

exec gtimeout 2m "${SCRIPT_DIR}/find-slidev-port.py" "$@"
