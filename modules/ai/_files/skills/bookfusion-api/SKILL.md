---
name: bookfusion-api
description: >-
  Call the BookFusion cloud library/reader directly via its (reverse-engineered) mobile JSON API
  instead of scraping the website with a browser. Use for reading a BookFusion library
  programmatically: search/list books, highlights, bookshelves, series, libraries, authors, tags,
  categories; get reading positions, bookmarks, user profile, subscription; and (gated) create/update
  or delete items. Triggers on: BookFusion, my BookFusion library, list my books/highlights, export
  highlights, BookFusion reading position, replace BookFusion web scraping.
argument-hint: "<command> [--param value ...] [--data '<json>'] [--dry-run] [--pretty] [--dangerous] | login | list | help"
allowed-tools: >-
  Bash(${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh *)
  Bash(bash ${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh *)
  Read(references/*)
  Read
dependencies: >-
  kotlin (auto-bootstrapped via `nix shell nixpkgs#kotlin` when not on PATH; JDK 11+ used for HTTP);
  two Kotlin dependencies (Gson for JSON, SnakeYAML for reading the OpenAPI spec) resolved from Maven
  Central on first run and cached. jq optional for post-processing JSON output.
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
- **DANGEROUS** — all deletes **and `updateUserBook`** (see "Editing book metadata" — it is the *only* path to change a book's title/tags/shelves/series, so even a routine edit needs `--dangerous`). **Refused unless `--dangerous`** is passed (exit code 4).
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
  `--data` = JSON `payload` part, `--file PATH` = optional binary part (the CLI names the binary part
  correctly per endpoint — `binary` for `createHighlight`, `file` for the rest).

## Editing book metadata (`updateUserBook`) — merge/replace semantics
`updateUserBook` is DANGEROUS and is the **only** way to change a book's metadata (title, summary, tags,
bookshelves, series, authors, publisher_name, published_at). Its update rules (verified live) matter:
- An **omitted** field is left **unchanged** — you cannot clear a field by omitting it.
- A sent **scalar** (`title`/`summary`/`language`/`publisher_name`/`published_at`) **overwrites** the old
  value. (`publisher_name` and `published_at` writability was verified live — the Android app's own update
  model omits them, and even omits `tags`, yet the server accepts all three.)
- A sent **array** (`tags`, `bookshelf_ids`, `authors`, `series`) **replaces the entire set**. So
  `{"bookshelf_ids":[5]}` does *not* add shelf 5 — it removes the book from every other shelf. To add a
  shelf, read the book's current `bookshelves[].id`, union your new id in, and send the full list.
- There is **no structured `isbn` field** anywhere in this API — confirmed by decompiling the Android app
  (v2.23.8): no `isbn` literal in any book model. The ISBN you see in the **website** editor is a web-only
  field this mobile API neither returns nor accepts, so it cannot be read or cleared from here. An ISBN that
  *does* show up in this API lives as free text in `tags` (only editable via the `tags` array).
  `creation_token` for `createSeries`/`createBookshelf` is auto-generated when you omit it.

## Bulk changes — `batch` (one login, one JVM)
Each CLI call cold-starts a JVM (~2 s), so many single writes are slow. For bulk work use `batch`, which
reads **JSONL from stdin** (one op per line), logs in **once**, and prints one compact result line per op:
```bash
printf '%s\n' \
  '{"command":"updateUserBook","id":10798945,"data":{"tags":["css","debugging"]}}' \
  '{"command":"updateUserBook","id":10798946,"data":{"bookshelf_ids":[96027]}}' \
  | ${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh batch --dangerous
# -> {"line":1,"command":"updateUserBook","id":"10798945","status":"ok","http":200}
#    stderr: batch: 2 ops, 2 ok, 0 error
```
Response bodies are suppressed (results only). Default is continue-on-error (exit non-zero if any op
failed); use `--stop-on-error` to halt at the first failure. A per-line DANGEROUS op still requires the
batch-level `--dangerous`. Re-run failed lines to resume — the tool invents no server-side idempotency.
For single writes, `--quiet` likewise suppresses the ~1 KB response echo (prints only `ok: …` on stderr).

## Request validation (fast feedback, before the round trip)
Every request body (and path/query params) is validated against [`references/openapi.yaml`](references/openapi.yaml)
**before** it is sent, so mistakes surface locally instead of as an opaque server error after a wasted call.
- **Safe mistakes are auto-fixed** and reported as `fix:` lines on stderr: numeric-string → integer/number
  (`"20"`→`20`), `"true"`/`"false"` → boolean, a scalar where an array is expected is wrapped (`"5"`→`[5]`,
  then its element is coerced too), and enum values are snapped to the correct case (`"Book"`→`"book"`).
  The corrected value is what gets sent.
- **Unfixable mistakes are `error:` lines and block the request (exit `2`) before any network call**: a missing
  required field (reported with its expected type/enum — never invented) or a type that can't be safely coerced
  (e.g. `"abc"` for an integer). Fix them in one shot from the messages.
- **Unknown fields and unknown enum values are `warn:` only and still send** — the spec is reverse-engineered and
  may be incomplete; a `(did you mean 'query'?)` hint is added when a close match exists. `fix:` notes never print
  secret values.

```bash
# Validate offline and print the effective request — never sends, never logs in:
${CLAUDE_SKILL_DIR}/scripts/bookfusion.sh searchHighlights --dry-run --data '{"book_id":"111","page":"2"}'
```
- `--dry-run` — validate + print the request, do not send (exit `2` if it has hard errors, else `0`).
- `--force` — send even when validation found hard errors (still coerces and prints them).
- `--no-validate` — skip validation/coercion entirely (e.g. if the spec is wrong for a given endpoint).

Note: a bare `{}` body now **fails fast** for commands that have required fields (e.g. `addBookBookmark`,
`updateBookReadingPosition`) instead of round-tripping to a server error — supply the fields, or use `--force`/`--no-validate`.

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

Throughput note: sequential single-command runs are bounded by the **~2 s JVM cold-start per invocation**,
not by the rate limit (so the effective rate is ~0.5 req/s, well under the 5 req/s cap). For many writes,
use `batch` (one JVM + one login) — that is where the rate limit actually governs pace.

## Exit codes
`0` ok · `2` usage error (incl. validation hard-fail / `--dry-run` with errors) · `3` auth failure · `4` blocked (DANGEROUS without `--dangerous`, or EXCLUDED) · `5` HTTP error (status + body printed) · `6` I/O / network error.

## First run
The very first invocation (cold cache) bootstraps the Kotlin toolchain via `nix` and resolves the two
Maven dependencies, printing JVM / dependency-resolver / nix noise to **stderr**. That is normal one-time
setup, not an error — judge success by the **exit code**, not by stderr volume.

## Editing this skill
The installed files under `~/.claude/skills/bookfusion-api/` are **read-only symlinks into the Nix store**
(home-manager). Do not edit them in place. Make changes in the source at
`~/.config/nix-darwin/modules/ai/_files/skills/bookfusion-api/`, then re-activate with `darwin-rebuild switch`.

## Tests
`bash ${CLAUDE_SKILL_DIR}/tests/integration_test.sh` runs the client against a local stdlib mock
(`--base-url http://127.0.0.1:PORT`) — no real BookFusion account needed. The mock's canned responses double
as documentation of the real API's behavior (see the `# REAL BEHAVIOR:` comments in `tests/mock_server.py`).
