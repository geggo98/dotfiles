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
# AWS credentials deliberately have NO sops-nix lookup here.
#
# There used to be one — eight load_from_secret calls for aws_access_key_id,
# aws_session_token, agentcore_region and friends. Every one of them was dead:
# none of those files has ever existed, and none is declared in
# modules/secrets.nix. What actually works is the standard AWS CLI chain, fed by
# ~/.aws/config and ~/.aws/credentials, which sops-nix writes directly
# (modules/secrets.nix). agent-browser reads that chain itself, so this script
# has nothing to load and no secret to hold.
#
# AGENTCORE_* remain plain environment variables with documented defaults
# (us-east-1, aws.browser.v1, 3600) — see references/aws-agentcore.md.

timeout="5m"
silent=false
head_n=""
tail_n=""
match_pattern=""
replace_pattern=""
replace_with=""
aws_agent_core=false
engine="agent-browser"
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
    --engine) engine="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

case "$engine" in
  agent-browser) ;;
  camoufox)
    $aws_agent_core && die "--engine camoufox is incompatible with --aws-agent-core (AgentCore is Chromium-only)"
    AGENT_BROWSER="${CAMOUFOX_DRIVER:-camoufox-driver}"
    ;;
  *) die "Unknown --engine: ${engine} (supported: agent-browser, camoufox)" ;;
esac

if $aws_agent_core; then
  # Say which identity this run will bill and act as, before doing either.
  #
  # AWS_PROFILE is inherited, not chosen here, and sops-nix writes the *C24 work*
  # profile into ~/.aws/credentials — so a stray AWS_PROFILE from a direnv or an
  # earlier command silently redirects AgentCore at another identity. The
  # justfile hits the same hazard with Pulumi and unsets the variable; that is
  # right there, where explicit static keys are injected and must not be
  # overridden. Here the profile *is* the credential source, so unsetting it
  # would break a deliberate choice. Report it instead: visible beats silent,
  # and the fix stays in the caller's hands.
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    identity="static key ${AWS_ACCESS_KEY_ID:0:4}… from \$AWS_ACCESS_KEY_ID"
  elif [[ -n "${AWS_PROFILE:-}" ]]; then
    identity="profile '${AWS_PROFILE}' (from \$AWS_PROFILE)"
  else
    identity="profile 'default' (~/.aws/config)"
  fi
  $silent || print -u2 "agentcore: region ${AGENTCORE_REGION:-us-east-1}, ${identity}"
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
