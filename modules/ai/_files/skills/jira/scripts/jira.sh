#!/bin/zsh
# Thin wrapper for the jira skill CLI: resolves wrapper-level options, then execs
# the self-contained uv Python client under a timeout guard. All remaining args
# (including the global --write / --dangerous gating flags) are forwarded verbatim.
#
#   jira.sh [--timeout DUR] [--env-file PATH]... [--write] [--dangerous] <command> [args...]
#
# Run it directly (./scripts/jira.sh …); it requires zsh and gtimeout.
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/jira.sh) or with: zsh scripts/jira.sh"
  exit 1
fi
set -eEuo pipefail

die() {
  echo >&2 "ERROR: $*"
  exit 2
}

SCRIPT_DIR="${0:A:h}"
CLIENT="${SCRIPT_DIR}/jira.py"

# Parse wrapper-level options (everything else — commands, args, and the
# --write/--dangerous gating flags — is passed through to jira.py untouched).
timeout="5m"
env_files=()
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)  (( $# >= 2 )) || die "--timeout requires a value"; timeout="$2"; shift 2 ;;
    --env-file) (( $# >= 2 )) || die "--env-file requires a path"; env_files+=("$2"); shift 2 ;;
    *)          args+=("$1"); shift ;;
  esac
done

# Source env files in order (later files override earlier ones).
for ef in "${env_files[@]}"; do
  [[ -f "$ef" ]] || die "env file not found: $ef"
  set -a; source "$ef"; set +a
done

command -v uv       >/dev/null 2>&1 || die "uv not found — required to run jira.py (runs under 'uv run')."
command -v gtimeout >/dev/null 2>&1 || die "gtimeout not found — required as the timeout guard (GNU coreutils)."
[[ -x "$CLIENT" ]]  || die "client not found or not executable: $CLIENT"

exec gtimeout "$timeout" "$CLIENT" "${args[@]}"
