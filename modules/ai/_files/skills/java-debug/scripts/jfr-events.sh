#!/usr/bin/env bash
# jfr-events.sh — Extract specific JFR events from a recording, with sane caps
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: jfr-events.sh <recording.jfr> [options]

Wrap `jfr print --events <pattern> [--json] <file>` with token-conservative defaults.
Without --events, lists distinct event types found in the recording.

Options:
  --events PATTERN     Event type or wildcard (e.g. jdk.GarbageCollection, 'jdk.GC*',
                       'com.example.*', 'spring.startup'). Omit to list types.
  --json               Emit JSON (default for parsing); --text for jfr's native format
  --text               Emit jfr's tabular text format
  --jq EXPR            jq expression applied when --json. Default projection:
                       '.recording.events[] | {type, startTime, duration, thread: .thread.name}'
  --max-events N       Hard cap on emitted events (default: 100)
  --stack-depth N      jfr print --stack-depth N (default: 16)
  --output FILE        Force write full output to FILE
  --max-lines N        Spill to file if output exceeds N lines (default: 500)
  --timeout SECS       jfr CLI timeout (default: 60)
  -h, --help           Show this help

Exit codes:
  0 ok | 1 usage error | 2 missing jfr/jq | 3 jfr failed

Warning:
  `jdk.ExecutionSample` typically has 10k+ events per minute. Without --max-events the
  script will refuse to dump them all; raise the cap explicitly if needed.

Examples:
  # What event types are in this recording?
  jfr-events.sh /tmp/myapp.jfr

  # GC events as JSON, default projection
  jfr-events.sh /tmp/myapp.jfr --events 'jdk.GC*'

  # Custom application events with custom jq projection
  jfr-events.sh /tmp/myapp.jfr --events 'com.example.*' \
    --jq '.recording.events[] | {type, orderId, durationMs: (.duration / 1000000)}'

  # CPU samples, raw text, capped at 200
  jfr-events.sh /tmp/myapp.jfr --events jdk.ExecutionSample --text --max-events 200
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

JFR_FILE=""
EVENTS=""
FORMAT="json"
JQ_EXPR=""
MAX_EVENTS=100
STACK_DEPTH=16
OUTPUT=""
MAX_LINES=500
TIMEOUT=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --events) EVENTS="$2"; shift 2 ;;
    --json) FORMAT="json"; shift ;;
    --text) FORMAT="text"; shift ;;
    --jq) JQ_EXPR="$2"; shift 2 ;;
    --max-events) MAX_EVENTS="$2"; shift 2 ;;
    --stack-depth) STACK_DEPTH="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
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

# No --events: list event types from metadata
if [[ -z "$EVENTS" ]]; then
  echo "=== distinct event types in $JFR_FILE ==="
  run_with_timeout jfr metadata "$JFR_FILE" 2>&1 \
    | grep -oE 'name="[a-zA-Z0-9._]+"' \
    | sort -u \
    | sed 's/name="//; s/"//'
  exit 0
fi

# Big-volume guardrail
if [[ "$EVENTS" == *"ExecutionSample"* && "$MAX_EVENTS" -lt 50 ]]; then
  :  # explicit cap already in place
fi

TMP=$(mktemp -t jfr-events-XXXXXX.txt)
trap 'rm -f "$TMP"' EXIT

if [[ "$FORMAT" == "json" ]]; then
  command -v jq >/dev/null 2>&1 || { err "jq not found on PATH"; exit 2; }
  [[ -z "$JQ_EXPR" ]] && JQ_EXPR='.recording.events[] | {type, startTime, duration, thread: (.thread.name // .sampledThread.javaName // null)}'
  # Pipe jfr json -> jq with hard cap via head on the projected lines
  run_with_timeout jfr print --json --stack-depth "$STACK_DEPTH" --events "$EVENTS" "$JFR_FILE" 2>/dev/null \
    | jq -c "$JQ_EXPR" 2>"${TMP}.err" \
    | head -n "$MAX_EVENTS" > "$TMP" || true
  if [[ -s "${TMP}.err" ]]; then
    err "jq filter failed:"
    cat "${TMP}.err" >&2
    exit 3
  fi
else
  run_with_timeout jfr print --stack-depth "$STACK_DEPTH" --events "$EVENTS" "$JFR_FILE" 2>&1 \
    | head -n "$((MAX_EVENTS * 8))" > "$TMP" || true
fi

LINE_COUNT=$(wc -l < "$TMP" | tr -d ' ')

if [[ "$LINE_COUNT" == "0" ]]; then
  echo "no events matched $EVENTS in $JFR_FILE"
  exit 0
fi

if [[ -n "$OUTPUT" ]]; then
  cp "$TMP" "$OUTPUT"
  printf 'wrote %s lines (cap %s events) to %s\n' "$LINE_COUNT" "$MAX_EVENTS" "$OUTPUT"
elif (( LINE_COUNT > MAX_LINES )); then
  SPILL="/tmp/jfr-events-$(date +%Y%m%d-%H%M%S).${FORMAT}"
  cp "$TMP" "$SPILL"
  head -100 "$TMP"
  printf '\n... [%s lines omitted, full output at %s] ...\n' "$((LINE_COUNT - 100))" "$SPILL"
else
  cat "$TMP"
fi
