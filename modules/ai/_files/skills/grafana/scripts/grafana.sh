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
SKILL_DIR="${SCRIPT_DIR:h}"

# Source .env if present (GRAFANA_INSTANCE, GRAFANA_SERVICE_ACCOUNT_TOKEN)
if [[ -f "${SKILL_DIR}/.env" ]]; then
  set -a
  source "${SKILL_DIR}/.env"
  set +a
fi

# Build GRAFANA_URL from GRAFANA_INSTANCE if not already set
if [[ -z "${GRAFANA_URL:-}" && -n "${GRAFANA_INSTANCE:-}" ]]; then
  export GRAFANA_URL="https://${GRAFANA_INSTANCE}"
fi

# Map GRAFANA_SERVICE_ACCOUNT_TOKEN to GRAFANA_TOKEN if not already set
if [[ -z "${GRAFANA_TOKEN:-}" && -n "${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  export GRAFANA_TOKEN="${GRAFANA_SERVICE_ACCOUNT_TOKEN}"
fi

timeout="5m"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

exec gtimeout "$timeout" uv run --script "${SCRIPT_DIR}/grafana.py" "${args[@]}"
