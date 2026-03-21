#!/bin/zsh
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/grafana.sh) or with: zsh scripts/grafana.sh"
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

# Parse wrapper-level options
timeout="5m"
env_files=()
cli_url=""
cli_org_id=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)   timeout="$2"; shift 2 ;;
    --env-file)  env_files+=("$2"); shift 2 ;;
    --url)       cli_url="$2"; shift 2 ;;
    --org-id)    cli_org_id="$2"; shift 2 ;;
    *)           args+=("$1"); shift ;;
  esac
done

# Source env files in order (later files override earlier ones)
for ef in "${env_files[@]}"; do
  [[ -f "$ef" ]] || die "env file not found: $ef"
  set -a; source "$ef"; set +a
done

# CLI flags override env files
[[ -n "$cli_url" ]]    && export GRAFANA_URL="$cli_url"
[[ -n "$cli_org_id" ]] && export GRAFANA_ORG_ID="$cli_org_id"

# Map legacy/convenience names to canonical env vars
if [[ -z "${GRAFANA_URL:-}" && -n "${GRAFANA_INSTANCE:-}" ]]; then
  export GRAFANA_URL="https://${GRAFANA_INSTANCE}"
fi
if [[ -z "${GRAFANA_TOKEN:-}" && -n "${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  export GRAFANA_TOKEN="${GRAFANA_SERVICE_ACCOUNT_TOKEN}"
fi

exec gtimeout "$timeout" uv run --script "${SCRIPT_DIR}/grafana.py" "${args[@]}"
