#!/usr/bin/env bash
# otel-collector-up.sh — Start a local OTel collector with default fileexporter config
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: otel-collector-up.sh [options]

Start `otelcol-contrib` with a default config that accepts OTLP traces (gRPC 4317
and HTTP 4318) and writes them as JSONL to a local file via the fileexporter.

If otelcol-contrib isn't on PATH, falls back to:
  nix run nixpkgs#opentelemetry-collector-contrib -- --config <generated>

Options:
  --config PATH         Use an existing collector config (skip default generation)
  --output PATH         Where the fileexporter writes traces (default: /tmp/otel-traces-<ts>.jsonl)
  --port N              OTLP gRPC port (default: 4317)
  --http-port N         OTLP HTTP port (default: 4318)
  --background          Run in background; write PID to /tmp/otel-collector-<ts>.pid
                        and logs to /tmp/otel-collector-<ts>.log. Print both paths.
  --timeout SECS        Auto-stop after SECS seconds (default: 0 = run until killed)
  --print-config        Generate the default config, print it, and exit (no start)
  -h, --help            Show this help

Exit codes:
  0 ok | 1 usage error | 2 missing otelcol-contrib AND nix | 3 collector failed

Examples:
  # Foreground, default config -> /tmp/otel-traces-<ts>.jsonl
  otel-collector-up.sh

  # Background, custom output, 60s lifetime
  otel-collector-up.sh --background --output /tmp/myrun.jsonl --timeout 60

  # Generate config but don't start
  otel-collector-up.sh --print-config > my-otel-config.yaml
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

CONFIG=""
OUTPUT="/tmp/otel-traces-$(date +%Y%m%d-%H%M%S).jsonl"
GRPC_PORT=4317
HTTP_PORT=4318
BACKGROUND=0
TIMEOUT=0
PRINT_CONFIG_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --port) GRPC_PORT="$2"; shift 2 ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --background) BACKGROUND=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --print-config) PRINT_CONFIG_ONLY=1; shift ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
done

# Port-collision check
check_port_free() {
  local port="$1" label="$2"
  if command -v lsof >/dev/null 2>&1; then
    if lsof -i ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
      err "port $port ($label) is already in use"
      lsof -i ":$port" -sTCP:LISTEN >&2 || true
      exit 1
    fi
  fi
}

generate_default_config() {
  cat <<EOM
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:${GRPC_PORT}
      http:
        endpoint: 0.0.0.0:${HTTP_PORT}

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024

exporters:
  file:
    path: ${OUTPUT}
    format: json
    flush_interval: 1s
    rotation:
      max_megabytes: 100
      max_backups: 5
      localtime: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [file]
  telemetry:
    logs:
      level: warn
EOM
}

if (( PRINT_CONFIG_ONLY )); then
  generate_default_config
  exit 0
fi

# Generate config if user didn't provide one
GENERATED_CONFIG=""
if [[ -z "$CONFIG" ]]; then
  GENERATED_CONFIG=$(mktemp -t otel-collector-config-XXXXXX.yaml)
  generate_default_config > "$GENERATED_CONFIG"
  CONFIG="$GENERATED_CONFIG"
  printf 'generated default config at %s\n' "$CONFIG" >&2
fi

# Resolve binary
COLLECTOR_BIN=""
if command -v otelcol-contrib >/dev/null 2>&1; then
  COLLECTOR_BIN="otelcol-contrib"
elif command -v nix >/dev/null 2>&1; then
  printf 'otelcol-contrib not on PATH; falling back to `nix run nixpkgs#opentelemetry-collector-contrib`\n' >&2
  COLLECTOR_BIN="nix run nixpkgs#opentelemetry-collector-contrib --"
else
  err "neither otelcol-contrib nor nix is on PATH (install opentelemetry-collector-contrib or use the nix-shell skill)"
  exit 2
fi

check_port_free "$GRPC_PORT" "OTLP gRPC"
check_port_free "$HTTP_PORT" "OTLP HTTP"

mkdir -p "$(dirname "$OUTPUT")"
TS=$(date +%Y%m%d-%H%M%S)
PIDFILE="/tmp/otel-collector-${TS}.pid"
LOGFILE="/tmp/otel-collector-${TS}.log"

printf '=== starting OTel collector ===\n' >&2
printf 'gRPC : 0.0.0.0:%s\n' "$GRPC_PORT" >&2
printf 'HTTP : 0.0.0.0:%s\n' "$HTTP_PORT" >&2
printf 'file : %s\n' "$OUTPUT" >&2

run_collector() {
  # shellcheck disable=SC2086
  $COLLECTOR_BIN --config "$CONFIG"
}

if (( BACKGROUND )); then
  ( run_collector ) > "$LOGFILE" 2>&1 &
  COL_PID=$!
  echo "$COL_PID" > "$PIDFILE"
  printf 'pid  : %s (written to %s)\n' "$COL_PID" "$PIDFILE" >&2
  printf 'log  : %s\n' "$LOGFILE" >&2
  if (( TIMEOUT > 0 )); then
    ( sleep "$TIMEOUT" && kill -TERM "$COL_PID" 2>/dev/null && printf 'auto-stopped collector PID %s after %ss\n' "$COL_PID" "$TIMEOUT" >&2 ) &
  fi
  printf '%s\n' "$OUTPUT"   # canonical stdout: the traces file path
else
  if (( TIMEOUT > 0 )); then
    if command -v timeout >/dev/null 2>&1; then
      timeout "$TIMEOUT" bash -c "$COLLECTOR_BIN --config \"$CONFIG\"" || true
    elif command -v gtimeout >/dev/null 2>&1; then
      gtimeout "$TIMEOUT" bash -c "$COLLECTOR_BIN --config \"$CONFIG\"" || true
    else
      run_collector
    fi
  else
    run_collector
  fi
fi
