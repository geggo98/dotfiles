---
name: bitbucket-pr
description: "Read and manage Bitbucket Cloud pull requests, comments, and tasks via the `bb` CLI (gildas/bitbucket-cli v0.18.1+). Use when reviewing PR feedback, replying to comments, creating tasks/PRs, or marking review tasks done. Also bridges JIRA issues to their linked Bitbucket PRs/branches/repos via Jira's dev-status API — find the PR(s) for a JIRA key (e.g. VUKFZIF-1234), even in repos that aren't cloned locally."
context: fork
allowed-tools: Bash(./scripts/bitbucket_pr.sh *) Bash(./scripts/bitbucket_pr_comments.sh *) Bash(./scripts/bitbucket_pr_tasks.sh *) Bash(./scripts/bitbucket_jira.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh *) Bash(zsh *)
dependencies: "bb (Bitbucket CLI, installed via Nix on this host), jq, curl (JIRA bridge). JIRA bridge credentials: jira_url / jira_username / jira_api_token via env (JIRA_URL, JIRA_USERNAME, JIRA_API_TOKEN / ATLASSIAN_API_TOKEN) or files in ~/.config/sops-nix/secrets"
---

# Bitbucket Pull Request Skill

A wrapper around `bb` (Bitbucket Cloud CLI) exposing **stable, read- and safe-write** operations on PRs, comments, and tasks. Destructive operations (`merge`, `decline`, any `delete`) are intentionally **not** wrapped — use raw `bb` with explicit user approval if you really need them.

> **⚠ Run these scripts from inside the target repository's git working tree, by their absolute `${CLAUDE_SKILL_DIR}/scripts/…` path — never `cd` into the skill directory.** `bb` resolves the workspace and repository from the **git remote of the current directory** (`--workspace`/`--repository` default to *"determined from the git configuration"*). A wrong CWD — the skill dir, `/tmp`, or any repo whose remote isn't `bitbucket.org` — fails with `Error: Argument repository is missing`. The scripts self-locate their own helpers (`${0:A:h}`), so the absolute path works from any CWD; just keep your shell in the repo you're operating on. The scripts emit a non-fatal warning when the current directory has no `bitbucket.org` remote.

> **Two exceptions to "run inside the repo":**
> 1. Pass `--repo <workspace>/<slug>` (or the native `--workspace`/`--repository` pair) to any `bitbucket_pr*.sh` command to target a specific repo regardless of CWD — needed for PRs in repos you haven't cloned (e.g. ones surfaced by `bitbucket_jira.sh`). It also silences the no-remote warning. See [§11](#11-jira--bitbucket-bridge).
> 2. **`bitbucket_jira.sh` is workspace-global:** it talks to the Jira REST API directly, runs from **any CWD**, and ignores git/`bb` entirely.

## 1. Capability surface

| Resource | Read | Write (safe) | Hidden (raw `bb` only) |
|---|---|---|---|
| PR      | `list`, `get` | `create` (opt. `--draft`), `update` (title / description) | `merge`, `decline`, `approve`, `unapprove`, `request-changes` |
| Comment | `list`, `get` | `create`, `update`, `resolve`, `reopen` | `delete` |
| Task    | `list`, `get` | `create`, `update`, `resolve`, `reopen` | `delete` |

Bitbucket's hierarchy: **PR → comment → task** (tasks may also live on the PR with no parent comment).

## 2. Helper scripts

