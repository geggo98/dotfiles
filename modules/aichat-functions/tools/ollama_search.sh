#!/usr/bin/env bash
# Description: Query a local Ollama model for offline reasoning.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ollama_search.sh --query <text> [--model <name>] [--json]

Options:
  --query, -q    Prompt text to send to the model (required)
  --model, -m    Ollama model to use (default: llama3)
  --host         Ollama host (default: http://127.0.0.1:11434)
  --json         Output raw JSON response
  --help, -h     Show help
USAGE
}

require() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "ollama_search.sh: missing dependency '$name'" >&2
    exit 1
  fi
}

require jq
require curl

query=""
model="llama3"
host="http://127.0.0.1:11434"
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
    --host)
      host=${2:-}
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
      echo "ollama_search.sh: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$query" ]]; then
  echo "ollama_search.sh: --query is required" >&2
  usage >&2
  exit 1
fi

payload=$(jq -n --arg model "$model" --arg prompt "$query" '{
  model: $model,
  prompt: $prompt,
  stream: false
}')

response=$(curl -sS --fail-with-body \
  -H "Content-Type: application/json" \
  -X POST "$host/api/generate" \
  -d "$payload")

if [[ "$json_output" == "true" ]]; then
  printf '%s\n' "$response"
else
  jq -r '.response // empty' <<<"$response"
fi
