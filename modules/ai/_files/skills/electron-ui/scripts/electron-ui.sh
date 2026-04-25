#!/bin/zsh
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/electron-ui.sh) or with: zsh scripts/electron-ui.sh"
  exit 1
fi
set -eEuo pipefail
trap 'e=$?; trap - EXIT; cleanup; exit $e' EXIT
cleanup() {
  :
}

SCRIPT_DIR="${0:A:h}"
AGENT_BROWSER="${AGENT_BROWSER:-agent-browser}"

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

if $silent; then
  gtimeout "$timeout" "$AGENT_BROWSER" "${args[@]}" >/dev/null 2>&1
  exit $?
fi

if [[ -n "$head_n" || -n "$tail_n" || -n "$match_pattern" || -n "$replace_pattern" ]]; then
  output="$(gtimeout "$timeout" "$AGENT_BROWSER" "${args[@]}" 2>&1)"
  rc=$?

  if [[ -n "$match_pattern" ]]; then
    output="$(echo "$output" | grep -E "$match_pattern" || true)"
  fi
  if [[ -n "$replace_pattern" ]]; then
    output="$(echo "$output" | sed -E "s|${replace_pattern}|${replace_with}|g")"
  fi
  if [[ -n "$head_n" ]]; then
    output="$(echo "$output" | head -n "$head_n")"
  fi
  if [[ -n "$tail_n" ]]; then
    output="$(echo "$output" | tail -n "$tail_n")"
  fi

  echo "$output"
  exit $rc
fi

exec gtimeout "$timeout" "$AGENT_BROWSER" "${args[@]}"