| Script | Purpose |
|---|---|
| `${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh`          | PR-level operations |
| `${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh` | Comment operations |
| `${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh`    | Task operations    |
| `${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh`        | JIRA → Bitbucket bridge (find PRs/branches/repos for a JIRA key); see [§11](#11-jira--bitbucket-bridge) |

All four are **zsh** scripts that source `${CLAUDE_SKILL_DIR}/scripts/_lib.sh` for shared helpers (logging, prerequisite checks, stdin reading, output buffering, `--repo` target parsing). Run them directly — they refuse to run under bash. Run any script with `--help` for its full grammar. The three `bb` wrappers share the same exit codes and env vars (see §6, §7); `bitbucket_jira.sh` reuses the same exit-code scheme but talks to Jira, not `bb` (see §11).

## 3. Usage by resource

> **Targeting another repo (any command below):** by default each command resolves the workspace/repository from the current git remote. Add `--repo <workspace>/<slug>` — or the native pair `--workspace <W> --repository <R>` — to operate on a different repo, **including one you haven't cloned**. The `<workspace>/<slug>` is exactly what `bitbucket_jira.sh repos` prints. This is the bridge from a JIRA lookup to reading that PR's comments/tasks (see [§11](#11-jira--bitbucket-bridge)).

### Pull requests

```bash
# List open PRs in the workspace/repo configured for bb
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh list                       # default state OPEN, formatted JSON
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh list MERGED                # OPEN | MERGED | DECLINED | SUPERSEDED
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh list --format tsv          # ~10x smaller for browsing
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh list MERGED --format tsv

# Fetch one PR as JSON
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh get 1234

# Create a PR (description is optional, supplied via stdin)
echo "Closes #999. Background: …" | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh create "Add foo bar" feature/foo main

# Create a draft PR (--draft may go before or after the positional args)
echo "WIP, do not merge yet." | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh create --draft "Add foo bar" feature/foo main

# Rename a PR
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh update 1234 --title "Better title"

# Replace the description (multiline markdown via stdin)
cat <<'MD' | ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh update 1234 --description-from-stdin
## Summary
- Did X
- Did Y

## Test plan
- [ ] Manual smoke
MD
```

> **⚠ Draft state is write-only through `bb` (v0.18.1).** `create --draft` sets it,
> but `bb pr get` / `pr list` **omit the `draft` field entirely** and `bb pr update`
> has **no `--draft` flag** — so this skill can neither read back nor toggle (publish /
> un-publish) draft status. To confirm a PR is a draft, query the REST API directly:
> `GET repositories/<ws>/<slug>/pullrequests/<id>?fields=id,draft,state` with the same
> credentials `bb` stores (Basic auth, user + app password from `config-cli.yml`).

#### PR description conventions (attribution & prompt reference)

When **you (the agent) create a PR via `create`** (or replace its description via
`update`), compose the body as usual, then apply these conventions:

**Attribution footer (on by default, opt-out).** Make the **very last line** of
the description a single footer line: a robot emoji plus a note that the PR was
created with help from this skill. **Match the language of the PR description:**

- English body → ``🤖 Created with assistance from the `bitbucket-pr` skill.``
- German body  → ``🤖 Erstellt mit Unterstützung des `bitbucket-pr` Skills.``

Put a `---` separator on the line above the footer. Omit the footer only if the
user asks you to.

**No other AI attribution.** This footer is the *only* provenance line. Do **not**
add `Co-Authored-By: Claude`, `Generated with Claude Code`, or any other AI/model
byline anywhere in the PR description (commits are already covered by the global
`includeCoAuthoredBy = false` Claude Code setting).

**Original prompt as reviewer reference (off by default — ask first).**
**Before** creating the PR, ask the user whether the original prompt that
triggered the work should be included as a reference for the reviewer. If they
agree:

- Quote the prompt **verbatim** as a Markdown blockquote (`>`) under a short
  heading (e.g. `### Original request` / `### Ursprünglicher Auftrag`).
- Do **not** silently fix typos or mistakes in the original — mark them with
  `[sic]`.
- Capture the outcome of any clarifying follow-up questions either **inline** in
  the quote (a short annotation next to the relevant phrase) **or** as a
  **bullet list directly below** the quoted prompt — short, location-specific
  clarifications inline; longer or multiple ones as a list.

Order in the description: PR body → (optional) quoted-prompt block → `---` →
🤖 footer (the footer always stays the **last** line).

Example description (with prompt reference):

````markdown
## Summary
- …

## Test plan
- [ ] …

---

### Original request
> Pls add retry to the uploader, make it confgiurable [sic]

Clarifications:
- Max retries default: 3 (confirmed with author)
- Backoff: exponential, capped at 30s

---

🤖 Created with assistance from the `bitbucket-pr` skill.
````

> **Tip:** route `create` *and* `update` through these scripts — they pipe the
> description to `bb` via stdin, sidestepping the heredoc escaping problems that
> bite when calling `bb pr create/update --description "..."` inline.

### Comments

```bash
# All comments on a PR — JSON filtered to {id, content, inline}
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh list 1234
# Or compact TSV (bb's native columns: id, created_on, updated_on, file, user, content)
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh list 1234 --format tsv

# Raw markdown of one comment
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh get 1234 5678

# Top-level comment
echo "**Heads up:** depends on #1230." | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh create 1234

# Inline comment on a file/line
echo "Consider extracting this." | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh create 1234 --file src/main.go --line 42

# Reply to an existing comment
echo "Agreed, will fix." | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh create 1234 --parent 5678

# Edit a comment you (or the bot) wrote
echo "Updated wording." | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh update 1234 5678

# Resolve / reopen
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh resolve 1234 5678
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh reopen  1234 5678
```

### Tasks (new in `bb` v0.18.0)

```bash
# All tasks on a PR — formatted JSON
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh list 1234
# Or compact TSV (id, state, creator, created_on, updated_on, resolved_on, resolved_by, content)
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh list 1234 --format tsv

# One task
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh get 1234 4242

# Standalone PR task
echo "Update CHANGELOG for the release." | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh create 1234

# Task attached to a comment (e.g., turn review feedback into an actionable item)
echo "Rename `foo` to `fooBar`." | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh create 1234 --comment 5678

# Edit task text
echo "Rename `foo` to `fooBaz` (renamed in spec)." | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh update 1234 4242

# Mark done / reopen
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh resolve 1234 4242
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh reopen  1234 4242
```

## 4. Common review workflow

```bash
# 1. Pull the discussion surface
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh list 1234 > /tmp/comments.json
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh    list 1234 > /tmp/tasks.json

# 2. For each unresolved task, decide: fix in code, reply in thread, or close.
#    After implementing each fix:
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh resolve 1234 4242
echo "Fixed in <commit-hash>" | \
  ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh create 1234 --parent <task-comment-id>
```

## 5. Output format

- **Default: pretty-printed JSON.** Every `list` / `get` / `create` / `update` / `resolve` / `reopen` call goes through `bb --output json` and the JSON is emitted verbatim (already indented by `bb`).
- **TSV opt-in on `list`:** every `list` command accepts `--format json|tsv`. TSV is `bb`'s native tab-separated output — roughly **10× smaller** than JSON for `pr list` (measured: 256 KB → 26 KB), **7×** for `comment list`, **12×** for `task list`. Use it when you only need to browse / pick an id and don't need to filter with `jq`.
- `bitbucket_pr_comments.sh list` (JSON path) is **filtered** down to `{id, content, inline}` per comment for compactness; pipe further through `jq` for selection: `... list 1234 | jq 'map(select(.inline))'`. The TSV path keeps `bb`'s columns: `id, created_on, updated_on, file, user, content`.
- `bitbucket_pr_comments.sh get` returns the raw markdown body only (no JSON wrapper); when spilled, the tempfile suffix is `.md`.
- **Spillover for large outputs.** If a command's output exceeds `BB_OUTPUT_MAX_BYTES` (default **32 768**), it is written to `${TMPDIR:-/tmp}/bb-<label>.XXXXXX.<ext>` (`<ext>` ∈ `json` / `tsv` / `md`) and stdout shows a header (size, line count, full path) followed by a 10-line preview. Read the full result with `jq . <path>` (JSON) or `column -t -s $'\t' <path>` (TSV). Raise the threshold if needed: `BB_OUTPUT_MAX_BYTES=65536 ${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh get 1234`.

## 6. Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Invalid arguments / missing stdin / bad flag |
| 2 | `bb` / `jq` / `curl` not on PATH (JIRA bridge: also missing credentials) |
| 3 | `bb` invocation or JIRA REST call failed (network, auth, server error) |
| 4 | PR / comment / task / JIRA issue not found |

## 7. Environment variables

| Variable               | Description                                                                                  |
|------------------------|----------------------------------------------------------------------------------------------|
| `BITBUCKET_CLI`        | Path to the `bb` binary (default `bb`)                                                       |
| `JQ_PATH`              | Path to `jq` (default `jq`)                                                                  |
| `BB_OUTPUT_MAX_BYTES`  | Spill output larger than this to a tempfile (default `32768`; matches `database` skill)      |
| `BB_PROFILE`           | (Read by `bb`) which profile to use                                                          |
| `BB_OUTPUT_FORMAT`     | (Documented for `bb` — but see warning below)                                                |
| `CURL_PATH`            | (JIRA bridge) Path to `curl` (default `curl`)                                                |
| `JIRA_URL`             | (JIRA bridge) Jira base URL; else file `jira_url` in `$SOPS_SECRETS_DIR`                     |
| `JIRA_USERNAME`        | (JIRA bridge) Jira account email for Basic auth; else file `jira_username`                   |
| `JIRA_API_TOKEN`       | (JIRA bridge) Atlassian API token; falls back to `ATLASSIAN_API_TOKEN`, then files           |
| `ATLASSIAN_API_TOKEN`  | (JIRA bridge) Fallback token (already exported in this shell)                                |
| `SOPS_SECRETS_DIR`     | (JIRA bridge) sops-nix secrets dir (default `~/.config/sops-nix/secrets`)                    |
| `JIRA_DEV_APPLICATION_TYPE` | (JIRA bridge) dev-status `applicationType` (default `bitbucket`)                        |

`bb` resolves the **workspace and repository from the git remote of the current directory** (its `--workspace`/`--repository` flags default to *"determined from the git configuration"*), falling back to the active profile's defaults. **This is why the scripts must run from inside the target repo's working tree** — see the callout at the top. Credentials and any profile-level defaults come from `bb`'s own config (`~/.config/bitbucket/config-cli.yml` or `~/Library/Application Support/bitbucket/config-cli.yml`) and its keychain-stored credentials.

> **⚠ `BB_OUTPUT_FORMAT` is silently ignored by `bb` v0.18.0.** Running `env BB_OUTPUT_FORMAT=json bb pr list` falls back to the default `table` output (with ASCII borders) instead of JSON. Only the explicit `-o/--output` flag is honoured. The wrapper scripts always pass `--output` per call, so this does not affect them — but raw `bb` invocations need the flag too.

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `bb: command not found` | `bb` not on PATH | `bb` is installed via Nix on this host; rebuild: `just build && sudo darwin-rebuild switch --flake .` |
| `jq: command not found` | `jq` not on PATH | Already in `home.packages`; same rebuild fix |
| `Error: Invalid PR ID` | Non-numeric input | Use numeric PR/comment/task ID |
| `This command expects … on stdin` | Forgot to pipe content | `echo "text" \| ${CLAUDE_SKILL_DIR}/scripts/...` (or use a here-doc) |
| `pr task --help` unknown command | `bb` is pre-v0.18.0 | Confirm `bb --version` reports `0.18.0`; tasks require v0.18.0+ |
| Auth / 401 errors | Profile not set up or token expired | Reconfigure with `bb profile create` / `bb profile update`; check `BB_PROFILE` |
| `Error: Argument repository is missing` (or operates on the wrong repo) | CWD has no `bitbucket.org` remote — script run from the skill dir, `/tmp`, or a non-Bitbucket repo | Invoke via `${CLAUDE_SKILL_DIR}/scripts/…` from **inside the target repo's working tree**; never `cd` into the skill directory. (You'll also see the non-fatal "No bitbucket.org git remote" warning.) |
| `task resolve`/`reopen` rejected / invalid state | Used `needs_work`/`complete`/`pending` from `bb`'s `--state` help | Those values are wrong; the API only accepts `RESOLVED`/`UNRESOLVED` — the wrapper's `resolve`/`reopen` already send the correct ones. See [§9](#9-known-quirks). |
| Output goes to a tempfile (header + preview only) | Output exceeded `BB_OUTPUT_MAX_BYTES` (default 32 KB) | Read the tempfile with `jq . <path>` / `column -t -s $'\t' <path>`, or raise the cap: `BB_OUTPUT_MAX_BYTES=65536 …`. For `list`, try `--format tsv` first — it's usually small enough to stay inline. |
| `ERROR: This script requires zsh but is running under bash.` | Invoked via `bash ${CLAUDE_SKILL_DIR}/scripts/...` | Run the script directly (`${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh ...`) or with `zsh ${CLAUDE_SKILL_DIR}/scripts/...`. |
| (JIRA bridge) `Missing Jira credentials` | `JIRA_URL`/`JIRA_USERNAME`/token absent from env **and** `$SOPS_SECRETS_DIR` | Set the env vars, or ensure the `jira_url`/`jira_username`/`jira_api_token` sops-nix secrets exist; confirm with `bitbucket_jira.sh whoami`. |
| (JIRA bridge) empty `pullRequests` / `detail: []` | `--application-type stash` against a Cloud site, or the issue has no linked dev data | Use the default `bitbucket`; verify the issue really has a linked branch/PR. |
| (JIRA bridge) `HTTP 401/403` | Wrong account/token, or token lacks access | `bitbucket_jira.sh whoami` shows the token's account; use the Jira token via Basic auth (not a Bitbucket Bearer token). |
| (JIRA bridge) PR URL full of `%7B…%7D` UUIDs | `--no-resolve-repo` used, or multiple repos linked to the issue | Run without `--no-resolve-repo`; for multi-repo issues take the slug from `bitbucket_jira.sh repos`. |

## 9. Known quirks

> The `bb pr update` "unsupported protocol scheme" bug
> ([gildas/bitbucket-cli#92]) is **fixed in v0.18.1** — the version installed via
> Nix on this host. `update` now works through the script directly; no workaround
> needed.

[gildas/bitbucket-cli#92]: https://github.com/gildas/bitbucket-cli/issues/92

### `bb pr task update --state` help lists the wrong values

`bb pr task update --help` (through v0.18.1) advertises:

```
--state string   Updated state of the task. Can be one of needs_work, complete or pending
```

Those values are **wrong**: the Bitbucket Cloud REST API only accepts `RESOLVED`
and `UNRESOLVED` for task state, and passing `needs_work` / `complete` /
`pending` is rejected. The `resolve` / `reopen` subcommands of
`bitbucket_pr_tasks.sh` already send `--state RESOLVED` / `--state UNRESOLVED`,
so this only bites if you edit the wrapper or call raw `bb` — **do not** "fix"
the mapping to match the help text. Unlike the now-fixed `pr update` bug noted
above, this is a documentation defect, not tied to a release: the `RESOLVED` /
`UNRESOLVED` API contract is permanent, so this note stays even after `bb`
upgrades.

## 10. What this skill does NOT do

By design, the scripts **do not** wrap these operations. If a user explicitly requests one, run raw `bb` and **always confirm before executing**:

- **`bb pr merge`** — merges PR code into the destination branch (irreversible)
- **`bb pr decline`** — closes a PR
- **`bb pr approve` / `unapprove` / `request-changes`** — review state changes that show up as you, the operator
- **`bb pr comment delete`** / **`bb pr task delete`** — destroy review history

For everything else (anything not listed in §1 as "Read" or "Write (safe)"), prefer raw `bb <subcommand> --help` and surface the command to the user before running it.

## 11. JIRA → Bitbucket bridge

`bitbucket_jira.sh` answers **"which Bitbucket PRs/branches belong to this JIRA
issue?"** — something `bb` cannot do (it only sees the current repo's git remote).
Bitbucket reports development data back to Jira; this script reads it from Jira's
**dev-status** REST endpoint. It is **workspace-global**: it talks to the Jira REST
API directly, runs from **any CWD**, and uses `curl` + `jq` (no `bb`, no git).

### Credentials (env first, then sops-nix files)

Resolved in this order — the first non-empty wins; missing values produce a clear
error listing what to set:

| Value          | env                                        | else file in `$SOPS_SECRETS_DIR` (default `~/.config/sops-nix/secrets`) |
|----------------|--------------------------------------------|------------------------------------------------------------------------|
| Base URL       | `JIRA_URL`                                 | `jira_url`                                                              |
| Username/email | `JIRA_USERNAME`                            | `jira_username`                                                         |
| API token      | `JIRA_API_TOKEN` → `ATLASSIAN_API_TOKEN`   | `jira_api_token` → `atlassian_c24_bitbucket_api_token`                  |

Auth is **HTTP Basic** (`"$JIRA_USERNAME:$JIRA_API_TOKEN"`) against the Jira site —
an Atlassian API token works for Jira this way. (The same token does **not** work as
a Bearer token against `api.bitbucket.org`; use the bridge, not raw Bitbucket API
calls.) These are the same secrets the Atlassian MCP server uses.

### Commands

```bash
# Resolve a Jira key to its numeric issue id (dev-status needs the id, not the key).
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh id VUKFZIF-2978              # → 123456
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh id VUKFZIF-2978 --format json # → {id,key,summary}

# Pull requests linked to an issue (key OR numeric id). By default also resolves the
# repo slug and rewrites the UUID-based PR URL to a clean one (single-repo case).
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh prs VUKFZIF-2978
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh prs VUKFZIF-2978 --state MERGED   # client-side filter
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh prs VUKFZIF-2978 --format tsv      # id, status, source, dest, repo, url, title
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh prs VUKFZIF-2978 --no-resolve-repo # skip the extra repository call (raw UUID URL)

# Linked branches and repositories
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh branches VUKFZIF-2978
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh repos    VUKFZIF-2978              # prints the <workspace>/<slug>

# Which account does the token belong to? (verifies auth; don't guess the login)
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh whoami
```

`prs` JSON shape: `{ issue: {id, key}, repositories: [{name, url, slug}], pullRequests:
[{id, status, title, source, destination, author, lastUpdate, url, repo}] }`. With a
single linked repo, each PR's `repo` is the `<workspace>/<slug>` and `url` is rewritten
to `https://bitbucket.org/<slug>/pull-requests/<id>`. `--format tsv` emits one PR per
row. Output spills to a tempfile past `BB_OUTPUT_MAX_BYTES`, same as the `bb` wrappers.

### End-to-end: from a JIRA key to that PR's review surface

The repo is usually **not** cloned locally, so feed the slug into the `bb` wrappers via
`--repo` (see [§3](#3-usage-by-resource)) — no checkout required:

```bash
# 1. Find the PR id + repo slug for the ticket
${CLAUDE_SKILL_DIR}/scripts/bitbucket_jira.sh prs VUKFZIF-2978 --format tsv
#    1309   OPEN   feature/x   master   check24/kfz-if-versicherer   https://…/pull-requests/1309   …

# 2. Read its comments / tasks from anywhere, targeting that repo explicitly
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh list 1309 --repo check24/kfz-if-versicherer
${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh    list 1309 --repo check24/kfz-if-versicherer
```

### Notes & gotchas

- **`applicationType` must be `bitbucket`** (Bitbucket Cloud), the default. `stash`
  (Bitbucket Server) returns an empty `detail: []` against a Cloud site. Override with
  `--application-type T` or `$JIRA_DEV_APPLICATION_TYPE` only if you know you need it.
- **Numeric issue id required by dev-status.** The script resolves a key → id for you
  via `/rest/api/3/issue/{KEY}`; pass either a key or an id.
- **UUID URLs.** dev-status PR URLs contain workspace/repo **UUIDs**, not slugs. `prs`
  resolves the slug (one extra `dataType=repository` call) and cleans the URL when a
  single repo is linked; with multiple repos it leaves the raw URL and lists the repos.
- Exit codes match the rest of the skill (§6): `2` = missing prereq/credentials,
  `3` = API/auth/network (run `whoami` to check the token), `4` = issue/resource not found.
