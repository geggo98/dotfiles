#!/bin/zsh
# Smoke test for the nixos skill.
#
# The point of this test is narrow and worth stating: the CLI depends on
# mcp_nixos INTERNALS (`mcp_nixos.server.nix.fn`). Upstream owes us no stability
# there, so a version bump can rename or rewrap it. Without this test that shows
# up as a confusing runtime failure inside somebody's task; with it, it shows up
# here.
#
# Network is required — every action is an HTTP query, there is no local index.
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: this script requires zsh but is running under bash."
  exit 1
fi
set -euo pipefail

Q=${NIX_QUERY:-+nix-query}
command -v "$Q" >/dev/null 2>&1 || { echo >&2 "not on PATH: $Q"; exit 2; }

fail=0
check() {
  local label="$1" pattern="$2"; shift 2
  local out
  if ! out=$("$Q" "$@" 2>&1); then
    printf '%-34s FAIL (exit %s)\n' "$label" "$?"
    printf '%s\n' "$out" | head -3
    fail=1
    return
  fi
  if printf '%s' "$out" | grep -q "$pattern"; then
    printf '%-34s ok\n' "$label"
  else
    printf '%-34s FAIL (no match for %s)\n' "$label" "$pattern"
    printf '%s\n' "$out" | head -3
    fail=1
  fi
}

# One per code path that reaches a different upstream tool or source.
check "search (nixos packages)"  'ripgrep'      search ripgrep --limit 2
check "info (exact package)"     'ripgrep'      info ripgrep --type package
check "versions (nixhub)"        'Total versions' versions duckdb --limit 2
check "channels"                 'Branch'       channels
check "search (home-manager)"    'option'       search enable --source home-manager --limit 2

exit $fail
