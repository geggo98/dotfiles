#!/usr/bin/env bash
# jmx.sh — jmxterm wrapper with subcommands (domains | list | attr | invoke)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: jmx.sh <subcommand> [options]

Wrap jmxterm in non-interactive mode (-n -i -) for token-conservative JMX queries.
If jmxterm is not on PATH, falls back to `nix run nixpkgs#jmxterm --`.

Subcommands:
  domains [options]                                     List MBean domains
  list --domain D [--filter PAT] [options]              List MBean ObjectNames in a domain
  attr <objectname-or-glob> <attr-or-csv> [options]     Read attribute(s)
  invoke <objectname> <op> [arg ...] [options]          Invoke an MBean operation

Common options:
  --host HOST         Target host (default: localhost)
  --port PORT         JMX/RMI port (default: 5000)
  --user USER         JMX username (overrides JMX_USER env / credentials file)
  --password PASS     JMX password (DISCOURAGED — leaks via ps. Use --password-cmd.)
  --password-cmd CMD  Run CMD; stdout is the password
  --timeout SECS      Hard timeout for the jmxterm call (default: 30)
  --max-rows N        Spill output to /tmp if exceeded (default: 200)
  --output FILE       Force write full output to FILE
  --verbose           Log resolved command and binary to stderr (no secret values)
  -h, --help          Show this help

Authentication resolution (first hit wins):
  1. --user/--password / --password-cmd
  2. ENV: JMX_USER, JMX_PASSWORD, JMX_PASSWORD_CMD
  3. File: $JMX_CREDENTIALS or ~/.config/java-debug/jmx-credentials (mode 0600),
     INI sections keyed by host:port
  4. None (anonymous open)

Exit codes:
  0 ok | 1 usage error | 2 jmxterm AND nix both missing | 3 jmxterm failed | 4 auth failure

Examples:
  jmx.sh domains --port 5000
  jmx.sh list --domain Catalina --port 5000
  jmx.sh attr --port 5000 'java.lang:type=Memory' HeapMemoryUsage
  jmx.sh attr --port 5000 'Catalina:type=Connector,port=*' localPort
  jmx.sh invoke --port 5000 'java.lang:type=Memory' gc
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }
log()  { (( VERBOSE )) && printf '[jmx.sh] %s\n' "$*" >&2 || true; }

SUBCMD="${1:-}"
[[ -z "$SUBCMD" || "$SUBCMD" == "-h" || "$SUBCMD" == "--help" ]] && { usage; exit 0; }
shift || true

HOST=localhost
PORT=5000
DOMAIN=""
FILTER=""
USER_FLAG=""
PASS_FLAG=""
PASS_CMD=""
TIMEOUT=30
MAX_ROWS=200
OUTPUT=""
VERBOSE=0
positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --filter) FILTER="$2"; shift 2 ;;
    --user) USER_FLAG="$2"; shift 2 ;;
    --password) PASS_FLAG="$2"; shift 2 ;;
    --password-cmd) PASS_CMD="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --max-rows) MAX_ROWS="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
    -*) err "unknown option: $1"; usage; exit 1 ;;
    *)  positional+=("$1"); shift ;;
  esac
done

# ---- Auth resolution ----
resolve_auth() {
  local user="" pass=""
  # 1. CLI flags
  if [[ -n "$USER_FLAG" ]]; then user="$USER_FLAG"; fi
  if [[ -n "$PASS_FLAG" ]]; then pass="$PASS_FLAG"; AUTH_SRC="--password flag"
  elif [[ -n "$PASS_CMD" ]]; then
    pass=$(/bin/sh -c "$PASS_CMD" 2>/dev/null) || { err "auth: --password-cmd failed: $PASS_CMD"; exit 4; }
    AUTH_SRC="--password-cmd flag"
  fi
  # 2. ENV vars
  if [[ -z "$user" && -n "${JMX_USER:-}" ]]; then user="$JMX_USER"; fi
  if [[ -z "$pass" ]]; then
    if [[ -n "${JMX_PASSWORD:-}" ]]; then pass="$JMX_PASSWORD"; AUTH_SRC="JMX_PASSWORD env"
    elif [[ -n "${JMX_PASSWORD_CMD:-}" ]]; then
      pass=$(/bin/sh -c "$JMX_PASSWORD_CMD" 2>/dev/null) || { err "auth: JMX_PASSWORD_CMD failed"; exit 4; }
      AUTH_SRC="JMX_PASSWORD_CMD env"
    fi
  fi
  # 3. Credentials file
  local cred_file="${JMX_CREDENTIALS:-${XDG_CONFIG_HOME:-$HOME/.config}/java-debug/jmx-credentials}"
  if [[ -z "$user$pass" && -f "$cred_file" ]]; then
    local mode
    mode=$(stat -f '%Lp' "$cred_file" 2>/dev/null || stat -c '%a' "$cred_file" 2>/dev/null || echo "")
    if [[ "$mode" != "600" && "$mode" != "0600" ]]; then
      err "refusing to read JMX credentials with mode $mode; chmod 600 $cred_file"
    else
      local key="$HOST:$PORT"
      local in_section=0 cu="" cp="" cpc=""
      while IFS= read -r line; do
        line="${line%%#*}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
          [[ "${BASH_REMATCH[1]}" == "$key" ]] && in_section=1 || in_section=0
        elif (( in_section )) && [[ "$line" =~ ^([a-z-]+)\ *=\ *(.+)$ ]]; then
          case "${BASH_REMATCH[1]}" in
            user) cu="${BASH_REMATCH[2]}" ;;
            password) cp="${BASH_REMATCH[2]}" ;;
            password-cmd) cpc="${BASH_REMATCH[2]}" ;;
          esac
        fi
      done < "$cred_file"
      [[ -z "$user" && -n "$cu" ]] && user="$cu"
      if [[ -z "$pass" ]]; then
        if [[ -n "$cp" ]]; then pass="$cp"; AUTH_SRC="credentials file [$key]"
        elif [[ -n "$cpc" ]]; then
          pass=$(/bin/sh -c "$cpc" 2>/dev/null) || { err "auth: credentials file password-cmd failed"; exit 4; }
          AUTH_SRC="credentials file [$key] password-cmd"
        fi
      fi
    fi
  fi
  RESOLVED_USER="$user"
  RESOLVED_PASS="$pass"
}

