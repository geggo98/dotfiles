---
name: bitbucket-pr
description: "Read and manage Bitbucket Cloud pull requests, comments, and tasks via the `bb` CLI (gildas/bitbucket-cli v0.18.0+). Use when reviewing PR feedback, replying to comments, creating tasks/PRs, or marking review tasks done."
context: fork
allowed-tools: Bash(./scripts/bitbucket_pr.sh *) Bash(./scripts/bitbucket_pr_comments.sh *) Bash(./scripts/bitbucket_pr_tasks.sh *) Bash(zsh *)
dependencies: "bb (Bitbucket CLI, installed via Nix on this host), jq"
---

# Bitbucket Pull Request Skill

A wrapper around `bb` (Bitbucket Cloud CLI) exposing **stable, read- and safe-write** operations on PRs, comments, and tasks. Destructive operations (`merge`, `decline`, any `delete`) are intentionally **not** wrapped — use raw `bb` with explicit user approval if you really need them.

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
./scripts/bitbucket_pr.sh list                       # default state OPEN, formatted JSON
./scripts/bitbucket_pr.sh list MERGED                # OPEN | MERGED | DECLINED | SUPERSEDED
./scripts/bitbucket_pr.sh list --format tsv          # ~10x smaller for browsing
./scripts/bitbucket_pr.sh list MERGED --format tsv

# Fetch one PR as JSON
./scripts/bitbucket_pr.sh get 1234

# Create a PR (description is optional, supplied via stdin)
echo "Closes #999. Background: …" | \
  ./scripts/bitbucket_pr.sh create "Add foo bar" feature/foo main

# Rename a PR
./scripts/bitbucket_pr.sh update 1234 --title "Better title"

# Replace the description (multiline markdown via stdin)
cat <<'MD' | ./scripts/bitbucket_pr.sh update 1234 --description-from-stdin
## Summary
- Did X
- Did Y

## Test plan
- [ ] Manual smoke
MD
```

> **⚠ `update` is broken in bb v0.18.0** — see [§9 Known bugs](#9-known-bugs-bb-v0180). Until `bb ≥ 0.18.1` ships, use the `curl` REST workaround documented there for `update`. `create` is unaffected and should still go through this script (it pipes the description to `bb` via stdin, sidestepping heredoc escaping problems that bite when calling `bb pr create --description "..."` inline).

### Comments

```bash
# All comments on a PR — JSON filtered to {id, content, inline}
./scripts/bitbucket_pr_comments.sh list 1234
# Or compact TSV (bb's native columns: id, created_on, updated_on, file, user, content)
./scripts/bitbucket_pr_comments.sh list 1234 --format tsv

# Raw markdown of one comment
./scripts/bitbucket_pr_comments.sh get 1234 5678

# Top-level comment
echo "**Heads up:** depends on #1230." | \
  ./scripts/bitbucket_pr_comments.sh create 1234

# Inline comment on a file/line
echo "Consider extracting this." | \
  ./scripts/bitbucket_pr_comments.sh create 1234 --file src/main.go --line 42

# Reply to an existing comment
echo "Agreed, will fix." | \
  ./scripts/bitbucket_pr_comments.sh create 1234 --parent 5678

# Edit a comment you (or the bot) wrote
echo "Updated wording." | \
  ./scripts/bitbucket_pr_comments.sh update 1234 5678

# Resolve / reopen
./scripts/bitbucket_pr_comments.sh resolve 1234 5678
./scripts/bitbucket_pr_comments.sh reopen  1234 5678
```

### Tasks (new in `bb` v0.18.0)

```bash
# All tasks on a PR — formatted JSON
./scripts/bitbucket_pr_tasks.sh list 1234
# Or compact TSV (id, state, creator, created_on, updated_on, resolved_on, resolved_by, content)
./scripts/bitbucket_pr_tasks.sh list 1234 --format tsv

# One task
./scripts/bitbucket_pr_tasks.sh get 1234 4242

# Standalone PR task
echo "Update CHANGELOG for the release." | \
  ./scripts/bitbucket_pr_tasks.sh create 1234

# Task attached to a comment (e.g., turn review feedback into an actionable item)
echo "Rename `foo` to `fooBar`." | \
  ./scripts/bitbucket_pr_tasks.sh create 1234 --comment 5678

# Edit task text
echo "Rename `foo` to `fooBaz` (renamed in spec)." | \
  ./scripts/bitbucket_pr_tasks.sh update 1234 4242

# Mark done / reopen
./scripts/bitbucket_pr_tasks.sh resolve 1234 4242
./scripts/bitbucket_pr_tasks.sh reopen  1234 4242
```

## 4. Common review workflow

```bash
# 1. Pull the discussion surface
./scripts/bitbucket_pr_comments.sh list 1234 > /tmp/comments.json
./scripts/bitbucket_pr_tasks.sh    list 1234 > /tmp/tasks.json

