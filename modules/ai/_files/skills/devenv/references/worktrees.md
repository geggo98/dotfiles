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

### Does a background hook survive the end of its caller?

Origin of the question: a comment in a local project configuration of the user says that
a background `post-start` build was killed in the middle of the compile when the caller
(an agent or a script) ended right after `wt switch`. The project is not named here,
because this repository is public. The comment is the only source.

Measured on 17.11.2026 on macOS with the installed `wt` (`wt --version` prints
`wt 0807dc3`), in a scratch repository, one run per variant. The project hook was
`sleep 4` followed by writing a file; no real build ran. A Python test program started
`wt` as the leader of a new process group and waited until `wt` returned. It then sent
the signal shown to the process group named in the table and looked for the file 7 s
after `wt` had returned (variant F: 8 s after the signal):

| Variant | Call | Signal after the call returned | Sent to | File present |
|---|---|---|---|---|
| A | `wt hook post-start` | none | none | yes |
| B | `wt hook post-start` | SIGTERM | process group of `wt` | yes |
| C | `wt switch --create` | none | none | yes |
| D | `wt switch --create` | SIGTERM | process group of `wt` | yes |
| E | `wt switch --create` | SIGKILL | process group of `wt` | yes |
| F | `wt hook post-start` | SIGKILL | process group of the hook | no |

The core of the test program (hook: `build = "sleep 4; date +%s > \"{{ worktree_path }}/marker\""`
under `[post-start]` in the scratch repository's `.config/wt.toml`; `-y` skips the
approval prompt of that scratch project):

```python
p = subprocess.Popen(["wt", "hook", "post-start", "-y"], cwd=repo, start_new_session=True)
p.wait()
os.killpg(p.pid, signal.SIGTERM)   # B; D and E: `wt switch --create c1 -y --no-cd` with SIGTERM / SIGKILL
time.sleep(7)
print(os.path.exists(marker))
```

The call returned after 0.1 to 0.4 s. The test program had made `wt` the leader of a new
process group and session. A process listing (`ps -axo pid=,ppid=,pgid=,command=`) taken
right after `wt hook post-start` returned shows the hook's shell and its `sleep` in a
different process group than `wt`. A signal to the process group of `wt` therefore cannot
reach the hook, so B shows only that the hook is not in that group; it does not show that
the hook withstands a signal. For `wt switch --create` (C to E) no listing was taken, so
those variants show only that the file appeared. Variant F signalled the group id read
from the listing, the group of the hook's shell, and the hook died.

Not measured: the name of the process that leads the hook's group; the process listing
for `wt switch --create` and for `wt hook post-switch`; a caller or environment that ends processes by other means, for
example an IDE or agent harness that tracks jobs or sessions; a real build hook (devenv,
Gradle); hooks that outlive a time limit of the caller. These measurements therefore
neither confirm nor explain the older observation. If your caller ends its background
processes, use a blocking hook (`pre-start`) or `wt hook post-start --foreground` (the
flag appears in `wt hook post-start --help`; it was not run here). The price is that the
creation waits for the build. For the IntelliJ script, the foreground variant needs a
change in `modules/worktrunk.nix`, because the script calls `wt hook post-start` without
`--foreground`.

## Approval

Worktrunk runs a project hook only after the user has approved it, and asks again
whenever the command changes (stated in the documentation of the `worktrunk` skill;
observed on 17.11.2026: after a hook command had changed, `wt config approvals list`
printed "Approved commands no longer in project config"). In a non-interactive session the
hook fails with `Cannot prompt for approval in non-interactive environment`. The user
approves per repository:

```bash
wt config approvals add
```

An agent does not pass `--yes` on its own initiative. The approval is the user's decision
about whether the repository may run commands on the machine.

Measured on 17.11.2026 with `wt 0807dc3`, in a real project repository with two
unapproved hook commands and stdin from `/dev/null`: `wt config approvals add` listed the
two commands, printed `Cannot prompt for approval in non-interactive environment` and
approved nothing (a later `wt config approvals list` still showed both as unapproved).
`wt config approvals list` prints an `APPROVED` and an `UNAPPROVED` section. The only
non-interactive way that was tested is `wt config approvals add --yes`. It was run on
17.11.2026 in 24 repositories, each time after the check described below; afterwards
`wt config approvals list` showed no unapproved command in any of them. `--yes` is listed
under "Global Options" in `wt config approvals --help`. `wt hook …` has its own `--yes`,
which `wt hook pre-start --help` describes as skipping the approval prompts for project
hooks; whether that stores an approval was not tested. `wt config approvals add --yes`
approves every command the repository declares (that is why the check below comes first).