AUTH_SRC="none"
RESOLVED_USER=""
RESOLVED_PASS=""
resolve_auth

if [[ -n "$RESOLVED_USER$RESOLVED_PASS" ]]; then
  log "auth: using $AUTH_SRC"
else
  log "auth: none (anonymous open)"
fi

# ---- Resolve jmxterm binary ----
JMX_BIN=""
if command -v jmxterm >/dev/null 2>&1; then
  JMX_BIN="jmxterm"
elif command -v nix >/dev/null 2>&1; then
  JMX_BIN="nix run nixpkgs#jmxterm --"
  log "jmxterm not on PATH; falling back to: $JMX_BIN"
else
  err "neither jmxterm nor nix is on PATH. Install jmxterm or use the nix-shell skill."
  exit 2
fi
log "using $JMX_BIN"

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$TIMEOUT" "$@"
  else "$@"
  fi
}

# ---- Build the open-line ----
if [[ -n "$RESOLVED_USER" || -n "$RESOLVED_PASS" ]]; then
  OPEN_LINE="open $HOST:$PORT -u $RESOLVED_USER -p $RESOLVED_PASS"
else
  OPEN_LINE="open $HOST:$PORT"
fi

# ---- Build the per-subcommand jmxterm script ----
make_script() {
  printf '%s\n' "$OPEN_LINE"
  case "$SUBCMD" in
    domains)
      printf 'domains\n'
      ;;
    list)
      [[ -z "$DOMAIN" ]] && { err "list: --domain DOMAIN is required"; exit 1; }
      printf 'beans -d %q\n' "$DOMAIN"
      ;;
    attr)
      (( ${#positional[@]} >= 2 )) || { err "attr: ObjectName and attribute(s) required"; exit 1; }
      local on="${positional[0]}"
      local attrs="${positional[1]}"
      # jmxterm `get` accepts one attribute at a time; iterate over CSV
      printf 'bean %q\n' "$on"
      IFS=',' read -r -a alist <<< "$attrs"
      for a in "${alist[@]}"; do
        a="${a##[[:space:]]}"; a="${a%%[[:space:]]}"
        printf 'get %s\n' "$a"
      done
      ;;
    invoke)
      (( ${#positional[@]} >= 2 )) || { err "invoke: ObjectName and operation required"; exit 1; }
      local on="${positional[0]}"
      local op="${positional[1]}"
      local args=("${positional[@]:2}")
      printf 'bean %q\n' "$on"
      if (( ${#args[@]} > 0 )); then
        printf 'run %s' "$op"
        for a in "${args[@]}"; do printf ' %q' "$a"; done
        printf '\n'
      else
        printf 'run %s\n' "$op"
      fi
      ;;
    *)
      err "unknown subcommand: $SUBCMD"; usage; exit 1 ;;
  esac
  printf 'close\nexit\n'
}

TMP=$(mktemp -t jmx-out-XXXXXX.txt)
trap 'rm -f "$TMP"' EXIT

if ! run_with_timeout sh -c "$JMX_BIN -n -i -" <<< "$(make_script)" > "$TMP" 2>&1; then
  rc=$?
  err "jmxterm failed (rc=$rc). Last 5 lines:"
  tail -5 "$TMP" >&2
  exit 3
fi

# Filter list output if --filter is set
if [[ "$SUBCMD" == "list" && -n "$FILTER" ]]; then
  # Convert shell-style glob to extended regex (very simple: * -> .*)
  local_pat=$(printf '%s' "$FILTER" | sed 's/[.]/\\./g; s/[*]/.*/g')
  awk -v p="^${local_pat}\$" 'BEGIN{IGNORECASE=1} $0 ~ p || $0 !~ /^[a-zA-Z0-9._]+:.*/' "$TMP" > "${TMP}.f"
  mv "${TMP}.f" "$TMP"
fi

LINES=$(wc -l < "$TMP" | tr -d ' ')

if [[ -n "$OUTPUT" ]]; then
  cp "$TMP" "$OUTPUT"
  printf 'wrote %s lines to %s\n' "$LINES" "$OUTPUT"
elif (( LINES > MAX_ROWS )); then
  SPILL="/tmp/jmx-${SUBCMD}-$(date +%Y%m%d-%H%M%S).txt"
  cp "$TMP" "$SPILL"
  head -100 "$TMP"
  printf '\n... [%s lines omitted, full output at %s] ...\n\n' "$((LINES - 120))" "$SPILL"
  tail -20 "$TMP"
else
  cat "$TMP"
fi
