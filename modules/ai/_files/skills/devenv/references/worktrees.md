# Git Worktrees with devenv

Read this file when a devenv project is used from several git worktrees, in particular
when an IDE creates the worktrees. Worktrunk (`wt`, a command-line tool for git
worktrees with lifecycle hooks; its own documentation is in the `worktrunk` skill) manages
the worktrees; devenv builds the project. The two meet in two places: the `agent:build`
task and the hooks in the project's `.config/wt.toml`.

Terms.

- The *primary worktree* is the original checkout of the repository; every other
  worktree is linked to it.
- Hooks: `pre-start` runs when worktrunk creates a worktree and blocks; `post-start` runs
  right after creation in the background; `post-switch` runs in the background on every
  switch to a worktree, new or existing. `wt step copy-ignored` copies the gitignored
  files of the primary worktree into the current one and skips files that already exist.
- A command written `+name` (for example `+wt-intellij-setup`) is a program that
  home-manager installs into `/etc/profiles/per-user/<user>/bin`.
- Paths such as `modules/worktrunk.nix` refer to the nix-darwin repository, checked out at
  `~/.config/nix-darwin` on the machines it configures. It defines the user-level setup
  described here. Other repositories do not have these helpers; the project template
  below works without them.

## Why a new worktree needs setup

A git worktree shares the repository but not the untracked files. A fresh worktree has
no gitignored files (a gitignored `.envrc`, the `.devenv/` cache, build output), and
neither direnv nor devenv has approved it. Tests and the language server fail until
someone prepares it.

`wt switch --create` runs worktrunk hooks that prepare it. An IDE that runs
`git worktree add` itself triggers none of them. The section "IntelliJ" below closes
that gap.

## The `agent:build` task

Define one fast build that makes tests and the language server work, and give it the
name `agent:build` (namespace convention: `tasks.md` in this directory). The contract
below narrows the generic `agent:build` example in the section "Tasks" of `SKILL.md`
(one directory up; a packaging build) for use as a worktree hook.

```nix
{
  tasks."agent:build".exec = "gradle classes testClasses --no-build-cache";   # example: Gradle
}
```

Contract:

- Fast and incremental: compile main and test code, but run no tests.
- Safe to run twice: a second run in an unchanged tree is a no-op.
- Exits non-zero on a build failure, so a hook log shows the failure.

Run it as `devenv tasks run agent:build`, without `devenv shell --` in front.
Measured on 16.11.2026 with devenv 2.3.1: a task started by `devenv tasks run` sees the
packages of `devenv.nix` on its `PATH`. A throwaway task that ran `command -v hello`
found `hello` in the `/nix/store` both with and without `devenv shell --` in front. A
failing task gives exit code 1. The `devenv shell --` prefix evaluates the environment a
second time and adds nothing. Limit: this holds for the tested version; if a task misses
a tool, retry with `devenv shell --` first.

## Project template `.config/wt.toml`

This file lives in the root of the project repository, not in `~/.config` (the
user-level worktrunk file is `~/.config/worktrunk/config.toml`).

```toml
# Prepare a new worktree. Checked in, so every teammate gets it.

[pre-start]
# Blocking. A new worktree has no gitignored files (.envrc, caches). Copy them from the
# primary worktree before anything else runs. Existing files are skipped, so a second
# copy by a user-level hook does no harm.
copy = "wt step copy-ignored"

[post-start]
# Background. The build can take minutes; creating the worktree must not wait for it.
build = "devenv tasks run agent:build"
```

Origin of the split: `pre-*` hooks block and abort the operation on failure; `post-*`
hooks run in the background and write a log (`wt config state logs`). The copy must
finish before the build starts, so it goes to `pre-start`. The build goes to
`post-start`, so a slow or failing build never blocks or aborts the creation.

Limit: user-level and project-level `post-start` hooks run at the same time. A
user-level `post-start` hook that the build depends on can lose that race. Put such a
hook into `pre-start` instead.

## Approval

Worktrunk runs a project hook only after the user has approved it, and asks again
whenever the command changes. In a non-interactive session the hook fails with
`Cannot prompt for approval in non-interactive environment`. The user approves once per
repository:

```bash
wt config approvals add
```

An agent never passes `--yes` to skip this. The approval is the user's decision about
whether the repository may run commands on the machine.

## Approval of direnv and devenv

direnv approves an `.envrc` by path and content, so a copied or checked-out `.envrc` is
unapproved. `devenv allow` is a separate approval: it lets devenv's shell integration
(set up by `eval "$(devenv hook zsh)"` in the shell startup file; this repository does it
in `modules/shells.nix`) activate the
environment automatically when you enter the directory. It is stored per directory, one JSON line per directory, in
`$XDG_DATA_HOME/devenv/allowed` (default `~/.local/share/devenv/allowed`); that format is
internal to devenv 2.3.1 and may change.

