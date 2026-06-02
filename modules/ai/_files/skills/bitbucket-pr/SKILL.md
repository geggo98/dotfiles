---
name: bitbucket-pr
description: "Read and manage Bitbucket Cloud pull requests, comments, and tasks via the `bb` CLI (gildas/bitbucket-cli v0.18.0+). Use when reviewing PR feedback, replying to comments, creating tasks/PRs, or marking review tasks done."
context: fork
allowed-tools: Bash(./scripts/bitbucket_pr.sh *) Bash(./scripts/bitbucket_pr_comments.sh *) Bash(./scripts/bitbucket_pr_tasks.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh *) Bash(${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh *) Bash(zsh *)
dependencies: "bb (Bitbucket CLI, installed via Nix on this host), jq"
---

# Bitbucket Pull Request Skill

A wrapper around `bb` (Bitbucket Cloud CLI) exposing **stable, read- and safe-write** operations on PRs, comments, and tasks. Destructive operations (`merge`, `decline`, any `delete`) are intentionally **not** wrapped — use raw `bb` with explicit user approval if you really need them.

> **⚠ Run these scripts from inside the target repository's git working tree, by their absolute `${CLAUDE_SKILL_DIR}/scripts/…` path — never `cd` into the skill directory.** `bb` resolves the workspace and repository from the **git remote of the current directory** (`--workspace`/`--repository` default to *"determined from the git configuration"*). A wrong CWD — the skill dir, `/tmp`, or any repo whose remote isn't `bitbucket.org` — fails with `Error: Argument repository is missing`. The scripts self-locate their own helpers (`${0:A:h}`), so the absolute path works from any CWD; just keep your shell in the repo you're operating on. The scripts emit a non-fatal warning when the current directory has no `bitbucket.org` remote.

## 1. Capability surface

| Resource | Read | Write (safe) | Hidden (raw `bb` only) |
|---|---|---|---|
| PR      | `list`, `get` | `create`, `update` (title / description) | `merge`, `decline`, `approve`, `unapprove`, `request-changes` |
| Comment | `list`, `get` | `create`, `update`, `resolve`, `reopen` | `delete` |
| Task    | `list`, `get` | `create`, `update`, `resolve`, `reopen` | `delete` |

Bitbucket's hierarchy: **PR → comment → task** (tasks may also live on the PR with no parent comment).

## 2. Helper scripts

| Script | Purpose |
|---|---|
| `${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh`          | PR-level operations |
| `${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_comments.sh` | Comment operations |
| `${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr_tasks.sh`    | Task operations    |

All three are **zsh** scripts that source `${CLAUDE_SKILL_DIR}/scripts/_lib.sh` for shared helpers (logging, prerequisite checks, stdin reading, output buffering). Run them directly — they refuse to run under bash. Run any script with `--help` for its full grammar. All three share the same exit codes and env vars (see §6, §7).

## 3. Usage by resource

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

> **⚠ `update` is broken in bb v0.18.0** — see [§9 Known bugs](#9-known-bugs-bb-v0180). Until `bb ≥ 0.18.1` ships, use the `curl` REST workaround documented there for `update`. `create` is unaffected and should still go through this script (it pipes the description to `bb` via stdin, sidestepping heredoc escaping problems that bite when calling `bb pr create --description "..."` inline).

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
| 2 | `bb` or `jq` not on PATH |
| 3 | `bb` invocation failed (network, auth, server error) |
| 4 | PR / comment / task not found |

## 7. Environment variables

| Variable               | Description                                                                                  |
|------------------------|----------------------------------------------------------------------------------------------|
| `BITBUCKET_CLI`        | Path to the `bb` binary (default `bb`)                                                       |
| `JQ_PATH`              | Path to `jq` (default `jq`)                                                                  |
| `BB_OUTPUT_MAX_BYTES`  | Spill output larger than this to a tempfile (default `32768`; matches `database` skill)      |
| `BB_PROFILE`           | (Read by `bb`) which profile to use                                                          |
| `BB_OUTPUT_FORMAT`     | (Documented for `bb` — but see warning below)                                                |

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
| `task resolve`/`reopen` rejected / invalid state | Used `needs_work`/`complete`/`pending` from `bb`'s `--state` help | Those values are wrong; the API only accepts `RESOLVED`/`UNRESOLVED` — the wrapper's `resolve`/`reopen` already send the correct ones. See [§9](#9-known-bugs-bb-v0180). |
| `bb pr update`: `unsupported protocol scheme ""` | Bug in `bb` v0.18.0 (URL built without API base) | See [§9 Known bugs](#9-known-bugs-bb-v0180) — use `curl` REST workaround |
| Output goes to a tempfile (header + preview only) | Output exceeded `BB_OUTPUT_MAX_BYTES` (default 32 KB) | Read the tempfile with `jq . <path>` / `column -t -s $'\t' <path>`, or raise the cap: `BB_OUTPUT_MAX_BYTES=65536 …`. For `list`, try `--format tsv` first — it's usually small enough to stay inline. |
| `ERROR: This script requires zsh but is running under bash.` | Invoked via `bash ${CLAUDE_SKILL_DIR}/scripts/...` | Run the script directly (`${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh ...`) or with `zsh ${CLAUDE_SKILL_DIR}/scripts/...`. |

## 9. Known bugs (bb v0.18.0)

### `bb pr update` fails with `unsupported protocol scheme ""`

**Affected:** `${CLAUDE_SKILL_DIR}/scripts/bitbucket_pr.sh update` (every flag combination). `list`, `get`, `create` are *not* affected.

**Symptom:**

```
Failed to get pullrequest <id>: error.runtime
Caused by:
    Get "pullrequests/<id>": unsupported protocol scheme ""
```

**Cause:** `bb pr update` fetches the current PR before patching, but builds the GET URL as a bare path (`pullrequests/<id>`) instead of prefixing the API base (`https://api.bitbucket.org/2.0/repositories/<ws>/<repo>/`). Go's `http.Client` rejects relative URLs. Reproduce with `LOG_LEVEL=DEBUG LOG_DESTINATION=stderr bb pr update …`. `--workspace`, `--repository`, `--profile` do not change the behaviour.

**Upstream status:** [gildas/bitbucket-cli#92](https://github.com/gildas/bitbucket-cli/issues/92) — open, labelled `bug`. Fixed on the [`dev` branch](https://github.com/gildas/bitbucket-cli/tree/dev) (commits `b833434` "missing path join", plus follow-ups `45ef589`, `d0e1ac9`, `dcb23cf` for the workspace-resolution chain that surfaces once the URL bug is gone). **No release tag yet** as of 2026-05-26 — owner has stated a new version is forthcoming. Delete this section once `bb ≥ 0.18.1` is installed via Nix and verified.

**Workaround:** call the Bitbucket Cloud REST API directly with `curl`. Credentials live in `~/Library/Application Support/bitbucket/config-cli.yml` (the `user:` / `password:` fields — an App Password with `pullrequest:write` scope).

```bash
USER_BB=$(grep '^      user:'     "$HOME/Library/Application Support/bitbucket/config-cli.yml" | awk '{print $2}')
PASS_BB=$(grep '^      password:' "$HOME/Library/Application Support/bitbucket/config-cli.yml" | awk '{print $2}')

WORKSPACE=<workspace>
REPO=<repo>
PR_ID=<id>

# Write the description to a file, then lift it into the JSON body via jq.
# This avoids heredoc / shell-quoting issues (literal \" and \* leaking into
# the published description).
DESC_FILE=$(mktemp -t "pr-${PR_ID}-description.XXXXXX") || exit 1
trap 'rm -f "$DESC_FILE"' EXIT
cat > "$DESC_FILE" <<'MD'
## Summary
- …
MD

JSON_BODY=$(jq -n --arg desc "$(cat "$DESC_FILE")" '{description: $desc}')

curl -fsS -u "$USER_BB:$PASS_BB" -X PUT \
  -H "Content-Type: application/json" \
  -d "$JSON_BODY" \
  "https://api.bitbucket.org/2.0/repositories/$WORKSPACE/$REPO/pullrequests/$PR_ID"
```

Other fields go in the same JSON body: `title`, `destination: {branch: {name: "<branch>"}}`, `reviewers: [{uuid: "<uuid>"}]`. The REST `PUT` performs a *partial* update — only the supplied fields change. See the [Bitbucket Cloud REST API v2.0 docs](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/#api-repositories-workspace-repo-slug-pullrequests-pull-request-id-put) for the full schema.

### `bb pr task update --state` help lists the wrong values

`bb pr task update --help` (v0.18.0) advertises:

```
--state string   Updated state of the task. Can be one of needs_work, complete or pending
```

Those values are **wrong**: the Bitbucket Cloud REST API only accepts `RESOLVED`
and `UNRESOLVED` for task state, and passing `needs_work` / `complete` /
`pending` is rejected. The `resolve` / `reopen` subcommands of
`bitbucket_pr_tasks.sh` already send `--state RESOLVED` / `--state UNRESOLVED`,
so this only bites if you edit the wrapper or call raw `bb` — **do not** "fix"
the mapping to match the help text. Unlike the `pr update` bug above, this is a
documentation defect, not tied to a release: the `RESOLVED` / `UNRESOLVED` API
contract is permanent, so this note stays even after `bb` upgrades.

## 10. What this skill does NOT do

By design, the scripts **do not** wrap these operations. If a user explicitly requests one, run raw `bb` and **always confirm before executing**:

- **`bb pr merge`** — merges PR code into the destination branch (irreversible)
- **`bb pr decline`** — closes a PR
- **`bb pr approve` / `unapprove` / `request-changes`** — review state changes that show up as you, the operator
- **`bb pr comment delete`** / **`bb pr task delete`** — destroy review history

For everything else (anything not listed in §1 as "Read" or "Write (safe)"), prefer raw `bb <subcommand> --help` and surface the command to the user before running it.
