# The iTerm2 Web profile's DuckDuckGo settings

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

### The iTerm2 Web profile carries its DuckDuckGo settings in the URL

`modules/misc.nix` installs
`modules/_files/darwin/iTerm2/DynamicProfiles/50_Nix.json`, whose `Web` profile
opens a WKWebView browser session at its `Initial URL`. The search settings ride
in that URL rather than being clicked together once per machine:

```json
"Initial URL": "https://start.duckduckgo.com/?kae=t&kbi=1&kp=-2&kpsb=-1"
```

`kae` theme, `kbi` compact results, `kp` safe search, `kpsb` the "Protected"
reminder; the full list is <https://duckduckgo.com/params>. Each setting also
exists as a cookie named after the parameter minus its leading `k` — `kp` → `p`,
`kae` → `ae`.

Five facts decide what this can and cannot do. Each was measured against the live
site on 2026-08-24; DuckDuckGo ships continuously, so re-measure rather than trust
the list.

- **Mind the domain: the settings cookies are host-only on `duckduckgo.com`, and
  `start.duckduckgo.com` therefore never receives them.** The parsed cookie jar
  shows `duckduckgo.com` with no leading dot, so it is not a domain cookie. A
  machine whose settings are configured by hand still opens the start page with
  DuckDuckGo's defaults, and only picks the settings up once a search lands on
  `duckduckgo.com`. Everything the profile needs on the start page must be in the
  URL.
- **The search form forwards the search settings but drops the theme.** Typing a
  query on the start page produces
  `duckduckgo.com/?…&kp=-2&kpsb=-1&kbi=1&q=…` — `kl`, `k1` and `kaf` travel too,
  and they survive follow-up searches. `kae` does not, on either start page. The
  results page therefore themes itself from the cookie, or from
  `prefers-color-scheme`, which macOS Dark Mode drives. Measured with the browser
  forced to `prefers-color-scheme: light`, so the browser could not fake the
  result.
- **URL parameters never write cookies.** They override per request, which is why
  they cannot fight a machine's own saved settings beyond the keys they name.
- **Plain `duckduckgo.com/` is the promotional homepage** ("Switch to DuckDuckGo",
  "Download Browser"). `duckduckgo.com/?startpage=1` renders the same minimal page
  as `start.duckduckgo.com` on the origin that holds the cookies, which would make
  the theme apply there as well — but that parameter appears only in the page's own
  JavaScript, so a silent removal would drop the profile onto the promotional page.
- **Cloud Save can be automated, and deliberately is not.**
  `?key=<SHA-512 hex of the passphrase>` sets the cloud key and triggers
  `GET /settings.js?key=…`, which returns the saved settings or 404. That key reads
  *and* overwrites the blob, and DuckDuckGo stores it unencrypted, so it is a
  bearer token — it belongs in 1Password, not in a git-tracked profile or a URL
  that lands in browsing history.

To read what a machine currently has, parse iTerm2's own WebKit store — it
persists across restarts, which is what makes a one-time manual setup stick:

```bash
cd ~/Library/WebKit/com.googlecode.iterm2/WebsiteDataStore/*/   # one store, keyed by UUID

# Cookies/Cookies.binarycookies carries the settings cookies in Apple's binary
# format, so reading it needs a parser rather than grep. The domain recorded
# there has no leading dot — that is the host-only property above, on disk.

# localStorage: the origin files are length-prefixed binary (hence -a), and
# duckduckgo.com and start.duckduckgo.com are separate origins with separate
# databases — only the former carries duckduckgo_settings and objectKey. The
# value is UTF-16, so `cast(value as text)` in the sqlite3 CLI stops at the
# first NUL byte and prints a lone `{`.
for f in Origins/*/*/origin; do
  grep -aq 'duckduckgo\.com' "$f" || continue
  db=${f%/origin}/LocalStorage/localstorage.sqlite3
  [ -f "$db" ] || continue
  sqlite3 "file:$db?mode=ro" \
    "select hex(value) from ItemTable where key='duckduckgo_settings';" |
    python3 -c 'import sys;print(bytes.fromhex(sys.stdin.read().strip()).decode("utf-16-le"))'
done
```

`objectKey` there is the Cloud Save key — treat it as a credential.

Editing the profile follows the usual path: change the JSON, `just build`,
`just switch`. iTerm2 re-reads dynamic profiles live, so no restart is needed.