A blind `allow` in every new worktree would run code from a foreign branch, for example a
checked-out pull request, wherever the project tracks `.envrc` or `devenv.nix` in git. In
particular `devenv.nix` is always tracked, so a branch can change it.

The user-level worktrunk configuration (`modules/worktrunk.nix`) inherits the approval
instead. Its hook `+wt-inherit-trust` (source:
`modules/_files/worktrunk/wt-inherit-trust.py`) runs `direnv allow` only for an `.envrc`
that is byte-identical to the approved one in the primary worktree; this covers a
tracked and a gitignored `.envrc` alike. The hook is a user-level `pre-start` step that
runs after `wt step copy-ignored`, so the approval is in place before any project
`post-start` hook starts. It runs `devenv allow` only if `devenv.nix` and
`devenv.yaml` are identical to the primary worktree's and that worktree is approved; this
check is independent of the `.envrc` check and needs a `devenv.nix` in the new worktree.
Each of the two checks prints one line on stderr: `allowed`, `skip, <reason>`, or a
failure message. A skip or failure leaves that tool unapproved. The hook exits 0 in every
case, so the creation succeeds, with one exception: wrong arguments (exit 2), which the
configured hook cannot produce. When the new worktree is the primary worktree itself, it
prints one line, `skip, this is the primary worktree`, and runs neither check.
Teammates without `+wt-inherit-trust` approve by hand (`direnv allow`, `devenv allow`). Do not put
a blind `allow` into the project `.config/wt.toml`: that file arrives with every branch.

Limit: the check does not compare files that `devenv.nix` imports.

## IntelliJ

IntelliJ creates worktrees itself and offers a setup script for them. Source: the
JetBrains page "Use Git worktrees" (IntelliJ IDEA 2026.3),
https://www.jetbrains.com/help/idea/use-git-worktrees.html, read on 16.11.2026.

Configure it per worktree, in the New Worktree dialog (Git | New Worktree): expand
"Copy local project setup", select "Run setup script", and enter the absolute path of
the script:

```
/etc/profiles/per-user/<user>/bin/+wt-intellij-setup
```

Documented behaviour: IntelliJ runs the script in the new worktree, passes the worktree
path as argument, and waits up to 5 minutes. On failure or timeout it shows a
notification and keeps the worktree. It does not run the script when the worktree is
opened for a pull or merge request. The page does not say which `PATH` the script gets,
at which argument position the path arrives, or whether the script's output is shown
anywhere; it mentions only the notification on failure.

`+wt-intellij-setup` (defined as `wt-intellij-setup` in `modules/worktrunk.nix`;
overview in `docs/ai-tooling.md`) therefore sets its own `PATH`: the Nix-built `wt`,
`devenv`, `direnv` and `git` first, then `/etc/profiles/per-user/<user>/bin`,
`/run/current-system/sw/bin`, `/nix/var/nix/profiles/default/bin` and
`/opt/homebrew/bin`. It takes the worktree from the first argument and opens the log
`~/Library/Logs/wt-intellij-setup/<time>-<name>.log` before it checks the argument
(`<time>` is `YYYYMMDDTHHMMSS`; `<name>` is the last path component of the argument, or
`no-argument`), so a missing or wrong argument leaves a trace. (`wt hook <type>` runs the configured hooks of that type in
the current worktree.) It then runs `wt hook pre-start` (blocking),
`wt hook post-start` and `wt hook post-switch` (background), which are the hooks
`wt switch --create` would have run.

If the script fails, read the newest log first. A failure of `pre-start` ends the script
with the same exit code; the most common cause is a project hook that the user has not
approved yet (see "Approval").

Open questions. Status on 16.11.2026: not yet checked in a real IntelliJ; the script was
run by hand with a minimal `PATH` only. Check once: whether the background hooks survive
the end of the script (a complete build log in `wt config state logs` shows it), and the
argument position (the first log line, `argument=…`, shows what the script received; no
log at all means IntelliJ did not start the script; a log named `…-no-argument.log`
means it passed no argument).

## Worktree location

IntelliJ proposes a directory next to the repository, named after the repository and the
branch, and JetBrains advises against a location inside the project (same page as above).
Worktrunk's `worktree-path` template (`.worktrees/{{ branch | sanitize }}`, set in
`modules/worktrunk.nix`) names a different place: a `.worktrees/` directory inside the
primary worktree. That directory is ignored by the user-level global git ignore
(`modules/git.nix`), not by the project, so on a machine without that ignore it shows up
as untracked. Both layouts work: `wt switch <branch>` finds a worktree by
its branch, wherever it lives, and `wt list` shows the path. In IntelliJ's dialog, keep
the suggested location outside the repository.
