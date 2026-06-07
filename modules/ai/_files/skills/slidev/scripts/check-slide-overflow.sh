#!/bin/zsh
if [ -n "$BASH_VERSION" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/check-slide-overflow.sh) or with: zsh scripts/check-slide-overflow.sh"
  exit 1
fi
set -euo pipefail

# Absolute directory of this script, even when sourced or symlinked.
SCRIPT_DIR="${0:A:h}"

# --- Browser provisioning (nix-pinned, with CDN fallback) -------------------
# Playwright resolves browsers by EXACT revision (1.58.2 wants chromium-1208 /
# firefox-1509 / webkit-2248), so the nix bundle's playwright-driver version
# MUST equal PW_VERSION below. PW_VERSION is the single pin coupled across three
# places: this var, the npm:playwright@ specifier in check-slide-overflow.ts,
# and the deno --lock. Bump all three (and NIXPKGS_REF) in lockstep.
PW_VERSION="1.58.2"
# nixpkgs commit shipping playwright-driver ${PW_VERSION} (2026-04-28:
# chromium-1208 firefox-1509 webkit-2248 ffmpeg-1011). Pinned by full rev so it
# does NOT drift off the system flake registry.
NIXPKGS_REF="github:nixos/nixpkgs/e75f25705c2934955ee5075e62530d74aca973c6"

provisioned=0
if command -v nix >/dev/null 2>&1; then
  nixpw="$(nix eval --raw "${NIXPKGS_REF}#playwright-driver.version" 2>/dev/null || true)"
  if [ "$nixpw" != "$PW_VERSION" ]; then
    echo >&2 "check-slide-overflow: nixpkgs playwright-driver ('${nixpw}') != checker pin ('${PW_VERSION}'); bump both in lockstep. Falling back to CDN browsers."
  elif browsers="$(nix build --no-link --print-out-paths "${NIXPKGS_REF}#playwright-driver.browsers" 2>/dev/null)"; then
    export PLAYWRIGHT_BROWSERS_PATH="$browsers"
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    provisioned=1
  fi
fi
if [ "$provisioned" -eq 0 ]; then
  echo >&2 "check-slide-overflow: using Playwright CDN browsers (nix bundle unavailable); ensuring chromium+firefox+webkit…"
  # Non-fatal: if one engine fails to download, still run the checker with the
  # rest — the .ts reports a clear per-engine launch error for any that's missing.
  deno run --allow-env --allow-read --allow-write --allow-net --allow-run --allow-sys \
    npm:playwright@"${PW_VERSION}" install chromium firefox webkit \
    || echo >&2 "check-slide-overflow: 'playwright install' returned non-zero; continuing with whatever installed."
fi

# Deno resolves npm:playwright (version pinned in the .ts import specifier);
# the co-located lock + --frozen pin the full transitive tree reproducibly.
# Permissions are the minimal set Playwright needs to launch a browser.
exec deno run \
  --allow-env --allow-read --allow-write --allow-net --allow-run --allow-sys \
  --lock="${SCRIPT_DIR}/check-slide-overflow.lock" --frozen \
  "${SCRIPT_DIR}/check-slide-overflow.ts" "$@"
