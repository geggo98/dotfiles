#!/usr/bin/env bash
# jfr-summary.sh — Token-conservative summary of a .jfr recording
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: jfr-summary.sh <recording.jfr> [options]

Run `jfr summary` + `jfr metadata` against a recording, capping output so the agent
can read it in a single bite. Full output is spilled to a temp file when it would
exceed --max-lines.

Options:
  --max-events-per-type N   Cap metadata rows shown per event type (default: 5)
  --max-lines N             Spill to file if combined output exceeds N lines (default: 500)
  --output FILE             Force write the full output to FILE (no spill heuristic)
  --timeout SECS            jfr CLI timeout (default: 30)
  -h, --help                Show this help

Exit codes:
  0 ok | 1 usage error | 2 missing jfr | 3 jfr failed

Example:
  jfr-summary.sh /tmp/myapp.jfr
  jfr-summary.sh /tmp/myapp.jfr --output /tmp/full.txt
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

JFR_FILE=""
MAX_PER_TYPE=5
MAX_LINES=500
OUTPUT=""
TIMEOUT=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --max-events-per-type) MAX_PER_TYPE="$2"; shift 2 ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -*) err "unknown option: $1"; exit 1 ;;
    *) JFR_FILE="$1"; shift ;;
  esac
done

[[ -z "$JFR_FILE" ]] && { err "recording path required"; usage; exit 1; }
[[ -f "$JFR_FILE" ]] || { err "no such file: $JFR_FILE"; exit 1; }
command -v jfr >/dev/null 2>&1 || { err "jfr not found on PATH (need JDK 14+)"; exit 2; }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$TIMEOUT" "$@"
  else "$@"
  fi
}

TMP=$(mktemp -t jfr-summary-XXXXXX.txt)
trap 'rm -f "$TMP"' EXIT

{
  echo "=== jfr summary ==="
  run_with_timeout jfr summary "$JFR_FILE" 2>&1 || { err "jfr summary failed"; exit 3; }
  echo ""
  echo "=== jfr metadata (first $MAX_PER_TYPE rows per event type) ==="
  # `jfr metadata` blocks are headed by `<event name=...>` followed by fields.
  # Truncate within each block to MAX_PER_TYPE field lines.
  run_with_timeout jfr metadata "$JFR_FILE" 2>&1 \
    | awk -v cap="$MAX_PER_TYPE" '
        /^<event name=|^<periodic|^<type/ { block=0; print; next }
        /^$/ { block=0; print; next }
        { block++; if (block <= cap) print; else if (block == cap+1) print "  ... [truncated; use --max-events-per-type to see more]" }
      ' || true
} > "$TMP"

LINE_COUNT=$(wc -l < "$TMP" | tr -d ' ')

if [[ -n "$OUTPUT" ]]; then
  cp "$TMP" "$OUTPUT"
  printf 'wrote %s lines to %s\n' "$LINE_COUNT" "$OUTPUT"
elif (( LINE_COUNT > MAX_LINES )); then
  SPILL="/tmp/jfr-summary-$(date +%Y%m%d-%H%M%S).txt"
  cp "$TMP" "$SPILL"
  head -100 "$TMP"
  printf '\n... [%s lines omitted, full output at %s] ...\n\n' "$((LINE_COUNT - 120))" "$SPILL"
  tail -20 "$TMP"
else
  cat "$TMP"
fi
