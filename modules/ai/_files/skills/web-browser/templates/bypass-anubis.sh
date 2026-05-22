#!/bin/bash
# Template: Anubis (proof-of-work) bypass + hand-off
# Purpose: Clear an Anubis JS challenge in Camoufox, save state, hand off to
#          the default agent-browser engine for subsequent work.
# Usage: ./bypass-anubis.sh <url> [output-dir]
#
# Outputs:
#   - anubis-pass.png:   Screenshot of the post-challenge page (proof)
#   - anubis-state.json: Playwright storage state (cookies + localStorage)
#   - anubis-page.txt:   Snapshot of the protected page after hand-off
#
# Notes:
#   - Anubis is a CPU-only challenge, so any browser passes given time. We use
#     Camoufox here only to demonstrate the hand-off pattern; on a single host
#     the default engine would also work.
#   - The auth cookie is `techaro.lol-anubis-auth` (signed JWT, ~1 week TTL).

set -euo pipefail

TARGET_URL="${1:-https://anubis.techaro.lol/}"
OUTPUT_DIR="${2:-.}"
SKILL="$(dirname "$0")/.."

mkdir -p "$OUTPUT_DIR"
STATE_FILE="$OUTPUT_DIR/anubis-state.json"

wb() { zsh "$SKILL/scripts/web-browser.sh" "$@"; }

echo "→ Phase 1: clear Anubis challenge in Camoufox"
wb --engine camoufox open "$TARGET_URL"

# Wait up to 120 s for the proof-of-work cookie to land
wb --engine camoufox wait \
   --fn "document.cookie.includes('techaro.lol-anubis-auth')" \
   --timeout 120

wb --engine camoufox screenshot "$OUTPUT_DIR/anubis-pass.png"
wb --engine camoufox state save "$STATE_FILE"
wb --engine camoufox close

[[ -s "$STATE_FILE" ]] || { echo "ERROR: state file is empty"; exit 1; }
grep -q "techaro.lol-anubis-auth" "$STATE_FILE" \
  || { echo "ERROR: auth cookie missing from state"; exit 1; }

echo "→ Phase 2: continue under agent-browser with the cleared state"
wb --state "$STATE_FILE" open "$TARGET_URL"
wb wait --load domcontentloaded
wb snapshot -i > "$OUTPUT_DIR/anubis-page.txt"
wb close

echo ""
echo "Bypass complete:"
ls -la "$OUTPUT_DIR"
