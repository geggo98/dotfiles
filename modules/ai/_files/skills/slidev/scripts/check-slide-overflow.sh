#!/bin/zsh
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/check-slide-overflow.sh) or with: zsh scripts/check-slide-overflow.sh"
  exit 1
fi
set -euo pipefail

# Absolute directory of this script, even when sourced or symlinked.
SCRIPT_DIR="${0:A:h}"

# Deno resolves npm:playwright (version pinned in the .ts import specifier);
# the co-located lock + --frozen pin the full transitive tree reproducibly.
# Permissions are the minimal set Playwright needs to launch a browser.
exec deno run \
  --allow-env --allow-read --allow-write --allow-net --allow-run --allow-sys \
  --lock="${SCRIPT_DIR}/check-slide-overflow.lock" --frozen \
  "${SCRIPT_DIR}/check-slide-overflow.ts" "$@"
