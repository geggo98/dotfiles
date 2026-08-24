---
name: jira
description: >
  Control JIRA Cloud tickets over the REST API v2: arbitrary status transitions,
  comments, assignee, create issues, set descriptions, upload/embed attachments,
  labels, links, watchers, JQL search, and assignable-user lookup. A reliable
  fallback for the Atlassian MCP's gaps (no arbitrary transitions; comment Markdown
  gets mangled to wiki-markup; attachment upload can't see the host filesystem).
  Operations are split into read (no flag), write (--write), and dangerous/destructive
  (--dangerous) tiers, and every overwriting or deleting op is journaled locally so it
  can be undone. Long fields (description, comment bodies) can be read out to a file or a
  pipe and written back, so they can be edited with sed/perl without loading them into
  context. Use for: change ticket status / transition, comment, assign, create issue, read
  or edit a description or comment body, upload/embed/delete attachment, add/remove labels,
  link issues, search JQL, resolve an assignee, or undo a prior change.
argument-hint: "[--write|--dangerous] <command> [args...] | help"
allowed-tools: Read(references/*) Bash(./scripts/jira.sh *) Bash(zsh *) Read
dependencies: "uv, gtimeout"
---

# JIRA Skill

Controls JIRA Cloud tickets via the REST API v2 through a self-contained Python
(`uv`) client behind a thin zsh wrapper. It fills the gaps the Atlassian MCP leaves
open — most importantly **arbitrary status transitions** (the MCP cannot reach every
workflow status), a **predictable v2 wiki-markup** comment/description body (the MCP
mangles Markdown → wiki: `**x**`→`*x*`, backticks→`{{…}}`), assignee changes, issue
creation, and attachment upload/embed (the MCP server can't see the local filesystem).

## How to run (always use the helper script)

```bash
zsh ${CLAUDE_SKILL_DIR}/scripts/jira.sh $ARGUMENTS
```

> **Important:** Run the script directly (`${CLAUDE_SKILL_DIR}/scripts/jira.sh`). Do
> **not** prefix it with `bash` — it requires zsh and will fail under bash. It runs
> from **any** directory (no git, no `bb`).

## Operation tiers (read / write / dangerous)

Every command belongs to one tier, gated by global flags accepted **anywhere** in the
argument list. `--` ends **global** flag parsing only — per-command flags after it are
still interpreted, so it is *not* a way to pass a body that starts with a dash; use
`--file` or stdin for that:

| Tier | Flag | What it covers |
|---|---|---|
| **read** | *(none)* | Never changes anything. |
| **write** | `--write` | Creates or modifies ticket data. |
| **dangerous** | `--dangerous` (implies `--write`) | Irreversible deletes. |

Running a `write`/`dangerous` command without its flag prints a clear refusal and
does nothing — no partial mutation. This makes read-only inspection safe by default.

## Commands

```bash
J=${CLAUDE_SKILL_DIR}/scripts/jira.sh

# --- read (no flag; every read command also takes --output PATH|-) ---
$J whoami                                  # account behind the token (verify auth)
$J get JIRA-3052                         # status/type/assignee/labels/updated/description_chars
$J description JIRA-3052                 # the raw description body (read side of describe)
$J status JIRA-3052                      # current status name only
$J transitions JIRA-3052                 # available transitions (id, target, name)
$J comments JIRA-3052 --max 50           # newest comments first (idempotency pre-check)
$J comment-get JIRA-3052 121771          # one comment's raw body (read side of comment-edit)
$J search 'project = VUKFZIF AND status = "In QA"' --max 20   # JQL search
$J links JIRA-3052                       # issue links
$J attachments JIRA-3052                 # id/filename/size/mime/content-url per attachment
$J download JIRA-3052 crawllog.zip       # download an attachment (by id or filename)
$J user alex.beispiel@example.com        # resolve accountId (cached; see below)
$J users bob --issue JIRA-3052           # assignable-user search (paged + cached)
$J undo --list --issue JIRA-3052         # list undoable journal entries

# --- write (need --write) ---
$J --write transition JIRA-3052 "In Code Review"   # any status, by name, idempotent
$J --write transition JIRA-3052 61                  # or by transition id
printf '%s' "<wiki body>" | $J --write comment JIRA-3052 -   # body via stdin (no escaping)
$J --write comment JIRA-3052 --file note.md
$J --write comment-edit JIRA-3052 121771 --file note.md      # replace a comment body
$J --write assign JIRA-3052 @me                     # email / accountId / alias / --unassign
$J --write label JIRA-3052 --add security --remove wip
$J --write link JIRA-3052 "Blocks" JIRA-3060
$J --write watch JIRA-3052                          # add self as watcher (or unwatch)
printf '%s' "<description>" | \
  $J --write create --type Task --label security --summary "[ServiceA] High CVEs (netty)" -
$J --write create --summary "…" --description-file finding.wiki    # or from a file

# --- attachments (write) ---
$J --write attach JIRA-3052 screenshot.png crawllog.zip     # upload only
$J --write comment JIRA-3052 --embed screenshot.png "Error:" # upload + inline !screenshot.png!
$J --write comment JIRA-3052 --embed crawllog.zip "Log:"     # upload + link [^crawllog.zip]
$J --write describe JIRA-3052 --file description.wiki         # replace the description
$J --write describe JIRA-3052 --embed diagram.png "New desc:"

# --- dangerous (need --dangerous) ---
$J --dangerous comment-rm JIRA-3052 121771          # delete a comment (snapshot kept)
$J --dangerous attach-rm JIRA-3052 45231            # delete an attachment (bytes kept)

# --- undo (write) ---
$J --write undo --issue JIRA-3052                    # revert the last change on this ticket
$J --write undo --id 42                                 # revert a specific journal entry
```

- **`transition`** resolves the target status at runtime against the live
  `/transitions` endpoint (case-insensitive, matches the resulting status name) and is
  **idempotent** (already in the target status → no-op). Accepts a numeric transition id too.
- **`comment`** reads the body from **stdin** by default (`-`), so you post exactly the
  wiki-markup you intend without shell-quoting issues.
- **`comments`** shows the newest `--max` (default 50) and warns on stderr when the ticket
  has more (`Showing newest N of M …`) — raise `--max` before trusting a negative
  idempotency check on a long-history ticket.
- **`create`** defaults to project `$JIRA_PROJECT_KEY` (default `VUKFZIF`) and prints the new
  key on stdout; the sizes it actually sent go to stderr (`summary: 37 chars, description:
  1183 chars`). Check that line — a description of `1 char` after a long heredoc means the
  body never arrived. Its description comes from exactly one of `--description TEXT`,
  `--description-file PATH`, `--description-file -` or a bare `-`; combining them is an
  error. `--description -` is honoured too but warns, because `-` is a *filename*
  convention and this used to be read as the literal text `-`.
- **`describe`** **replaces** the description (no merge). The prior text is journaled, so
  `undo` restores it.

## Long fields: read, edit, write back

`-` is the stdin filename **everywhere** — a bare `-`, `--file -` and `--description-file -`
all mean the same thing. Inline text, a file and stdin are mutually exclusive; combining
them is an error rather than a silent winner.

Every read command takes `--output`:

| `--output` | Where the payload goes | Use it for |
|---|---|---|
| *(omitted)* | stdout, truncated above `$JIRA_OUTPUT_MAX_BYTES` (32 KiB) | the default — keeps big results out of context |
| `--output PATH` | `PATH`, byte-exact; stdout gets only `PATH<TAB>bytes` | editing a long body without ever loading it |
| `--output -` | stdout, byte-exact and untruncated | piping into `sed`/`perl` |

```bash
# via a file — the long body never enters the conversation
$J description JIRA-3052 --output /tmp/d.wiki
perl -pi -e 's/netty 4\.1\.\d+/netty 4.1.118/g' /tmp/d.wiki
$J --write describe JIRA-3052 --file /tmp/d.wiki

# or as a straight pipe
$J description JIRA-3052 --output - | sed 's/^h2\./h3./' \
  | $J --write describe JIRA-3052 --file -

# same for a single comment
$J comment-get JIRA-3052 121771 --output - | sed 's/typo/fixed/' \
  | $J --write comment-edit JIRA-3052 121771 --file -
```

> In a pipe you **must** spell out `--output -`. Without it the spill guard is active, and
> above 32 KiB it injects a truncation header into the stream. There is deliberately no
> `isatty()` auto-detection: under an agent harness stdout is always a pipe, which would
> disable the context protection entirely.

`get` reports `description_chars` rather than the description itself, so a body can be
size-checked in one call without paying for it: `$J get KEY --format json | jq
.description_chars`. Note that JQL `description IS EMPTY` will not find a ticket whose
description is a stray `-` — it is not empty.

## Attachments & embedding

`attach`, `--attach`, and `--embed` upload via `POST /rest/api/2/issue/<KEY>/attachments`
(multipart, `X-Atlassian-Token: no-check`). Each local file is validated first (regular,
readable, non-empty). ZIPs/binaries work.

| Purpose | Command | Body |
|---|---|---|
| Upload only | `attach <KEY> <file>…` | — |
| Upload while commenting/describing | `comment/describe … --attach <file>` | unchanged |
| Upload **and** embed | `comment/describe … --embed <file>` | wiki reference appended |

Reference syntax (Jira **v2** wiki-markup; `--embed` generates it automatically):
- **Image** (`png/jpg/jpeg/gif/webp/bmp/svg/tif/tiff/ico/heic`): `!name.png!` (inline).
- **Everything else** (ZIP/PDF/log/…): `[^name.zip]` (clickable file link).
- Order is upload-then-body, so a failed upload never leaves a dead reference.

## Assignable-user search (paged + cached)

`user` and `users` (and `assign`'s email resolution) page through
`/user[/assignable]/search` and cache results in a local SQLite DB. This avoids the
timeouts / **HTTP 429** you hit when repeatedly enumerating a huge user directory (e.g.
`check24`). Cache hits skip the API; `--refresh` forces a re-fetch. `users` needs a
`--project` or `--issue` scope. Tunables: `JIRA_USER_CACHE_TTL` (default 86400s),
`JIRA_USER_SEARCH_CAP` (default 1000), `JIRA_CACHE_DIR`.

## Undo journal

Before any op that **overwrites or deletes** data (`transition`, `comment-edit`,
`assign`, `describe`, `label`, `comment-rm`, `attach-rm`), the client snapshots the prior
value into a **durable local SQLite journal** (`JIRA_STATE_DIR`, default
`$XDG_STATE_HOME/jira-skill`); `attach-rm` also backs up the attachment bytes so the
delete is reversible.

- `undo --list [--issue KEY]` — read; shows recent entries (id, time, key, op, status).
- `undo [--issue KEY] [--id N]` — write; applies the inverse of the most recent (or
  chosen) entry and marks it undone.

Restores are honest about their limits: a deleted comment comes back as a **new**
comment (original id/author/timestamps can't be recreated); this is stated in the output.
Additive ops (`comment`, `attach`, `create`, `link`, `watch`) overwrite nothing and are
not journaled.

## Credentials

Same chain as the `bitbucket-pr` skill: **one env name, then one file.** The
`$SOPS_SECRETS_DIR` file is the default source; the environment variable is a
deliberate manual override.

- `JIRA_URL` | `jira_url` (required — no built-in default)
- `JIRA_USERNAME` | `jira_username`
- `JIRA_API_TOKEN` | `jira_api_token`

There is deliberately **no generic alias tier** (no `ATLASSIAN_API_TOKEN`, no
`atlassian_c24_bitbucket_api_token`). It was removed on 2026-08-24: the shell
exported `ATLASSIAN_API_TOKEN` globally holding a *Bitbucket* token, and because
the chain tried every env name before any file, that dead alias outranked the
correct `jira_api_token` file and every call failed. Worse, it failed as **HTTP
404**, since Jira hides issue existence from unauthenticated callers — so it read
as "that ticket does not exist". Do not reintroduce it.

HTTP Basic against the Jira site; httpx puts the token in a header, so it never reaches
the process argv. Missing credentials → exit 2 with a clear hint (no silent 401). A 401
or 404 now also names the source the token came from (`$JIRA_API_TOKEN` vs. the file),
never the token itself.
Exit codes: `0` ok, `1` bad args / gating refusal, `2` missing prereq/credentials,
`3` API/auth/network, `4` not found, `124` timeout (killed by gtimeout).

## Security

- The client speaks **only issue-scoped endpoints** (`/issue/…`, `/user/…`, `/myself`,
  `/search`, `/issueLink`, `/attachment/<id>`). It knows **no** board/workflow-config
  endpoints — boards and the workflow itself cannot be changed, only individual tickets.
- `create` is pre-set to `$JIRA_PROJECT_KEY` (`--project` / env overrides deliberately).
- `describe` **replaces** the description (journaled for undo). Deletes require the
  explicit `--dangerous` flag and are journaled (with bytes, for attachments).

## Workflow statuses (VUKFZIF)

Global "Any status" transitions — reachable from **every** status, transition name equals
the target status. Runtime source of truth is the `/transitions` endpoint; the id table is
documented for humans in [`references/workflow.md`](references/workflow.md):

`Open, Backlog, To Do, In Progress, In Code Review, In QA, In Test PM, Ready for Release,
Done, Closed` (`In Review` is a decoupled legacy status — no global transition reaches it).

## Related skills

- **`bitbucket-pr`**: JIRA ↔ Bitbucket bridge (linked PRs/branches/repos for a ticket) and
  PR management. Shares this skill's credential chain.