Exception: when the user explicitly asks the agent to approve the hooks of repositories
the user names, the agent first lists the unapproved commands of each repository with
`wt config approvals list`, and approves a repository only if every listed command is on
a list of commands that the user has seen in advance. Any other command: the agent skips
that repository and reports it.

Origin of the exception: on 17.11.2026 the user asked an agent to approve the hooks of
many repositories in one go. The agent used a list of four commands (`wt step copy-ignored`,
`devenv tasks run agent:build`, `devenv tasks run agent:install`,
`devenv shell -- uv sync`).


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
`devenv`, `direnv`, `git` and `coreutils` first, then IntelliJ's own `PATH`, then
`/etc/profiles/per-user/<user>/bin`,
`/run/current-system/sw/bin`, `/nix/var/nix/profiles/default/bin` and
`/opt/homebrew/bin`. It assumes the worktree is the first argument (unverified, see "Open
questions" below) and opens the log
`~/Library/Logs/wt-intellij-setup/<time>-<name>.log` before it checks the argument
(`<time>` is `YYYYMMDDTHHMMSS`; `<name>` is the last path component of the argument, or
`no-argument`), so a missing or wrong argument leaves a trace. The first line of the log
reads `start <YYYY-MM-DD HH:MM:SS> argument=<argument> cwd=<directory>`. The script then runs
`wt hook pre-start` (blocking), `wt hook post-start` and `wt hook post-switch`
(background). `wt hook <type>` runs the configured hooks of that type in the current
worktree; these are the hooks `wt switch --create` would have run.

If the script fails, read the newest log first
(`ls -t ~/Library/Logs/wt-intellij-setup | head -1`). The script runs with `set -e`. A
failure of `wt hook pre-start` ends it with the same exit code and a message in the log; a
known cause, seen in a test on 16.11.2026, is a project hook that the user has not
approved yet (see "Approval"). The script's own hint says to run
`wt config approvals add` "once"; that is shortened, because the call is needed again
after a hook command changes. A failing `git -C <argument> rev-parse --show-toplevel`
(a wrong argument; git exits with 128) or a failing `wt hook post-start` or
`wt hook post-switch` also ends the script, with that command's exit code and without a
message of the script's own.

Open questions. Status on 17.11.2026: not yet checked in a real IntelliJ. The script, as
built by `just build-host` on 16.11.2026, was run by hand in scratch repositories with
`PATH=/usr/bin:/bin` and a worktree created by `git worktree add` as argument. The log
showed the lines of `+wt-inherit-trust` (direnv and devenv approval were exercised with an
isolated `XDG_DATA_HOME`), and the exit code was 0, 1 (a project hook that was not
approved, with the approval hint in the log) or 2 (no argument, with a log). `wt` was
`wt 0807dc3`. Not covered: an IntelliJ launched from the Dock or Finder, which inherits
only the minimal `PATH` of launchd instead of a shell's `PATH`, and project hooks that run
a real build. The background `post-start` hook is not in the process group of
`wt hook post-start` (measured only for that call; `post-switch` and `wt switch --create`
were not listed; see "Does a background hook survive the end of its caller?"). That does
not show how IntelliJ ends a script's processes. Check once in IntelliJ:

- Whether IntelliJ ends the background hooks. The log of the project's `post-start` build
  hook (here `devenv tasks run agent:build`), listed by `wt config state logs`, should end
  with the build's last output line if they survived (the logs of a surviving and of a
  killed hook were not compared). Another check: the build's output, for example compiled
  classes, exists after the 5-minute window. If they did not, change the script to
  run `wt hook post-start --foreground` (not run here). IntelliJ then waits for the build;
  what it does to a script that runs past its 5 minutes is not documented beyond the
  notification.
- The argument position. The first log line (`argument=…`) shows what the script
  received. No log at all means the script did not run (wrong path, not executable, or IntelliJ
  did not start it). A log named
  `…-no-argument.log` means IntelliJ passed no argument.


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
