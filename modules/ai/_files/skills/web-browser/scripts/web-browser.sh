#!/bin/zsh
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/web-browser.sh) or with: zsh scripts/web-browser.sh"
  exit 1
fi
set -eEuo pipefail
die() {
  echo >&2 "ERROR: $*"
  exit 1
}
trap 'e=$?; trap - EXIT; cleanup; exit $e' EXIT
cleanup() {
  :
}

SCRIPT_DIR="${0:A:h}"
AGENT_BROWSER="${AGENT_BROWSER:-agent-browser}"
SECRETS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets"

# Load env var from sops-nix secrets if not already set and the file exists.
# Silent on missing secrets — agent-browser falls back to the AWS CLI / SSO chain.
load_from_secret() {
  local var_name="$1" file_name="$2"
  local current_val="${(P)var_name-}"
  if [[ -z "$current_val" && -r "${SECRETS_DIR}/${file_name}" ]]; then
    local val
    val="$(<"${SECRETS_DIR}/${file_name}")"
    if [[ -n "$val" ]]; then
      export "${var_name}=${val}"
    fi
  fi
}

timeout="5m"
silent=false
head_n=""
tail_n=""
match_pattern=""
replace_pattern=""
replace_with=""
aws_agent_core=false
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    --silent) silent=true; shift ;;
    --head) head_n="$2"; shift 2 ;;
    --tail) tail_n="$2"; shift 2 ;;
    --match) match_pattern="$2"; shift 2 ;;
    --replace) replace_pattern="$2"; replace_with="$3"; shift 3 ;;
    --aws-agent-core) aws_agent_core=true; shift ;;
    *) args+=("$1"); shift ;;
  esac
done

if $aws_agent_core; then
  load_from_secret AWS_ACCESS_KEY_ID         aws_access_key_id
  load_from_secret AWS_SECRET_ACCESS_KEY     aws_secret_access_key
  load_from_secret AWS_SESSION_TOKEN         aws_session_token
  load_from_secret AWS_PROFILE               aws_profile
  load_from_secret AGENTCORE_REGION          agentcore_region
  load_from_secret AGENTCORE_BROWSER_ID      agentcore_browser_id
  load_from_secret AGENTCORE_PROFILE_ID      agentcore_profile_id
  load_from_secret AGENTCORE_SESSION_TIMEOUT agentcore_session_timeout
  args=(-p agentcore "${args[@]}")
fi

# Silent mode: discard all output, only propagate exit code
if $silent; then
  gtimeout "$timeout" "$AGENT_BROWSER" "${args[@]}" >/dev/null 2>&1
  exit $?
fi

# Run command and capture output for post-processing
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
