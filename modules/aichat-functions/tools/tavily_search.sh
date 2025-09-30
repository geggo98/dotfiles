#!/usr/bin/env bash
# Description: Perform a Tavily web search and return JSON results.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tavily_search.sh --query <text> [--depth <basic|advanced>] [--max-results <n>] [--json]

Options:
  --query, -q       Search query to send to Tavily (required)
  --depth, -d       Search depth (basic or advanced, default: basic)
  --max-results, -n Maximum number of results to request (default: 5)
  --json            Output entire Tavily JSON response
  --help, -h        Show this help
USAGE
}

require() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "tavily_search.sh: missing dependency '$name'" >&2
    exit 1
  fi
}

require jq
require curl

query=""
depth="basic"
max_results=5
json_output="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query|-q)
      query=${2:-}
      shift 2
      ;;
    --depth|-d)
      depth=${2:-}
      shift 2
      ;;
    --max-results|-n)
      max_results=${2:-}
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
      echo "tavily_search.sh: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$query" ]]; then
  echo "tavily_search.sh: --query is required" >&2
  usage >&2
  exit 1
fi

if [[ -z "${TAVILY_API_KEY:-}" ]]; then
  echo "tavily_search.sh: TAVILY_API_KEY is not set" >&2
  exit 1
fi

payload=$(jq -n --arg query "$query" --arg depth "$depth" --argjson max "$max_results" '{
  query: $query,
  search_depth: $depth,
  include_images: false,
  include_answer: true,
  max_results: $max
}')

response=$(curl -sS --fail-with-body \
  -H "Content-Type: application/json" \
  -H "X-Tavily-API-Key: ${TAVILY_API_KEY}" \
  -X POST https://api.tavily.com/search \
  -d "$payload")

if [[ "$json_output" == "true" ]]; then
  printf '%s\n' "$response"
else
  jq '.results' <<<"$response"
fi
