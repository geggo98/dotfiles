#! /bin/zsh

set -euo pipefail

# Absolute directory of this script, even when sourced or symlinked
SCRIPT_DIR="${0:A:h}"

exec gtimeout 1m "${SCRIPT_DIR}/streamdeck_manifest.ts" "$@"

