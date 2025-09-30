#!/usr/bin/env bash
# Description: Run a deeper Perplexity search with higher recall.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pplx_deep.sh --query <text> [--model <name>] [--json]

Options:
  --query, -q    Query to send to Perplexity (required)
  --model, -m    OpenRouter model slug (default: perplexity/sonar-medium-online)
  --json         Emit raw JSON response instead of plain text summary
  --help, -h     Show this help message
USAGE
}

require() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "pplx_deep.sh: missing dependency '$name'" >&2
    exit 1
  fi
}

require jq
require curl

query=""
model="perplexity/sonar-medium-online"
json_output="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query|-q)
      query=${2:-}
      shift 2
      ;;
    --model|-m)
      model=${2:-}
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
      echo "pplx_deep.sh: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$query" ]]; then
  echo "pplx_deep.sh: --query is required" >&2
  usage >&2
  exit 1
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "pplx_deep.sh: OPENROUTER_API_KEY is not set" >&2
  exit 1
fi

payload=$(jq -n --arg query "$query" --arg model "$model" '{
  model: $model,
  messages: [
    {
      role: "system",
      content: "You are an in-depth research analyst. Exhaustively aggregate open web sources, reflect, and deliver structured insights with explicit citations and follow-up questions."
    },
    {
      role: "user",
      content: $query
    }
  ],
  stream: false,
  frequency_penalty: 0,
  presence_penalty: 0,
  top_p: 0.9
}')

response=$(curl -sS --fail-with-body \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H "HTTP-Referer: https://github.com/stefan" \
  -H "X-Title: aichat-functions" \
  -X POST https://openrouter.ai/api/v1/chat/completions \
  -d "$payload")

if [[ "$json_output" == "true" ]]; then
  printf '%s\n' "$response"
else
  jq -r '.choices[0].message.content // empty' <<<"$response"
fi
