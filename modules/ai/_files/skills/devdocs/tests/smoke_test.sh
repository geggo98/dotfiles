#!/bin/zsh
# Smoke test for the devdocs skill, against the REAL installed +devdocs and
# its real 39-doc index — unlike the nixos skill's smoke test, this one is
# honest to run any time: everything here is a local SQLite lookup, so it
# needs no network and no upstream availability.
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: this script requires zsh but is running under bash."
  exit 1
fi
set -euo pipefail

D=${DEVDOCS:-+devdocs}
command -v "$D" >/dev/null 2>&1 || { echo >&2 "not on PATH: $D"; exit 2; }

fail=0
check() {
  local label="$1" pattern="$2"; shift 2
  local out
  if ! out=$("$D" "$@" 2>&1); then
    printf '%-40s FAIL (exit %s)\n' "$label" "$?"
    printf '%s\n' "$out" | head -3
    fail=1
    return
  fi
  if printf '%s' "$out" | grep -q "$pattern"; then
    printf '%-40s ok\n' "$label"
  else
    printf '%-40s FAIL (no match for %s)\n' "$label" "$pattern"
    printf '%s\n' "$out" | head -3
    fail=1
  fi
}
check_exit() {
  local label="$1" want="$2"; shift 2
  local got=0
  "$D" "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then
    printf '%-40s ok (exit %s)\n' "$label" "$got"
  else
    printf '%-40s FAIL (exit %s, wanted %s)\n' "$label" "$got" "$want"
    fail=1
  fi
}

# One per resolution path (path-suffix FQN, anchor exact match, ambiguity,
# flat-doc-with-anchored-entries fallback) plus the exit-code contract.
check "docs (openjdk installed)"          'openjdk' docs
check "show (FQN, path-suffix match)"     'Inserts the specified element' show 'java.util.List#add(int,E)'
check "members (page listing)"            'add' members java.util.List --doc openjdk
check "search (fuzzy, cross-doc)"         'groupingBy' search groupingBy --doc openjdk
check "doctor (index integrity)"          'OK' doctor
check_exit "empty result"                 1 search totallyNotARealSymbolXYZ --doc openjdk
check_exit "unknown slug"                 3 types not-a-real-slug-at-all
check_exit "search --online always fails" 3 search x --online

exit $fail
