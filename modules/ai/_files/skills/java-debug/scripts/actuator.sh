#!/usr/bin/env bash
# actuator.sh — Thin bash wrapper that delegates to actuator.py
#
# All arguments are forwarded verbatim. The Python script handles base-URL
# resolution, auth chain, subcommands, and token-conservative output.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
PY="$SCRIPT_DIR/actuator.py"

if [[ ! -f "$PY" ]]; then
  printf 'error: %s not found next to %s\n' "$PY" "${BASH_SOURCE[0]}" >&2
  exit 2
fi

# Resolve python3
if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif [[ -x /usr/bin/python3 ]]; then
  PYTHON=/usr/bin/python3
else
  printf 'error: python3 not found on PATH\n' >&2
  exit 2
fi

exec "$PYTHON" "$PY" "$@"
