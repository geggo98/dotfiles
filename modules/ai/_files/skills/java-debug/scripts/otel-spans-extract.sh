#!/usr/bin/env bash
# otel-spans-extract.sh — Resource-context-aware extraction of spans from OTLP JSONL
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: otel-spans-extract.sh <traces.jsonl> [options]

Extract spans from an OTLP-JSON-Lines file written by the fileexporter.
The default projection includes service.name (from the parent resourceSpans
block) plus name, traceId, spanId, parentSpanId, durationMs — a common pitfall
of naive `.spans[]` extraction is losing the resource context, so this script
handles that correctly.

Options:
  --service NAME        Filter by service.name (exact match)
  --name PATTERN        Filter by span name (substring, case-insensitive)
  --trace-id ID         Filter by traceId (exact match)
  --min-duration MS     Keep only spans with durationMs >= this value
  --max-spans N         Hard cap on emitted spans (default: 200)
  --full                Emit raw OTLP JSON for matching spans (no projection)
  --output FILE         Force write full output to FILE
  --max-lines N         Spill to file if output exceeds N lines (default: 500)
  -h, --help            Show this help

Exit codes:
  0 ok | 1 usage error | 2 missing jq | 3 jq filter failed

Examples:
  # All spans projected to one JSON object per line
  otel-spans-extract.sh /tmp/traces.jsonl

  # Slow spans (>= 100ms) in service-a
  otel-spans-extract.sh /tmp/traces.jsonl --service service-a --min-duration 100

  # Full end-to-end trace, sorted by start time
  otel-spans-extract.sh /tmp/traces.jsonl --trace-id 4bf92f3577b34da6a3ce929d0e0e4736
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

JSONL=""
FILTER_SERVICE=""
FILTER_NAME=""
FILTER_TRACE_ID=""
MIN_DURATION=""
MAX_SPANS=200
FULL=0
OUTPUT=""
MAX_LINES=500

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --service) FILTER_SERVICE="$2"; shift 2 ;;
    --name) FILTER_NAME="$2"; shift 2 ;;
    --trace-id) FILTER_TRACE_ID="$2"; shift 2 ;;
    --min-duration) MIN_DURATION="$2"; shift 2 ;;
    --max-spans) MAX_SPANS="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
    -*) err "unknown option: $1"; exit 1 ;;
    *) JSONL="$1"; shift ;;
  esac
done

[[ -z "$JSONL" ]] && { err "traces.jsonl path required"; usage; exit 1; }
[[ -f "$JSONL" ]] || { err "no such file: $JSONL"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "jq not found on PATH"; exit 2; }

# Build the jq pipeline. Each input line is one OTLP ExportTraceServiceRequest batch
# containing one or more resourceSpans, each with its own resource attributes.
# We extract spans while preserving the service.name from the enclosing resource block.

JQ_FILTERS=""
[[ -n "$FILTER_SERVICE" ]]    && JQ_FILTERS+=" | select(.service == \"$FILTER_SERVICE\")"
[[ -n "$FILTER_NAME" ]]       && JQ_FILTERS+=" | select(.name | test(\"$FILTER_NAME\"; \"i\"))"
[[ -n "$FILTER_TRACE_ID" ]]   && JQ_FILTERS+=" | select(.traceId == \"$FILTER_TRACE_ID\")"
[[ -n "$MIN_DURATION" ]]      && JQ_FILTERS+=" | select(.durationMs >= $MIN_DURATION)"

if (( FULL )); then
  JQ_EXPR='
    .resourceSpans[] as $rs
    | ($rs.resource.attributes[] | select(.key=="service.name") | .value.stringValue) as $svc
    | $rs.scopeSpans[].spans[]
    | (. + {_service: $svc})
  '
  # For --full, filtering on the projected fields uses different keys
  JQ_FILTERS=""
  [[ -n "$FILTER_SERVICE" ]]  && JQ_FILTERS+=" | select(._service == \"$FILTER_SERVICE\")"
  [[ -n "$FILTER_NAME" ]]     && JQ_FILTERS+=" | select(.name | test(\"$FILTER_NAME\"; \"i\"))"
  [[ -n "$FILTER_TRACE_ID" ]] && JQ_FILTERS+=" | select(.traceId == \"$FILTER_TRACE_ID\")"
else
  JQ_EXPR='
    .resourceSpans[] as $rs
    | ($rs.resource.attributes[] | select(.key=="service.name") | .value.stringValue) as $svc
    | $rs.scopeSpans[].spans[]
    | {
        service: $svc,
        name,
        traceId,
        spanId,
        parentSpanId: (.parentSpanId // null),
        startTimeUnixNano,
        durationMs: (((.endTimeUnixNano | tonumber) - (.startTimeUnixNano | tonumber)) / 1000000.0),
        kind: (.kind // null),
        status: (.status.code // null)
      }
  '
fi

TMP=$(mktemp -t otel-spans-XXXXXX.txt)
trap 'rm -f "$TMP"' EXIT

if ! jq -c "$JQ_EXPR $JQ_FILTERS" "$JSONL" 2>"${TMP}.err" \
     | head -n "$MAX_SPANS" > "$TMP"; then
  err "jq filter failed:"
  cat "${TMP}.err" >&2
  exit 3
fi

LINE_COUNT=$(wc -l < "$TMP" | tr -d ' ')

if [[ "$LINE_COUNT" == "0" ]]; then
  echo "no spans matched filters in $JSONL"
  exit 0
fi

if [[ -n "$OUTPUT" ]]; then
  cp "$TMP" "$OUTPUT"
  printf 'wrote %s spans (cap %s) to %s\n' "$LINE_COUNT" "$MAX_SPANS" "$OUTPUT"
elif (( LINE_COUNT > MAX_LINES )); then
  SPILL="/tmp/otel-spans-$(date +%Y%m%d-%H%M%S).jsonl"
  cp "$TMP" "$SPILL"
  head -100 "$TMP"
  printf '\n... [%s spans omitted, full output at %s] ...\n' "$((LINE_COUNT - 100))" "$SPILL"
else
  cat "$TMP"
fi
