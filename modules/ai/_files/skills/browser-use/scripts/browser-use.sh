#!/bin/zsh
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/browser-use.sh) or with: zsh scripts/browser-use.sh"
  exit 1
fi
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

timeout="5m"
silent=false
head_n=""
tail_n=""
match_pattern=""
replace_pattern=""
replace_with=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    --silent) silent=true; shift ;;
    --head) head_n="$2"; shift 2 ;;
    --tail) tail_n="$2"; shift 2 ;;
    --match) match_pattern="$2"; shift 2 ;;
    --replace) replace_pattern="$2"; replace_with="$3"; shift 3 ;;
    *) args+=("$1"); shift ;;
  esac
done

# Silent mode: discard all output, only propagate exit code
if $silent; then
  gtimeout "$timeout" "${SCRIPT_DIR}/browser-use.py" "${args[@]}" >/dev/null 2>&1
  exit $?
fi

# Run command and capture output for post-processing
if [[ -n "$head_n" || -n "$tail_n" || -n "$match_pattern" || -n "$replace_pattern" ]]; then
  output="$(gtimeout "$timeout" "${SCRIPT_DIR}/browser-use.py" "${args[@]}" 2>&1)"
  rc=$?

  # Apply regex match filter (grep -P)
  if [[ -n "$match_pattern" ]]; then
    output="$(echo "$output" | grep -E "$match_pattern" || true)"
  fi

  # Apply regex replace (sed -E)
  if [[ -n "$replace_pattern" ]]; then
    output="$(echo "$output" | sed -E "s|${replace_pattern}|${replace_with}|g")"
  fi

  # Apply head (first N lines)
  if [[ -n "$head_n" ]]; then
    output="$(echo "$output" | head -n "$head_n")"
  fi

  # Apply tail (last N lines)
  if [[ -n "$tail_n" ]]; then
    output="$(echo "$output" | tail -n "$tail_n")"
  fi

  echo "$output"
  exit $rc
fi

exec gtimeout "$timeout" "${SCRIPT_DIR}/browser-use.py" "${args[@]}"
