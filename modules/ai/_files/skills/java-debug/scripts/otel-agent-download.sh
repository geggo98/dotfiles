#!/usr/bin/env bash
# otel-agent-download.sh — Idempotently download the OpenTelemetry Java agent jar
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: otel-agent-download.sh [options]

Idempotently download the OpenTelemetry Java agent jar from GitHub releases.
On success, prints the absolute path of the agent to stdout (so the calling
script can capture it via $(otel-agent-download.sh)).

Options:
  --to PATH           Destination path (default: ~/.cache/otel/opentelemetry-javaagent.jar)
  --version VERSION   Specific release tag like "2.10.0" (default: "latest")
  --force             Re-download even if the file already exists
  --verify-checksum   Download .sha256 next to the jar and verify
  --timeout SECS      curl --max-time value (default: 60)
  -h, --help          Show this help

Exit codes:
  0 ok | 1 usage error | 2 missing curl | 3 download/verify failed
EOF
}

err() { printf 'error: %s\n' "$*" >&2; }

DEST="${HOME}/.cache/otel/opentelemetry-javaagent.jar"
VERSION="latest"
FORCE=0
VERIFY=0
TIMEOUT=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --to) DEST="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --verify-checksum) VERIFY=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { err "curl not found on PATH"; exit 2; }

if [[ -f "$DEST" && $FORCE -eq 0 ]]; then
  printf '%s\n' "$DEST"
  printf 'agent already present at %s (use --force to re-download)\n' "$DEST" >&2
  exit 0
fi

if [[ "$VERSION" == "latest" ]]; then
  URL="https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar"
else
  URL="https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${VERSION}/opentelemetry-javaagent.jar"
fi

mkdir -p "$(dirname "$DEST")"
TMP="${DEST}.partial"

printf 'downloading %s -> %s\n' "$URL" "$DEST" >&2
if ! curl -fsSL --max-time "$TIMEOUT" -o "$TMP" "$URL"; then
  rm -f "$TMP"
  err "download failed: $URL"
  exit 3
fi

if (( VERIFY )); then
  SHA_URL="${URL%.jar}.jar.sha256"
  if ! curl -fsSL --max-time "$TIMEOUT" -o "${TMP}.sha256" "$SHA_URL"; then
    rm -f "$TMP" "${TMP}.sha256"
    err "checksum download failed: $SHA_URL"
    exit 3
  fi
  EXPECTED=$(awk '{print $1}' "${TMP}.sha256")
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$TMP" | awk '{print $1}')
  else
    ACTUAL=$(shasum -a 256 "$TMP" | awk '{print $1}')
  fi
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    rm -f "$TMP" "${TMP}.sha256"
    err "checksum mismatch: expected=$EXPECTED actual=$ACTUAL"
    exit 3
  fi
  rm -f "${TMP}.sha256"
  printf 'checksum verified (%s)\n' "$EXPECTED" >&2
fi

mv "$TMP" "$DEST"
printf '%s\n' "$DEST"
printf 'downloaded %s bytes\n' "$(wc -c < "$DEST" | tr -d ' ')" >&2