# 2. For each unresolved task, decide: fix in code, reply in thread, or close.
#    After implementing each fix:
./scripts/bitbucket_pr_tasks.sh resolve 1234 4242
echo "Fixed in <commit-hash>" | \
  ./scripts/bitbucket_pr_comments.sh create 1234 --parent <task-comment-id>
```

## 5. Output format

- **Default: pretty-printed JSON.** Every `list` / `get` / `create` / `update` / `resolve` / `reopen` call goes through `bb --output json` and the JSON is emitted verbatim (already indented by `bb`).
- **TSV opt-in on `list`:** every `list` command accepts `--format json|tsv`. TSV is `bb`'s native tab-separated output — roughly **10× smaller** than JSON for `pr list` (measured: 256 KB → 26 KB), **7×** for `comment list`, **12×** for `task list`. Use it when you only need to browse / pick an id and don't need to filter with `jq`.
- `bitbucket_pr_comments.sh list` (JSON path) is **filtered** down to `{id, content, inline}` per comment for compactness; pipe further through `jq` for selection: `... list 1234 | jq 'map(select(.inline))'`. The TSV path keeps `bb`'s columns: `id, created_on, updated_on, file, user, content`.
- `bitbucket_pr_comments.sh get` returns the raw markdown body only (no JSON wrapper); when spilled, the tempfile suffix is `.md`.
- **Spillover for large outputs.** If a command's output exceeds `BB_OUTPUT_MAX_BYTES` (default **32 768**), it is written to `${TMPDIR:-/tmp}/bb-<label>.XXXXXX.<ext>` (`<ext>` ∈ `json` / `tsv` / `md`) and stdout shows a header (size, line count, full path) followed by a 10-line preview. Read the full result with `jq . <path>` (JSON) or `column -t -s $'\t' <path>` (TSV). Raise the threshold if needed: `BB_OUTPUT_MAX_BYTES=65536 ./scripts/bitbucket_pr.sh get 1234`.

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

`bb` picks workspace/repository defaults from its own config (`~/.config/bitbucket/config-cli.yml` or `~/Library/Application Support/bitbucket/config-cli.yml`) and its keychain-stored credentials.

> **⚠ `BB_OUTPUT_FORMAT` is silently ignored by `bb` v0.18.0.** Running `env BB_OUTPUT_FORMAT=json bb pr list` falls back to the default `table` output (with ASCII borders) instead of JSON. Only the explicit `-o/--output` flag is honoured. The wrapper scripts always pass `--output` per call, so this does not affect them — but raw `bb` invocations need the flag too.

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `bb: command not found` | `bb` not on PATH | `bb` is installed via Nix on this host; rebuild: `just build && sudo darwin-rebuild switch --flake .` |
| `jq: command not found` | `jq` not on PATH | Already in `home.packages`; same rebuild fix |
| `Error: Invalid PR ID` | Non-numeric input | Use numeric PR/comment/task ID |
| `This command expects … on stdin` | Forgot to pipe content | `echo "text" \| ./scripts/...` (or use a here-doc) |
| `pr task --help` unknown command | `bb` is pre-v0.18.0 | Confirm `bb --version` reports `0.18.0`; tasks require v0.18.0+ |
| Auth / 401 errors | Profile not set up or token expired | Reconfigure with `bb profile create` / `bb profile update`; check `BB_PROFILE` |
| `bb pr update`: `unsupported protocol scheme ""` | Bug in `bb` v0.18.0 (URL built without API base) | See [§9 Known bugs](#9-known-bugs-bb-v0180) — use `curl` REST workaround |
| Output goes to a tempfile (header + preview only) | Output exceeded `BB_OUTPUT_MAX_BYTES` (default 32 KB) | Read the tempfile with `jq . <path>` / `column -t -s $'\t' <path>`, or raise the cap: `BB_OUTPUT_MAX_BYTES=65536 …`. For `list`, try `--format tsv` first — it's usually small enough to stay inline. |
| `ERROR: This script requires zsh but is running under bash.` | Invoked via `bash ./scripts/...` | Run the script directly (`./scripts/bitbucket_pr.sh ...`) or with `zsh ./scripts/...`. |

## 9. Known bugs (bb v0.18.0)

### `bb pr update` fails with `unsupported protocol scheme ""`

**Affected:** `./scripts/bitbucket_pr.sh update` (every flag combination). `list`, `get`, `create` are *not* affected.

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

## 10. What this skill does NOT do

By design, the scripts **do not** wrap these operations. If a user explicitly requests one, run raw `bb` and **always confirm before executing**:

- **`bb pr merge`** — merges PR code into the destination branch (irreversible)
- **`bb pr decline`** — closes a PR
- **`bb pr approve` / `unapprove` / `request-changes`** — review state changes that show up as you, the operator
- **`bb pr comment delete`** / **`bb pr task delete`** — destroy review history

For everything else (anything not listed in §1 as "Read" or "Write (safe)"), prefer raw `bb <subcommand> --help` and surface the command to the user before running it.
