#!/usr/bin/env bash
# Description: Ensure an Ollama model is pulled locally.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ollama_fetch.sh --model <name> [--host <url>]

Options:
  --model, -m   Ollama model to download (required)
  --host        Ollama host (default: http://127.0.0.1:11434)
  --help, -h    Show this help
USAGE
}

require() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "ollama_fetch.sh: missing dependency '$name'" >&2
    exit 1
  fi
}

require jq
require curl

model=""
host="http://127.0.0.1:11434"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model|-m)
      model=${2:-}
      shift 2
      ;;
    --host)
      host=${2:-}
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ollama_fetch.sh: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$model" ]]; then
  echo "ollama_fetch.sh: --model is required" >&2
  usage >&2
  exit 1
fi

payload=$(jq -n --arg model "$model" '{ model: $model }')

response=$(curl -sS --fail-with-body \
  -H "Content-Type: application/json" \
  -X POST "$host/api/pull" \
  -d "$payload")

printf '%s\n' "$response"
