#!/usr/bin/env bash
# jfr-view.sh — Run a predefined `jfr view` report against a recording, with caps
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: jfr-view.sh <view-name> <recording.jfr> [options]
       jfr-view.sh --list-views

Wrap `jfr view --width <W> <view> <file>` with a fixed-width default and output caps
so the agent can consume tabular reports in a single bite.

Arguments:
  <view-name>       e.g. hot-methods, gc, allocation-by-class, contention-by-thread,
                    file-io, socket-io, thread-cpu-load, jvm-information,
                    heap-statistics, exception-by-type — see --list-views
  <recording.jfr>   Path to the .jfr file

Options:
  --width N         Column width passed to `jfr view --width` (default: 200)
  --grep PATTERN    Case-insensitive filter on output lines (after view rendering)
  --head N          Print only first N lines (default: 200)
  --max-lines N     Spill to file if output exceeds N lines (default: 500)
  --output FILE     Force write full output to FILE
  --timeout SECS    jfr CLI timeout (default: 60)
  --list-views      Print available view names (calls `jfr view --help`) and exit
  -h, --help        Show this help

Exit codes:
  0 ok | 1 usage error | 2 missing jfr | 3 jfr failed

Examples:
  jfr-view.sh hot-methods /tmp/myapp.jfr
  jfr-view.sh allocation-by-class /tmp/myapp.jfr --grep com.example
  jfr-view.sh gc /tmp/myapp.jfr --width 240 --head 50
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

VIEW=""
JFR_FILE=""
WIDTH=200
GREP_PATTERN=""
HEAD_N=200
MAX_LINES=500
OUTPUT=""
TIMEOUT=60
LIST_VIEWS=0
positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-views) LIST_VIEWS=1; shift ;;
    --width) WIDTH="$2"; shift 2 ;;
    --grep) GREP_PATTERN="$2"; shift 2 ;;
    --head) HEAD_N="$2"; shift 2 ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -*) err "unknown option: $1"; exit 1 ;;
    *) positional+=("$1"); shift ;;
  esac
done

command -v jfr >/dev/null 2>&1 || { err "jfr not found on PATH (need JDK 21+ for views)"; exit 2; }

if (( LIST_VIEWS )); then
  jfr view --help 2>&1 || true
  exit 0
fi

(( ${#positional[@]} >= 2 )) || { err "view-name and recording path required"; usage; exit 1; }
VIEW="${positional[0]}"
JFR_FILE="${positional[1]}"
[[ -f "$JFR_FILE" ]] || { err "no such file: $JFR_FILE"; exit 1; }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$TIMEOUT" "$@"
  else "$@"
  fi
}

TMP=$(mktemp -t jfr-view-XXXXXX.txt)
trap 'rm -f "$TMP"' EXIT

if ! run_with_timeout jfr view --width "$WIDTH" "$VIEW" "$JFR_FILE" > "$TMP" 2>&1; then
  err "jfr view failed (view=$VIEW). Try --list-views to see available report names."
  tail -5 "$TMP" >&2
  exit 3
fi

if [[ -n "$GREP_PATTERN" ]]; then
  # Keep header (first ~5 lines) regardless of pattern match
  { head -5 "$TMP"; grep -i -- "$GREP_PATTERN" "$TMP" || true; } > "${TMP}.filtered"
  mv "${TMP}.filtered" "$TMP"
fi

LINE_COUNT=$(wc -l < "$TMP" | tr -d ' ')

emit() {
  if (( LINE_COUNT > HEAD_N )); then
    head -"$HEAD_N" "$TMP"
    printf '\n... [%s lines omitted; use --head N or --output FILE for more] ...\n' "$((LINE_COUNT - HEAD_N))"
  else
    cat "$TMP"
  fi
}

if [[ -n "$OUTPUT" ]]; then
  cp "$TMP" "$OUTPUT"
  printf 'wrote %s lines to %s\n' "$LINE_COUNT" "$OUTPUT"
elif (( LINE_COUNT > MAX_LINES )); then
  SPILL="/tmp/jfr-view-${VIEW}-$(date +%Y%m%d-%H%M%S).txt"
  cp "$TMP" "$SPILL"
  head -100 "$TMP"
  printf '\n... [%s lines omitted, full output at %s] ...\n\n' "$((LINE_COUNT - 120))" "$SPILL"
  tail -20 "$TMP"
else
  emit
fi
