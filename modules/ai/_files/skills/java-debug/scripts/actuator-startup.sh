#!/usr/bin/env bash
# actuator-startup.sh — Emit Spring Boot Actuator management.* properties as -D flags
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: actuator-startup.sh [options]

Emit the Spring Boot management.* properties as JVM -D flags. Two presets:
  --dev (default): everything exposed, show values + details ALWAYS, JMX enabled
  --prod          : health/info/metrics only over HTTP, masked values, WARNING printed

Options:
  --dev                       Use the development preset (default).
  --prod                      Use the production preset (advisory; Spring Security required).
  --include LIST              Override HTTP exposure (CSV of endpoint IDs, or '*').
  --health-details MODE       ALWAYS | WHEN_AUTHORIZED | NEVER. Defaults per preset.
  --show-values MODE          ALWAYS | WHEN_AUTHORIZED | NEVER. Defaults per preset.

Endpoint-relocation flags (all optional; emit only when set):
  --server-port N             -Dmanagement.server.port=N (separate management HTTP server)
  --server-base-path P        -Dmanagement.server.base-path=P (prepended, e.g. /admin)
  --web-base-path P           -Dmanagement.endpoints.web.base-path=P (replaces /actuator)

  --print-args-only           Emit only the flag string, no banner.
  -h, --help                  Show this help

Examples:
  # Local dev — full visibility
  actuator-startup.sh --print-args-only

  # Same, but Actuator on a separate port + non-default base-path
  actuator-startup.sh --server-port 9001 --web-base-path /management --print-args-only

  # Production preset (advisory — front this with Spring Security!)
  actuator-startup.sh --prod --print-args-only
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

PRESET=dev
INCLUDE=""
HEALTH_DETAILS=""
SHOW_VALUES=""
SERVER_PORT=""
SERVER_BASE_PATH=""
WEB_BASE_PATH=""
PRINT_ARGS_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dev) PRESET=dev; shift ;;
    --prod) PRESET=prod; shift ;;
    --include) INCLUDE="$2"; shift 2 ;;
    --health-details) HEALTH_DETAILS="$2"; shift 2 ;;
    --show-values) SHOW_VALUES="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --server-base-path) SERVER_BASE_PATH="$2"; shift 2 ;;
    --web-base-path) WEB_BASE_PATH="$2"; shift 2 ;;
    --print-args-only) PRINT_ARGS_ONLY=1; shift ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
done

# Apply preset defaults
case "$PRESET" in
  dev)
    : "${INCLUDE:=*}"
    : "${HEALTH_DETAILS:=ALWAYS}"
    : "${SHOW_VALUES:=ALWAYS}"
    ;;
  prod)
    : "${INCLUDE:=health,info,metrics}"
    : "${HEALTH_DETAILS:=WHEN_AUTHORIZED}"
    : "${SHOW_VALUES:=WHEN_AUTHORIZED}"
    ;;
esac

flags=(
  "-Dspring.jmx.enabled=true"
  "-Dmanagement.endpoints.enabled-by-default=true"
  "-Dmanagement.endpoints.web.exposure.include=$INCLUDE"
  "-Dmanagement.endpoints.jmx.exposure.include=*"
  "-Dmanagement.endpoints.jmx.exposure.exclude=none"
  "-Dmanagement.endpoint.health.show-details=$HEALTH_DETAILS"
  "-Dmanagement.endpoint.health.show-components=$HEALTH_DETAILS"
  "-Dmanagement.endpoint.env.show-values=$SHOW_VALUES"
  "-Dmanagement.endpoint.configprops.show-values=$SHOW_VALUES"
)

[[ -n "$SERVER_PORT" ]]      && flags+=("-Dmanagement.server.port=$SERVER_PORT")
[[ -n "$SERVER_BASE_PATH" ]] && flags+=("-Dmanagement.server.base-path=$SERVER_BASE_PATH")
[[ -n "$WEB_BASE_PATH" ]]    && flags+=("-Dmanagement.endpoints.web.base-path=$WEB_BASE_PATH")

if (( PRINT_ARGS_ONLY )); then
  printf '%s ' "${flags[@]}"
  printf '\n'
else
  cat <<EOM
=== Spring Boot Actuator startup flags (preset: $PRESET) ===
Add these to JAVA_TOOL_OPTIONS / your build file / Dockerfile / Spring bootRun jvmArgs:

EOM
  for f in "${flags[@]}"; do
    printf '  %s\n' "$f"
  done
  cat <<EOM

Equivalent application.yml:

  spring:
    jmx:
      enabled: true
  management:
    endpoints:
      enabled-by-default: true
      web:
        exposure:
          include: "$INCLUDE"
$( [[ -n "$WEB_BASE_PATH" ]] && printf '        base-path: "%s"\n' "$WEB_BASE_PATH" )
      jmx:
        exposure:
          include: "*"
    endpoint:
      health:
        show-details: $HEALTH_DETAILS
        show-components: $HEALTH_DETAILS
      env:
        show-values: $SHOW_VALUES
      configprops:
        show-values: $SHOW_VALUES
$( [[ -n "$SERVER_PORT$SERVER_BASE_PATH" ]] && printf '    server:\n' )
$( [[ -n "$SERVER_PORT" ]] && printf '      port: %s\n' "$SERVER_PORT" )
$( [[ -n "$SERVER_BASE_PATH" ]] && printf '      base-path: "%s"\n' "$SERVER_BASE_PATH" )

EOM
  if [[ "$PRESET" == "prod" ]]; then
    cat <<EOM >&2
WARNING (prod preset): even with WHEN_AUTHORIZED masking, Actuator endpoints expose
sensitive information. ALWAYS front them with Spring Security in production
(separate filter chain on management.server.port, Basic Auth or OIDC).
EOM
  fi
fi
