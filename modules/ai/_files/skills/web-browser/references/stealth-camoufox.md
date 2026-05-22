# Stealth mode (Camoufox)

The default `agent-browser` engine drives Chromium over CDP and exposes
itself unmistakably to fingerprint-class bot detectors (Cloudflare Turnstile,
DataDome, PerimeterX). The `--engine camoufox` engine drives [Camoufox](
https://github.com/daijro/camoufox) instead — a Firefox fork that spoofs
Canvas, WebGL, audio, fonts, screen, navigator, and WebRTC fingerprints in
C++ at engine source level, layered on Playwright Firefox + Juggler.

The two engines live in the same skill but are **separate processes with
separate state.** They do not share a session, refs, or open tabs. Hand off
between them by saving Playwright storage state (cookies + localStorage) on
one side and loading it on the other.

## Two classes of challenge

| Class | Examples | What gates the user out | Solution |
|---|---|---|---|
| **Proof-of-work** | Anubis | Server demands a SHA-256 hash with N leading zero bits; client burns CPU until found. No fingerprinting. | Any browser passes given enough time. Just wait 60–120 s. The default `agent-browser` works; `--engine camoufox` is unnecessary. |
| **Fingerprint + behaviour** | Cloudflare Turnstile, DataDome, PerimeterX, hCaptcha | Trust score from TLS fingerprint (JA3/JA4), Canvas/WebGL/audio hashes, `navigator.webdriver`, mouse trajectory, IP reputation. | `--engine camoufox` with `humanize=True`, `disable_coop=True`, `os`-pinning, optionally `geoip=True` + residential `--proxy`. |

If you can't tell which class a challenge belongs to, look at the request the
server makes:

- "Verify you are human" with a CAPTCHA widget or interstitial → fingerprint
  class.
- "Making sure you're not a robot" with a spinning shield and no widget
  (Anubis) or just a JS challenge that resolves in a few seconds → PoW.

## Camoufox flags

All flags are set at session launch time via `open`. They are immutable for
the rest of the session — calling `open` again on a live daemon just
navigates the existing browser.

| Flag | Camoufox kwarg | Default | When it matters |
|---|---|---|---|
| `--humanize` / `--no-humanize` | `humanize=True` | on | Required for Turnstile-class behavioural checks. Off saves a few hundred ms per click. |
| `--os macos\|linux\|windows` | `os=…` | `macos` | The fingerprint must agree with the IP/locale. Pin to whatever the proxy egresses from. |
| `--geoip` / `--no-geoip` | `geoip=True` | auto-on with `--proxy` | Aligns timezone, locale, Accept-Language with the egress IP. Don't use without a proxy — your real timezone will leak. |
| `--disable-coop` / `--no-disable-coop` | `disable_coop=True` | on | **Required** for Cloudflare Turnstile: the widget runs in a cross-origin iframe that COOP would isolate from Playwright. |
| `--proxy URL` | `proxy={"server": URL}` | none | A clean residential IP can succeed where a datacenter IP fails Cloudflare's reputation check. |
| `--locale CODE` | `locale=CODE` | `en-US` | Override when the target site geoblocks. |
| `--block-images` | `block_images=True` | off | Cheap perf win. Some captchas care about image fetches; test before relying on this. |
| `--window WxH` | `window=(W,H)` | `1280x720` | Pin to a common resolution. Avoid odd sizes. |
| `--headed` | `headless=False` | headless | Mostly for local debugging. |
| `--state PATH` | `storage_state=PATH` | none | Resume a saved session. |
| `--session-name NAME` | persistent under `~/.cache/camoufox-driver/sessions/NAME` | none | Browser profile persists across daemon restarts. |

Two common starting points:

```bash
# Anubis (PoW) — defaults are fine
camoufox-driver open https://target.example/protected

# Cloudflare Turnstile — full stealth profile
camoufox-driver open --humanize --os macos --disable-coop \
  --proxy http://user:pass@residential-proxy:8080 --geoip \
  https://target.example/login
```

## Detecting completion

Don't sleep — wait on the actual success signal.

| Challenge | Success signal | wait expression |
|---|---|---|
| Cloudflare Turnstile — invisible mode | `cf-turnstile-response` hidden input populated automatically | `wait --fn 'document.querySelector("input[name=\"cf-turnstile-response\"]")?.value?.length > 20' --timeout 90` |
| Cloudflare Turnstile — managed mode | Widget renders a visible "Verify you are human" checkbox; needs a click | `wait --selector ".cf-turnstile iframe" --timeout 30` then `click ".cf-turnstile iframe"` then wait on token value |
| Cloudflare interstitial (page visit) | `cf_clearance` cookie set | `wait --fn 'document.cookie.includes("cf_clearance")' --timeout 90` |
| Anubis | `techaro.lol-anubis-auth` cookie set | `wait --fn 'document.cookie.includes("techaro.lol-anubis-auth")' --timeout 120` |
| Generic JS challenge | Network idle + URL changed | `wait --load networkidle` then `get url` |

## Hand-off pattern: solve once, drive elsewhere

Camoufox is heavyweight (~300 MB binary, slower per-call than CDP). For
cookie-bound flows you can solve the challenge once in Camoufox, save the
state, and continue routine work in the default `agent-browser` engine.

```bash
# Phase 1 — clear the challenge in Camoufox
SKILL=…/web-browser

zsh "$SKILL/scripts/web-browser.sh" --engine camoufox open https://anubis.techaro.lol/
zsh "$SKILL/scripts/web-browser.sh" --engine camoufox wait \
    --fn "document.cookie.includes('techaro.lol-anubis-auth')" --timeout 120
zsh "$SKILL/scripts/web-browser.sh" --engine camoufox state save /tmp/anubis.json
zsh "$SKILL/scripts/web-browser.sh" --engine camoufox close

# Phase 2 — agent-browser continues with the cleared cookies
zsh "$SKILL/scripts/web-browser.sh" --state /tmp/anubis.json open https://anubis.techaro.lol/
zsh "$SKILL/scripts/web-browser.sh" snapshot -i
```

Works for:

- **Anubis**: cookie is signed-JWT, validates against any UA, persists ~1 week.
- **Cloudflare page-visit interstitial**: `cf_clearance` is IP+UA bound but
  works for ~30 min if you stay on the same IP and pin the same UA across
  engines (the default Camoufox `os=macos` profile uses a recent Firefox UA;
  agent-browser ships Chromium — UA mismatch invalidates the cookie).

Does **not** work for:

- **Cloudflare Turnstile form tokens**: `cf-turnstile-response` is a
  one-time JWT submitted with the form. You must submit the form inside the
  same Camoufox session.
- Anything that fingerprints again on each request rather than gating
  per-cookie.

## When Camoufox alone is not enough

If Turnstile still gates the page after a clean Camoufox run, the bottleneck
is usually IP reputation. Try:

1. A residential / mobile proxy (Bright Data, Smartproxy, OxyLabs, Apify).
2. Wait out the rate limit (Cloudflare ratchets up restrictions on
   repeatedly-failed IPs).
3. Bring in a paid captcha-solver service (CapSolver, 2Captcha, NopeCHA)
   and inject the returned token into `cf-turnstile-response`. The Camoufox
   wiki has [a worked example](https://github.com/daijro/camoufox/issues/584)
   and CapSolver publishes [an integration guide](
   https://www.capsolver.com/blog/web-scraping/camoufox-capsolver).

## Operational notes

- One daemon per `--session` name. Sockets live at
  `${XDG_RUNTIME_DIR:-/tmp}/camoufox-daemon-<session>.sock`; PID file is
  alongside. Logs at `~/.cache/camoufox-driver/sessions/<session>.log`.
- The first invocation provisions a uv-managed venv at
  `~/.cache/camoufox-driver/.venv` and (if the Nix-managed binary is not
  available for the platform) fetches the ~300 MB browser via
  `python -m camoufox fetch`. Expect a one-time delay.
- Refs (`@e1`, `@e2`, …) are written to the DOM as `data-camoufox-ref` and
  re-issued on each `snapshot`. They invalidate the same way as
  `agent-browser` refs do.
- `--engine camoufox` cannot be combined with `--aws-agent-core` (AgentCore
  is Chromium). The wrapper rejects the combination with a clear error.
- `--engine camoufox close --all` clears every Camoufox daemon socket; use
  it when a daemon is wedged.

## Why not just monkey-patch agent-browser?

Camoufox uses Firefox's Juggler protocol, not CDP. The agent-browser binary
speaks CDP. Pointing `--cdp` or `--executable-path` at Camoufox cannot work
without a translation layer that doesn't exist. Running Camoufox via its
documented Python wrapper is the only supported interface.

This is also why CDP-only features (React DevTools, `vitals`, network HAR,
Chrome trace) are not available under `--engine camoufox`. Use the default
engine for those.
