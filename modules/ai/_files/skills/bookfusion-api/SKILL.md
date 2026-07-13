---
name: bookfusion-api
description: >-
  Call the BookFusion cloud library/reader directly via its (reverse-engineered) mobile JSON API
  instead of scraping the website with a browser. Use for reading a BookFusion library
  programmatically: search/list books, highlights, bookshelves, series, libraries, authors, tags,
  categories; get reading positions, bookmarks, user profile, subscription; and (gated) create/update
  or delete items. Triggers on: BookFusion, my BookFusion library, list my books/highlights, export
  highlights, BookFusion reading position, replace BookFusion web scraping.
argument-hint: "<command> [--param value ...] [--data '<json>'] [--pretty] [--dangerous] | login | list | help"
allowed-tools: >-
  Bash(${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh *)
  Bash(bash ${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh *)
  Read(references/*)
  Read
dependencies: >-
  kotlin (auto-bootstrapped via `nix shell nixpkgs#kotlin` when not on PATH; JDK 11+ used for HTTP);
  one Kotlin dependency (Gson) resolved from Maven Central on first run and cached. jq optional for
  post-processing JSON output.
---

# bookfusion-api

Direct CLI access to the BookFusion mobile JSON API (`https://www.bookfusion.com`) — a fast, reliable
replacement for browser-based scraping. **Unofficial**: reverse-engineered from the Android app; the
server API is unversioned and may change; use may conflict with BookFusion's ToS. It identifies itself
via the `User-Agent` (`bookfusion-api-skill/...`) so usage is attributable to this skill.

## Quick start
```bash
# Credentials come from env / file / sops-nix (see below). Log in once (token is cached):
${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh login

# Read your library (SAFE, default-allowed):
${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh searchUserBooks --data '{"query":"kubernetes","per_page":20}' --pretty

# List every command and its danger tier:
${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh list
```
Command names are the API `operationId`s. Full list + bodies: [`references/endpoints.md`](references/endpoints.md).
Full request/response schemas: [`references/openapi.yaml`](references/openapi.yaml).

## Danger tiers (`bookfusion list` shows each command's tier)
- **SAFE** — reads/searches. Default-allowed. This is the scraping replacement.
- **WRITE** — non-destructive mutations (create/update, upload, reading position, kindle, borrow, join/leave). Default-allowed.
- **DANGEROUS** — destructive (all deletes + `updateUserBook` metadata overwrite). **Refused unless `--dangerous`** is passed (exit code 4).
- **EXCLUDED** — `createReaderSubscription` (payment) and `disconnectFacebook` are intentionally NOT wrapped. (No account-delete endpoint exists in the API.)

```bash
# refused without the flag:
${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh deleteUserBook --id 12345
# proceed explicitly:
${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh deleteUserBook --id 12345 --dangerous
```

## Passing parameters
- Path params: `--<name> value` — `--id`, `--number`, `--slug`, `--book_id`, `--categoryId`.
- Query params: `--email a@b.c` (used by `authChallenge`).
- Body: `--data '<json>'`, `--data-file PATH`, or `--data-stdin`. Missing body defaults to `{}`.
- Multipart (`createHighlight`, `updateUserBook`, `finalizeBookUpload`, `updateUserProfile`):
  `--data` = JSON `payload` part, `--file PATH` = optional binary part.

## Output & context economy
Designed to keep the agent context small and secret-free:
- **Lists → TSV by default** (`--format auto`), which is far more compact than JSON. Use `--format jsonl`
  for line-filterable JSON, or `--format json` (with `--pretty`) for full structure.
- **Large responses go to a temp file** (over `--max-bytes`, default 32 KiB): stdout then carries only the
  **file path**, with a short redacted preview + `records=`/`bytes=` summary on stderr. `Read`/`rg`/`awk`
  the file when you need the data. `--stdout` forces small results inline; `--out PATH` picks the file.
- **Credentials never reach the context.** Any response containing a `token`/`password`/… is always written
  to a `0600` file (full value there) and only a **redacted** preview is shown. Sensitive keys are masked
  as `***REDACTED***` everywhere they would otherwise print.

## Credentials (never printed; first non-empty wins) — details in [`references/auth-and-secrets.md`](references/auth-and-secrets.md)
| Credential | Order |
|---|---|
| username | `--username-file` → `$BOOKFUSION_USERNAME` → `$BOOKFUSION_USERNAME_FILE` → `~/.config/sops-nix/secrets/bookfusion_username` → `--username` (warns) |
| password | same order with `bookfusion_password` |
| token | `$BOOKFUSION_TOKEN` → `--token-file` → `$BOOKFUSION_TOKEN_FILE` → on-disk cache (auto-login otherwise) |

Do **not** paste passwords inline in a shared shell — prefer env, a `0600` file, or sops-nix.
`bookfusion login` refreshes the cached token; `bookfusion logout` clears it.

## Configuration (env or flag)
| Setting | Flag | Env | Default |
|---|---|---|---|
| API base URL | `--base-url` | `BOOKFUSION_BASE_URL` | `https://www.bookfusion.com` |
| Rate limit (req/s) | `--rate` | `BOOKFUSION_RATE_LIMIT` | `5` |
| Output format | `--format` | `BOOKFUSION_FORMAT` | `auto` (TSV for lists) |
| Inline size cap (bytes) | `--max-bytes` | `BOOKFUSION_OUTPUT_MAX_BYTES` | `32768` |

Rate limiting is enforced before **every** request via a file-locked timestamp, so it holds across
separate CLI invocations too (default ≈ one request per 200 ms). Set a lower `--base-url` for tests.

## Exit codes
`0` ok · `2` usage error · `3` auth failure · `4` blocked (DANGEROUS without `--dangerous`, or EXCLUDED) · `5` HTTP error (status + body printed) · `6` I/O / network error.

## Tests
`bash ${CLAUDE_SKILL_DIR}/tests/integration_test.sh` runs the client against a local stdlib mock
(`--base-url http://127.0.0.1:PORT`) — no real BookFusion account needed.
