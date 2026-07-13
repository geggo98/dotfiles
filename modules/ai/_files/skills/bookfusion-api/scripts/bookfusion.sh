#!/usr/bin/env bash
# Thin wrapper for the bookfusion-api skill CLI.
# Runs the Kotlin main.kts client, bootstrapping the Kotlin toolchain via nix when it is
# not already on PATH (this host has no system-wide kotlin). All args are forwarded verbatim.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KTS="$SCRIPT_DIR/bookfusion.main.kts"

# Point the client at the shipped OpenAPI spec so it can validate requests before sending
# (respect a pre-set value; the client also accepts --spec PATH). See references/openapi.yaml.
: "${BOOKFUSION_OPENAPI:="$(cd "$SCRIPT_DIR/.." && pwd)/references/openapi.yaml"}"
export BOOKFUSION_OPENAPI

if [[ ! -f "$KTS" ]]; then
  echo "bookfusion: client not found at $KTS" >&2
  exit 6
fi

if command -v kotlin >/dev/null 2>&1; then
  exec kotlin "$KTS" "$@"
elif command -v nix >/dev/null 2>&1; then
  # First invocation compiles the script and resolves the single Gson dependency (cached afterwards).
  exec nix shell nixpkgs#kotlin --command kotlin "$KTS" "$@"
else
  echo "bookfusion: need 'kotlin' or 'nix' on PATH to run the client" >&2
  exit 127
fi
