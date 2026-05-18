---
name: pr-bb
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

Run any script with `--help` to see its full grammar. All three share the same exit codes and env vars (see §6, §7).

## 3. Usage by resource

### Pull requests

```bash
# List open PRs in the workspace/repo configured for bb
./scripts/bitbucket_pr.sh list                 # default state OPEN
./scripts/bitbucket_pr.sh list MERGED          # OPEN | MERGED | DECLINED | SUPERSEDED

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

### Comments

```bash
# All comments on a PR (id + content + inline flag)
./scripts/bitbucket_pr_comments.sh list 1234

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
# All tasks on a PR
./scripts/bitbucket_pr_tasks.sh list 1234

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

- `list` / `get` commands return JSON (passed through `bb --output json`).
- `bitbucket_pr_comments.sh list` is **filtered** down to `{id, content, inline}` per comment for compactness; pipe through `jq` for filtering: `... list 1234 | jq 'map(select(.inline))'`.
- `bitbucket_pr_comments.sh get` returns the raw markdown body only (no JSON wrapper).
- Mutating commands echo the JSON of the created/updated resource on success.

## 6. Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Invalid arguments / missing stdin / bad flag |
| 2 | `bb` or `jq` not on PATH |
| 3 | `bb` invocation failed (network, auth, server error) |
| 4 | PR / comment / task not found |

## 7. Environment variables

| Variable        | Description                              |
|-----------------|------------------------------------------|
| `BITBUCKET_CLI` | Path to the `bb` binary (default `bb`)   |
| `JQ_PATH`       | Path to `jq` (default `jq`)              |
| `BB_PROFILE`    | (Read by `bb`) which profile to use      |
| `BB_OUTPUT_FORMAT` | (Read by `bb`) default output format  |

`bb` picks workspace/repository defaults from its own config (`~/.config/bitbucket/config-cli.yml` or `~/.bitbucket-cli`) and its keychain-stored credentials. The scripts pass `--output json` per call, so `BB_OUTPUT_FORMAT` does not affect them.

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `bb: command not found` | `bb` not on PATH | `bb` is installed via Nix on this host; rebuild: `just build && sudo darwin-rebuild switch --flake .` |
| `jq: command not found` | `jq` not on PATH | Already in `home.packages`; same rebuild fix |
| `Error: Invalid PR ID` | Non-numeric input | Use numeric PR/comment/task ID |
| `This command expects … on stdin` | Forgot to pipe content | `echo "text" \| ./scripts/...` (or use a here-doc) |
| `pr task --help` unknown command | `bb` is pre-v0.18.0 | Confirm `bb --version` reports `0.18.0`; tasks require v0.18.0+ |
| Auth / 401 errors | Profile not set up or token expired | Reconfigure with `bb profile create` / `bb profile update`; check `BB_PROFILE` |

## 9. What this skill does NOT do

By design, the scripts **do not** wrap these operations. If a user explicitly requests one, run raw `bb` and **always confirm before executing**:

- **`bb pr merge`** — merges PR code into the destination branch (irreversible)
- **`bb pr decline`** — closes a PR
- **`bb pr approve` / `unapprove` / `request-changes`** — review state changes that show up as you, the operator
- **`bb pr comment delete`** / **`bb pr task delete`** — destroy review history

For everything else (anything not listed in §1 as "Read" or "Write (safe)"), prefer raw `bb <subcommand> --help` and surface the command to the user before running it.
