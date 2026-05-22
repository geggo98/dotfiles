#!/bin/bash
# Template: Cloudflare Turnstile bypass
# Purpose: Solve a Cloudflare Turnstile widget under Camoufox (fingerprint +
#          behaviour stealth), then exercise the downstream form submit within
#          the same Camoufox session.
# Usage: ./bypass-turnstile.sh [url] [output-dir]
#
# Outputs:
#   - turnstile-before.png: Screenshot of the widget before it solves
#   - turnstile-after.png:  Screenshot of the widget after it auto-solves
#   - turnstile-page.txt:   Snapshot after the form is submitted (if applicable)
#   - turnstile-token.txt:  The cf-turnstile-response token (truncated)
#
# Notes:
#   - The Turnstile form token is a one-time JWT. You CANNOT hand off to
#     another engine after solving — the token is bound to the in-flight
#     submission. Complete the form inside this same Camoufox session.
#   - If the page never finishes its trust check, the bottleneck is usually
#     IP reputation. Add `--proxy http://user:pass@residential:8080` to the
#     `open` line.
#   - Camoufox's `disable_coop=True` (default with --engine camoufox) is
#     mandatory: Turnstile's widget runs in a cross-origin iframe that COOP
#     would isolate from Playwright.

set -euo pipefail

TARGET_URL="${1:-https://clifford.io/demo/cloudflare-turnstile}"
OUTPUT_DIR="${2:-.}"
SKILL="$(dirname "$0")/.."

mkdir -p "$OUTPUT_DIR"

wb() { zsh "$SKILL/scripts/web-browser.sh" "$@"; }

# Stealth profile: humanize + os-pin + disable-coop are the defaults; we set
# them explicitly here for documentation value. Add --proxy + --geoip when the
# default IP gets gated.
echo "→ Open the page under a full stealth profile"
wb --engine camoufox open \
   --humanize --os macos --disable-coop --locale en-US --window 1280x720 \
   "$TARGET_URL"

wb --engine camoufox wait --load domcontentloaded
wb --engine camoufox screenshot "$OUTPUT_DIR/turnstile-before.png"

echo "→ Wait for the Turnstile iframe to inject (managed-mode widget)"
wb --engine camoufox wait --selector ".cf-turnstile iframe" --timeout 30

# Two challenge modes:
#   - invisible/non-interactive: token populates automatically after a few
#     seconds. Just wait on the input value.
#   - managed: visible "Verify you are human" checkbox that needs a click.
# We try auto-solve first (15s), then click the iframe if still empty.
echo "→ Try auto-solve (15 s window)"
if ! wb --engine camoufox wait \
        --fn 'document.querySelector("input[name=\"cf-turnstile-response\"]")?.value?.length > 20' \
        --timeout 15 2>/dev/null; then
  echo "→ Managed mode — clicking the checkbox iframe"
  wb --engine camoufox click ".cf-turnstile iframe"
  wb --engine camoufox wait \
     --fn 'document.querySelector("input[name=\"cf-turnstile-response\"]")?.value?.length > 20' \
     --timeout 75
fi

# Pull the token out and trim it for the log file
TOKEN=$(wb --engine camoufox get value 'input[name="cf-turnstile-response"]')
printf '%.40s…\n' "$TOKEN" > "$OUTPUT_DIR/turnstile-token.txt"

wb --engine camoufox screenshot "$OUTPUT_DIR/turnstile-after.png"

# If the demo page has a submit button, exercise the full form flow so the
# token is actually validated server-side. The demo at clifford.io has one.
echo "→ Submit the form (if a submit button exists)"
SNAP=$(wb --engine camoufox snapshot -i || true)
if grep -qi "submit\|verify" <<<"$SNAP"; then
  wb --engine camoufox find role button --name "Submit" click \
    || wb --engine camoufox find text "Submit" click \
    || true
  wb --engine camoufox wait --load networkidle --timeout 30 || true
  wb --engine camoufox snapshot -i > "$OUTPUT_DIR/turnstile-page.txt"
fi

wb --engine camoufox close

echo ""
echo "Bypass complete:"
ls -la "$OUTPUT_DIR"
