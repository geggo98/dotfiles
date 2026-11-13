---
paths:
  - "justfile"
  - "scripts/**"
---

# Commands: the justfile, staging new files, applying the configuration

The `justfile` holds the commands an agent may run without asking. Raw `nix` and
`darwin-rebuild` commands need user approval. Three recipes use `sudo` and are for the user
only: `just switch`, `just switch-host` and `just daemon-restart`.

## Safe commands (via justfile, no approval needed)

| Command | Description |
|---|---|
| `just build` / `just build-host <host>` | Build (current or a specific) host config without applying |
| `just errlog-check` | Run the `+errlog` test suite in the Nix sandbox |
| `just check` / `just ai-check` / `just fmt-check` / `just eval` | `nix flake check`; isolated AI-aspect tests; format check; fast syntax check |
| `just fmt` | Format all Nix files with `nixpkgs-fmt` |
| `just vscode-ext-check` | Offline tests for `+vscode-ext` and the VS Code profile activation |
| `just update` / `-preview` / `-input <i>` / `-head` | Update flake inputs honouring the supply-chain cooldown (`-head` bypasses it) |
| `just audit` / `-inputs` / `-extensions [ids…]` / `-pins` | Cooldown and withdrawal audit: inputs, npm/GitHub package ages, VS Code extensions, hand-bumped pins behind upstream |
| `just update-pr [serial…]` | Check out the weekly update PR and build it (never switches); see `docs/supply-chain.md` |
| `just creds-check` | Do the long-lived credentials still authenticate? (jira, confluence, bb) |
| `just vscode-settings-check` | Has VS Code been trying to write the Nix-managed settings.json? |
| `just devdocs-list` / `-lock [families…]` / `-check` | DevDocs offline index: drift, re-lock, hermetic pipeline test |
| `just diff` / `just verify-no-diff` | Package delta vs. current system; assert no delta |
| `just deps` / `just show-derivation` | Flake dependency tree; derivation of current host build |
| `just cache-queue` / `just cache-prune <cat>` | R2 push queue depth/age; dry-run removal (`apply` is NOT agent-safe) |
| `just gc` / `just optimise` | User-level GC (7d) + sweep any running builder; hand store dedup |
| `just linux-builder-up/-status/-probe/-gc/-down [arch]` | Docker Linux builder lifecycle — see `docs/linux-builder.md` |
| `just linux-build <attr> [arch] false` | Build a flake attribute for Linux — trailing `false` skips the R2 push |

Four Linux-builder recipes are deliberately **absent** from that list, and not because they
need sudo:

- `just linux-build`/`nixos-build` **without** `push="false"`, and `just linux-push`,
  publish **signed** artifacts into the shared cache. An agent should not push there
  unsupervised — build with `push="false"` and let a human do the push.
- `just linux-builder-destroy` deletes a Docker volume and the keypair, and leaves a
  stale entry that needs a root `ssh-keygen -R` to clear.
- `just nixos-deploy <host>` activates a production system over ssh. Print it for the
  user instead, like `just switch`.

## New files: stage them before building

**Nix flakes only see git-tracked files.** Newly created files (modules, skill files,
references, templates, secrets — anything under the flake source) are **invisible** to
`nix build`, `just build`, `just eval`, and `darwin-rebuild` until at least
intent-to-added with `git add -N <paths>` (or fully staged with `git add <paths>`). The
flake build silently skips untracked files; the only hint is the
`warning: Git tree '…' has uncommitted changes` line, which fires even when nothing is
wrong.

After creating any new file, run:

```bash
git add -N <new-paths>      # intent-to-add is enough for flake to see them
just build                  # now picks up the new files
```

If a build seems to "ignore" your changes (a new module isn't applied, a new skill doesn't
appear, a new file referenced from a tracked module fails to load), check `git status`
first. Untracked files are the most common cause.

## Commands requiring user approval

These cannot run inside the agent sandbox or need explicit confirmation. **Agents must not
run them.** They need `sudo` and are interactive; print the command for the user instead:

```bash
just switch                       # apply config (see "Applying the configuration")
just switch --dry-run             # same, without applying
just switch-host DKL6GDJ7X1       # a specific host, by name
just daemon-restart               # restart nix-daemon; needed after first enabling
                                   # the R2 post-build-hook or a Linux builder (both
                                   # are read only at daemon startup) — see docs/nix-store.md
nix build .#darwinConfigurations.DKL6GDJ7X1.system   # or FCX19GT9XR
nix store diff-closures /run/current-system result
sudo nix-collect-garbage --delete-older-than 7d       # runs weekly anyway (modules/nix-gc.nix)
```

`auto-optimise-store` and the weekly `nix-optimise` dedup pass have daemon-restart and
timing traps of their own, measured — see `docs/nix-store.md` before touching either.

## Applying the configuration

Always apply via **`just switch`**, never a bare `sudo darwin-rebuild switch --flake .`.
A bare `--flake .` lets darwin-rebuild pick the flake attribute from the current hostname,
and macOS transiently renames the host (a `-2` Bonjour suffix on collision), breaking
attribute selection mid-switch. `just switch` reads the hardware serial
(`IOPlatformSerialNumber`) instead and passes `.#<serial>` explicitly — exactly how host
attributes are named. Extra arguments are forwarded (`just switch --dry-run`). Outside the
repo directory, the fish function `+darwin-rebuild-switch` (`modules/shells.nix`) does the
same serial lookup.
