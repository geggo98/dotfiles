#!/usr/bin/env bash
# jfr-record.sh — Control Java Flight Recorder recordings on running or new JVMs
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: jfr-record.sh <subcommand> [options]

Control JFR recordings on a running JVM via `jcmd`, or emit the JVM flag string
for starting a recording at JVM startup.

Subcommands:
  start    --pid PID | --match REGEX [--name N] [--settings S] [--duration D] [--filename F]
  status   --pid PID [--name N]
  dump     --pid PID --filename F [--name N]
  stop     --pid PID [--name N] [--filename F]
  startup  --filename F [--settings S] [--duration D] [--continuous] [--print-args-only]

Common options:
  --pid PID            Target JVM process ID
  --match REGEX        Resolve PID via `jcmd -l | grep -E REGEX | head -1`
  --name N             Recording name (default: "adhoc")
  --settings S         "default" | "profile" | path to custom .jfc (default: "profile")
  --duration D         e.g. "60s", "5m" (default: "60s"; omit for unbounded)
  --filename F         Output .jfr file path
  --continuous         (startup only) Production ringbuffer preset:
                       settings=default,disk=true,maxage=1h,maxsize=500m,dumponexit=true
  --print-args-only    (startup only) Only emit the -XX flag string, no header text
  --timeout SECS       Hard timeout for the jcmd call (default: 30)
  -h, --help           Show this help

Exit codes:
  0 ok | 1 usage error | 2 missing jcmd | 3 jcmd failed

Examples:
  # Start a 60s profile recording on a Spring Boot app whose cmdline contains "myapp.jar"
  jfr-record.sh start --match 'myapp\.jar' --filename /tmp/myapp.jfr

  # Check status by PID
  jfr-record.sh status --pid 12345

  # Dump in-flight recording, keep recording running
  jfr-record.sh dump --pid 12345 --name adhoc --filename /tmp/snapshot.jfr

  # Stop and write final recording
  jfr-record.sh stop --pid 12345 --name adhoc --filename /tmp/final.jfr

  # Emit JVM flag for production continuous recording
  jfr-record.sh startup --filename /var/log/app/rec.jfr --continuous --print-args-only
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

# ---- parse args ----
SUBCMD="${1:-}"
[[ -z "$SUBCMD" || "$SUBCMD" == "-h" || "$SUBCMD" == "--help" ]] && { usage; exit 0; }
shift || true

PID=""
MATCH=""
NAME="adhoc"
SETTINGS="profile"
DURATION="60s"
FILENAME=""
CONTINUOUS=0
PRINT_ARGS_ONLY=0
TIMEOUT=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pid) PID="$2"; shift 2 ;;
    --match) MATCH="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --filename) FILENAME="$2"; shift 2 ;;
    --continuous) CONTINUOUS=1; shift ;;
    --print-args-only) PRINT_ARGS_ONLY=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
done

# ---- helpers ----
require_jcmd() {
  command -v jcmd >/dev/null 2>&1 || { err "jcmd not found on PATH (need JDK 11+)"; exit 2; }
}

resolve_pid() {
  if [[ -n "$PID" ]]; then return; fi
  [[ -z "$MATCH" ]] && { err "either --pid or --match is required"; exit 1; }
  require_jcmd
  local matches
  matches=$(jcmd -l 2>/dev/null | grep -E "$MATCH" || true)
  local count
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if (( count == 0 )); then
    err "no JVM matches /$MATCH/. Available: $(jcmd -l 2>/dev/null | wc -l) JVM(s). Try: jcmd -l"
    exit 1
  elif (( count > 1 )); then
    err "multiple JVMs match /$MATCH/ — disambiguate via --pid. Matches:"
    printf '%s\n' "$matches" >&2
    exit 1
  fi
  PID=$(printf '%s\n' "$matches" | awk '{print $1}')
  printf 'resolved --match %q -> PID %s\n' "$MATCH" "$PID" >&2
}

run_jcmd() {
  local cmd=(jcmd "$PID" "$@")
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "${cmd[@]}"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT" "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

# ---- subcommands ----
case "$SUBCMD" in
  start)
    require_jcmd; resolve_pid
    [[ -z "$FILENAME" ]] && FILENAME="/tmp/jfr-${NAME}-$(date +%Y%m%d-%H%M%S).jfr"
    args=("JFR.start" "name=$NAME" "settings=$SETTINGS")
    [[ -n "$DURATION" ]] && args+=("duration=$DURATION")
    args+=("filename=$FILENAME")
    printf '=== JFR.start name=%s settings=%s duration=%s filename=%s on PID %s ===\n' \
      "$NAME" "$SETTINGS" "${DURATION:-<unbounded>}" "$FILENAME" "$PID"
    run_jcmd "${args[@]}" || { err "jcmd JFR.start failed"; exit 3; }
    ;;
  status)
    require_jcmd; resolve_pid
    args=("JFR.check")
    [[ -n "$NAME" && "$NAME" != "adhoc" ]] && args+=("name=$NAME")
    run_jcmd "${args[@]}" || { err "jcmd JFR.check failed"; exit 3; }
    ;;
  dump)
    require_jcmd; resolve_pid
    [[ -z "$FILENAME" ]] && { err "--filename is required for dump"; exit 1; }
    run_jcmd "JFR.dump" "name=$NAME" "filename=$FILENAME" || { err "jcmd JFR.dump failed"; exit 3; }
    printf 'dumped to %s\n' "$FILENAME"
    ;;
  stop)
    require_jcmd; resolve_pid
    args=("JFR.stop" "name=$NAME")
    [[ -n "$FILENAME" ]] && args+=("filename=$FILENAME")
    run_jcmd "${args[@]}" || { err "jcmd JFR.stop failed"; exit 3; }
    [[ -n "$FILENAME" ]] && printf 'final recording at %s\n' "$FILENAME"
    ;;
  startup)
    [[ -z "$FILENAME" ]] && { err "--filename is required for startup"; exit 1; }
    if (( CONTINUOUS )); then
      flag="-XX:StartFlightRecording=settings=default,disk=true,maxage=1h,maxsize=500m,dumponexit=true,filename=$FILENAME"
    else
      flag="-XX:StartFlightRecording=name=$NAME,settings=$SETTINGS,duration=$DURATION,filename=$FILENAME,dumponexit=true"
    fi
    extra="-XX:FlightRecorderOptions=stackdepth=128"
    if (( PRINT_ARGS_ONLY )); then
      printf '%s %s\n' "$flag" "$extra"
    else
      cat <<EOM
=== JVM startup flags for JFR ===
Add these to your JAVA_TOOL_OPTIONS / build file / Dockerfile:

  $flag
  $extra

stackdepth=128 is set because Spring stacks are deeper than the default 64 — without
it, jfr view hot-methods aggregates are useless. Override via --print-args-only if you
want to compose your own.
EOM
    fi
    ;;
  *)
    err "unknown subcommand: $SUBCMD"
    usage; exit 1 ;;
esac
