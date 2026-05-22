#!/usr/bin/env bash
# jmx-startup.sh — Emit JVM JMX flags for embedding in JAVA_TOOL_OPTIONS / build files
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: jmx-startup.sh [options]

Emit the JVM JMX remote-management flags. By default, uses the single-port pattern
(RMI registry == RMI server == --port) with no authentication and no SSL — fine
for local dev, dangerous in production. See --auth and --ssl for production knobs.

Options:
  --port N            JMX/RMI port (default: 5000). Uses single-port pattern
                      (com.sun.management.jmxremote.port == .rmi.port).
  --hostname HOST     java.rmi.server.hostname — what the RMI server reports back
                      to clients. Defaults to 127.0.0.1 for dev safety.
                      Set to the external IP for containers (see references/jmx.md §6).
  --auth              Require authentication. Reads JMX_PASSWORD_FILE env var
                      (path to a JDK-format password file, mode 0400/0600).
                      Optionally also JMX_ACCESS_FILE for readonly/readwrite.
  --ssl               Require SSL. RMI keystore/truststore must be configured
                      via JSSE properties separately.
  --print-args-only   Emit only the flag string, no banner. Suitable for shell
                      composition: JAVA_TOOL_OPTIONS="$(jmx-startup.sh --print-args-only)"
  -h, --help          Show this help

Exit codes:
  0 ok | 1 usage error / missing JMX_PASSWORD_FILE under --auth

Examples:
  # Local dev — single port, no auth, localhost-only
  jmx-startup.sh --port 5000 --print-args-only

  # Container with port-forward — bind to 127.0.0.1 (kubectl port-forward case)
  jmx-startup.sh --port 5000 --hostname 127.0.0.1 --print-args-only

  # Container with direct external access — hostname must match what the client uses
  jmx-startup.sh --port 5000 --hostname myhost.example.com --print-args-only
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

PORT=5000
HOSTNAME=127.0.0.1
AUTH=0
SSL=0
PRINT_ARGS_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --port) PORT="$2"; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --auth) AUTH=1; shift ;;
    --ssl) SSL=1; shift ;;
    --print-args-only) PRINT_ARGS_ONLY=1; shift ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
done

# Warn on 0.0.0.0 — common footgun
HOSTNAME_WARNING=""
if [[ "$HOSTNAME" == "0.0.0.0" ]]; then
  HOSTNAME_WARNING="WARNING: java.rmi.server.hostname=0.0.0.0 makes the RMI server tell clients to call back to 0.0.0.0, which breaks JMX from any non-local client. Set this to the externally-reachable hostname/IP instead."
fi

flags=(
  "-Dcom.sun.management.jmxremote=true"
  "-Dcom.sun.management.jmxremote.port=$PORT"
  "-Dcom.sun.management.jmxremote.rmi.port=$PORT"
  "-Djava.rmi.server.hostname=$HOSTNAME"
)

if (( AUTH )); then
  : "${JMX_PASSWORD_FILE:?--auth requires JMX_PASSWORD_FILE env var (path to a JDK-format password file)}"
  flags+=("-Dcom.sun.management.jmxremote.authenticate=true")
  flags+=("-Dcom.sun.management.jmxremote.password.file=$JMX_PASSWORD_FILE")
  if [[ -n "${JMX_ACCESS_FILE:-}" ]]; then
    flags+=("-Dcom.sun.management.jmxremote.access.file=$JMX_ACCESS_FILE")
  fi
else
  flags+=("-Dcom.sun.management.jmxremote.authenticate=false")
fi

if (( SSL )); then
  flags+=("-Dcom.sun.management.jmxremote.ssl=true")
else
  flags+=("-Dcom.sun.management.jmxremote.ssl=false")
fi

if (( PRINT_ARGS_ONLY )); then
  printf '%s ' "${flags[@]}"
  printf '\n'
else
  cat <<EOM
=== JVM startup flags for JMX ===
Add these to JAVA_TOOL_OPTIONS / your build file / Dockerfile / Spring bootRun jvmArgs:

EOM
  for f in "${flags[@]}"; do
    printf '  %s\n' "$f"
  done
  cat <<EOM

Single-port pattern: com.sun.management.jmxremote.port == .rmi.port avoids the
"double port" problem where the RMI server picks a random port at handshake time.

EOM
  if [[ -n "$HOSTNAME_WARNING" ]]; then
    printf '%s\n\n' "$HOSTNAME_WARNING" >&2
  fi
  if (( ! AUTH )); then
    cat <<EOM >&2
SECURITY: No authentication enabled. Anyone who reaches port $PORT has full code
execution on this JVM (load classes, invoke arbitrary MBean operations). Bind to
127.0.0.1 in dev; in production use --auth + JMX_PASSWORD_FILE, or front Actuator
with Spring Security instead.
EOM
  fi
fi
