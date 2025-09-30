#!/usr/bin/env bash
# Description: Fetch structured content for a URL via Tavily extract API.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tavily_fetch.sh --url <url> [--json]

Options:
  --url, -u    URL to fetch (required)
  --json       Output raw JSON (default prints the extracted summary)
  --help, -h   Show this help text
USAGE
}

require() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "tavily_fetch.sh: missing dependency '$name'" >&2
    exit 1
  fi
}

require jq
require curl

url=""
json_output="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url|-u)
      url=${2:-}
      shift 2
      ;;
    --json)
      json_output="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "tavily_fetch.sh: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$url" ]]; then
  echo "tavily_fetch.sh: --url is required" >&2
  usage >&2
  exit 1
fi

if [[ -z "${TAVILY_API_KEY:-}" ]]; then
  echo "tavily_fetch.sh: TAVILY_API_KEY is not set" >&2
  exit 1
fi

payload=$(jq -n --arg url "$url" '{ url: $url }')

response=$(curl -sS --fail-with-body \
  -H "Content-Type: application/json" \
  -H "X-Tavily-API-Key: ${TAVILY_API_KEY}" \
  -X POST https://api.tavily.com/extract \
  -d "$payload")

if [[ "$json_output" == "true" ]]; then
  printf '%s\n' "$response"
else
  jq -r '.summary // empty' <<<"$response"
fi
