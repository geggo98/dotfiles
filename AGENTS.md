# Repository Guidelines

This file provides guidance to AI coding agents when working with code in this repository.

## Repository Overview

This is a Nix-darwin configuration repository for managing macOS systems (Stefan Schwetschke's personal dotfiles). It uses Nix flakes, flake-parts, nix-darwin, Home Manager, and Determinate Nix for declarative system configuration on Apple Silicon Macs.

The repository follows the **Dendritic Pattern** for Nix flake structure — use the `/nix-dendritic-pattern` skill for detailed guidance on creating and modifying modules.

**Current Hosts:**
- `FCX19GT9XR` - Personal Mac (user: `stefan`)
- `DKL6GDJ7X1` - Work Mac (user: `stefan.schwetschke`)

## Build, Test, and Development Commands

A `justfile` provides safe, pre-approved commands that agents can run without user approval. Raw `nix` and `darwin-rebuild` commands require user approval. The **only** exceptions in the justfile are `just switch` / `just switch-host`, which apply the system config with `sudo` — these are for the user to run interactively, not agents. `just switch` is also the *only* supported way to apply the config: it selects the flake attribute by hardware serial, which a bare `darwin-rebuild switch --flake .` cannot do reliably (see "Applying the configuration").

### Safe commands (via justfile, no approval needed)

| Command | Description |
|---|---|
| `just build` | Build current host configuration without applying |
| `just build-host <host>` | Build a specific host (e.g. `just build-host DKL6GDJ7X1`) |
| `just check` | Run `nix flake check` |
| `just fmt` | Format all Nix files with `nixpkgs-fmt` |
| `just fmt-check` | Check formatting without modifying files |
| `just update` | Update all flake inputs |
| `just update-input <input>` | Update a single flake input |
| `just diff` | Build and show package delta vs. current system |
| `just verify-no-diff` | Build and assert no package delta (useful after refactoring) |
| `just deps` | Show flake dependency tree |
| `just eval` | Evaluate flake outputs (fast syntax check) |
| `just show-derivation` | Show derivation of current host build |
| `just gc` | Collect user-level garbage, keeping the last 7 days of generations |
| `just optimise` | Deduplicate the store (hard-link identical files) |

### New files: stage them before building

**Nix flakes only see git-tracked files.** Newly created files (modules, skill
files, references, templates, secrets — anything under the flake source) are
**invisible** to `nix build`, `just build`, `just eval`, and `darwin-rebuild`
until at least intent-to-added with `git add -N <paths>` (or fully staged with
`git add <paths>`). The flake build silently skips untracked files; the only
hint is the `warning: Git tree '…' has uncommitted changes` line, which fires
even when nothing is wrong.

After creating any new file, run:

```bash
git add -N <new-paths>      # intent-to-add is enough for flake to see them
just build                  # now picks up the new files
```

If a build seems to "ignore" your changes (a new module isn't applied, a new
skill doesn't appear, a new file referenced from a tracked module fails to
load) — check `git status` first. Untracked files are the most common cause.

### Commands requiring user approval

These cannot run inside the agent sandbox or need explicit confirmation:

```bash
# Apply configuration (requires sudo) — see "Applying the configuration" below
just switch

# Dry-run switch (extra args are forwarded to darwin-rebuild)
just switch --dry-run

# Build for a specific host directly
nix build .#darwinConfigurations.DKL6GDJ7X1.system
nix build .#darwinConfigurations.FCX19GT9XR.system

# Show package delta between current and new system
nix store diff-closures /run/current-system result

# Full system-wide garbage collection (prunes the system profile too). Runs
# automatically every week via modules/nix-gc.nix; this is the manual one-off.
sudo nix-collect-garbage --delete-older-than 7d
```

### Applying the configuration

Always apply via **`just switch`**, never a bare `sudo darwin-rebuild switch
--flake .`. A bare `--flake .` lets darwin-rebuild pick the flake attribute from
the current hostname, and macOS transiently renames the host — it appends a `-2`
Bonjour suffix on a name collision — at which point attribute selection breaks
with a confusing "no such attribute" error mid-switch. `just switch` reads the
hardware serial (`IOPlatformSerialNumber`) instead and passes `.#<serial>`
explicitly, which is exactly how host attributes are named. Extra arguments are
forwarded, so `just switch --dry-run` works.

```bash
just switch                       # this host, by serial (drift-safe)
just switch --dry-run             # same, without applying
just switch-host DKL6GDJ7X1       # a specific host, by name
```

Outside the repo directory, the fish function `+darwin-rebuild-switch`
(`modules/shells.nix`) does the same serial lookup against
`~/.config/nix-darwin`.

Agents must not run these — they need `sudo` and are interactive. Print the
command for the user instead.

## Architecture

### Dendritic Pattern with flake-parts

This repository uses the **Dendritic Pattern**: every file in `./modules/` is a flake-parts module organized by feature (aspect), not by configuration class. The `/nix-dendritic-pattern` skill provides full documentation on this pattern.

### Entry Point
- **`flake.nix`** - Uses `flake-parts.lib.mkFlake` and auto-imports all modules via `import-tree ./modules`

### Module Structure (`modules/`)

Each module defines a single aspect across all relevant configuration classes (darwin, homeManager, etc.) using `flake.modules.<class>.<name>`.

| Module | Description |
|---|---|
| `flake-parts.nix` | Registers `flake-parts.flakeModules.modules`, sets target systems |
| `darwin-wiring.nix` | Defines `configurations.darwin` option and wires it to `flake.darwinConfigurations` |
| `macos.nix` | macOS-specific defaults (dock, finder, trackpad, system preferences) via `flake.modules.darwin.macos` |
| `determinate.nix` | Determinate Nix module settings (`nix.enable = false`) via `flake.modules.darwin.determinate` |
| `nix-cache.nix` | Shared Cloudflare R2 Nix binary cache — substituter + signed `post-build-hook` push — via `flake.modules.darwin.nix-cache`. Bucket/domain provisioned in `infra/`; details in `infra/README.md` |
| `homebrew-common.nix` | Shared Homebrew configuration via `flake.modules.darwin.homebrew` |
| `shells.nix` | Shell configuration (Fish, Zsh, Bash) via `flake.modules.homeManager.shell` |
| `git.nix` | Git configuration via `flake.modules.homeManager.git` |
| `neovim.nix` | Neovim (nvf) configuration via `flake.modules.homeManager.neovim` |
| `packages.nix` | Common packages via `flake.modules.homeManager.packages` |
| `mcp-servers.nix` | Claude Code MCP server wrappers via `flake.modules.homeManager.mcp-servers` |
| `secrets.nix` | SOPS secret declarations and per-host secret merging |
| `misc.nix` | Key remapping, Hammerspoon, misc home config |
| `aichat.nix` | AI chat tool configuration |
| `ai-tools.nix` | AI tool packages and configuration |
| `boundary.nix` | HashiCorp Boundary PM2-managed proxies (work host) |
| `vault.nix` | HashiCorp Vault configuration |
| `overlays.nix` | Nixpkgs overlays |
| `formatter.nix` | `nix fmt` formatter configuration |

### Host Definitions (`modules/hosts/`)

Each host is a flake-parts module that composes aspect modules:

- **`modules/hosts/FCX19GT9XR.nix`** - Personal Mac: imports `darwin.{macos,determinate,homebrew}` and `homeManager.{shell,git,neovim,mcp-servers,aichat,ai-tools,packages,misc,secrets-FCX19GT9XR}`
- **`modules/hosts/DKL6GDJ7X1.nix`** - Work Mac: same pattern plus `homeManager.{boundary,vault}`

Host-specific secrets declarations live in **`hosts/<serial>/secrets.nix`**.

### Key Architectural Decisions

- **Value sharing:** Through `let` bindings and `config.flake.modules` — never through `specialArgs`
- **Module type:** Uses `deferredModule` type for beneficial merge semantics
- **Auto-import:** `import-tree ./modules` auto-discovers all module files
- **Nix management:** Determinate Nix manages the Nix installation, not nix-darwin's built-in `nix.enable`
- **SIP restriction:** `launchd.envVariables` is blocked by macOS System Integrity Protection. To set environment variables for GUI apps (e.g. PATH), use a `launchd.user.agents` entry that runs `/bin/launchctl setenv` at login instead
- **Binary cache (R2):** both hosts share a Cloudflare R2 cache (`modules/nix-cache.nix`). Pull is a public custom-domain substituter; push is a signed `nix copy` (root `post-build-hook`, or `just cache-seed`/`cache-push`). The hook is referenced by the **stable** `/run/current-system/sw/bin` path, but Determinate's `nix-daemon` reads the hook setting only at startup and `darwin-rebuild switch` does **not** restart it — after first enabling the cache, run `sudo launchctl kickstart -k system/systems.determinate.nix-daemon` (or reboot) once. Push credentials: `r2_secret_access_key` stores a Cloudflare API token (`cfat_…`) whose SHA-256 the push script derives as the S3 secret

## Coding Style & Naming Conventions

- **Indentation:** 2 spaces
- **Attribute sets:** Keep alphabetized within logical groups
- **Host naming:** Mirror host serials exactly (`FCX19GT9XR`, `DKL6GDJ7X1`)
- **Format before committing:** `just fmt` or `nix run nixpkgs#nixpkgs-fmt -- <files>`
- **Module pattern:** Each module file exports `flake.modules.<class>.<name>` — see `/nix-dendritic-pattern` skill

### Script style (shell, Python, regex)

macOS ships a BSD userland. GNU tools exist only inside the devenv shell or under
`g`-prefixed names, and are on `PATH` only if someone installed them. Anything that
runs outside a Nix wrapper must not assume either flavour.

- **Short scripts → zsh** (`#!/bin/zsh`), not bash. zsh is the macOS default login
  shell and a current release; `/bin/bash` is frozen at 3.2 (2007), so no associative
  arrays, `${var@Q}`, `readarray`, or `wait -n`. zsh also does not word-split
  unquoted parameters, which removes a whole class of quoting bugs.
- **Longer scripts → `python3` with a PEP-723 `uv` header**, stdlib-preferred. Once a
  script grows argument parsing, JSON handling, or more than a couple of branches, the
  shell version stops being readable or testable. See "uv-based skill scripts" below
  for the `--frozen` and lockfile rules.
- **Prefer a `perl` one-liner to `sed` / `awk` / `grep` / `cut` / `tr`** wherever
  performance allows. Perl is in the macOS base system, implements `-i`, `-n`, `-p`
  and PCRE itself, and behaves identically on macOS and Linux. The alternatives all
  diverge between BSD and GNU. Reach for the GNU tool only when data volume makes
  Perl's throughput or startup the bottleneck.

  | Instead of | Write |
  |---|---|
  | `grep -o` / `sed -n 's/…/\1/p'` | `perl -ne 'print $+{x} if /(?<x>…)/'` |
  | `sed -i'' -e 's/a/b/'` | `perl -i -pe 's/a/b/'` |
  | `awk -F'\t' '{print $4}'` | `perl -F'\t' -lane 'print $F[3]'` |
  | `grep -c` | `perl -ne '$n++ if /…/; END { print $n // 0 }'` |

  The `sed` row is not hypothetical: BSD `sed` reads `-i'' -e` as "backup extension
  `-e`" and silently leaves a stale `file-e` beside the real one. Perl implements
  `-i` itself, so the divergence is gone at the root rather than worked around. See
  the comment on the `brew-bump` recipe in the `justfile`.

- **Regex: named capture groups** wherever the syntax supports them — `(?<name>…)`
  with `$+{name}` in Perl, `(?P<name>…)` with `m["name"]` in Python. The name is free
  documentation, and the pattern keeps working when someone inserts a group ahead of
  it. Fall back to positional `$1`/`\1` only where there is no named form (POSIX
  BRE/ERE, `sed`, bash's `BASH_REMATCH`).
- **Regex: complex patterns go multi-line and commented** — `/x` in Perl,
  `re.VERBOSE` in Python — once a pattern carries more than one capture, a
  lookaround, or an alternation that no longer fits on one readable line.
- **Regex: always show a concrete example** of a line the pattern must match, in a
  comment directly above it. It lets the next reader check the pattern without
  running it, and it is the first thing to update when the input format drifts.

  ```perl
  # matches:     url = "github:Homebrew/brew/6.0.17";   ->  $+{tag} eq "6.0.17"
  m{^ \s* url \s* = \s* "github:Homebrew/brew/(?<tag>[^"]+)"; \s* $}x
  ```

- **Carve-out — scripts built by Nix.** Inside `pkgs.writeShellApplication` with an
  explicit `runtimeInputs`, the BSD/GNU question is settled at build time and bash is
  the right choice: `shellcheck` runs over it, `set -euo pipefail` is injected, and
  every tool resolves to a pinned nixpkgs path. Reference:
  `modules/nix-tarball-cache-repack.nix`.
- **Carve-out — `justfile` recipes** keep `#!/usr/bin/env bash` + `set -euo pipefail`
  to match the existing recipes, but follow the perl and regex rules above for their
  text processing.

## Commit & Pull Request Guidelines

Use Conventional Commits: `type(scope): subject` (imperative present tense, ≤72 chars)

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Common scopes:** `home`, `homebrew`, `darwin`, `flake`, `secrets`, `macos`, `env`, `project`, `docs`

**Examples:**
- `feat(home): Add Claude Code MCP servers for Atlassian and Context7`
- `fix(darwin): Correct Emoji & Symbols keyboard shortcut`
- `chore(flake): Update nixpkgs to 25.11`

Include host IDs and commands executed in commit body when relevant. Iterate with fixups (`git commit -m "fixup! …"`); run `git push --dry-run` and wait for explicit approval before pushing.

**`Co-Authored-By` trailer (Claude Code):** Use only the generic form — `Co-Authored-By: Claude <noreply@anthropic.com>`. Do **not** embed a specific model name, version, or context label (e.g. `Claude Opus 4.7 (1M context)`): Claude's content-integrity guardrail may block such trailers as impersonation of a "fabricated model". The block is non-deterministic (observed: the same string passed in one turn and was rejected in another), so even "it worked last time" is not a safe signal. The generic form always passes.

## Secrets & Configuration Tips

- **Location:** `secrets/secrets.enc.yaml` (global), `hosts/<serial>/secrets.enc.yaml` (per-host)
- **Decryption keys:** SSH Ed25519 key at `~/.ssh/id_ed25519_sops_nopw` (passwordless)
- **Secrets declaration:** In `modules/secrets.nix` and `hosts/<serial>/secrets.nix`
- **Critical note:** SOPS does not work in the agent sandbox — ask the user to edit secrets manually
- **Edit command:** `env SOPS_AGE_KEY=$(ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key) sops edit secrets/secrets.enc.yaml`
- Ensure new secrets are declared with explicit paths and modes; avoid committing derived plaintext files
- When provisioning a new machine, confirm the correct host serial directory under `hosts/` before switching

## Common Patterns

### Adding a New Module

Use the `/nix-dendritic-pattern` skill for guidance. In short:

1. Create `modules/<aspect>.nix`
2. Export `flake.modules.<class>.<name>` (e.g. `flake.modules.homeManager.my-feature`)
3. Import the module in the relevant host file(s) under `modules/hosts/<serial>.nix`

### Adding a New Host

1. Create `modules/hosts/<serial>.nix` composing existing aspect modules
2. Create `hosts/<serial>/secrets.nix` for host-specific secret declarations
3. The host is auto-discovered via `import-tree`

### Adding a New Secret

1. User edits secrets with: `env SOPS_AGE_KEY=$(ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key) sops edit secrets/secrets.enc.yaml`
2. Add secret declaration in `modules/secrets.nix` or `hosts/<serial>/secrets.nix`
3. Access via `config.sops.secrets.<name>.path` in configurations

### Adding an MCP Server

1. Add shell wrapper and server entry in `modules/mcp-servers.nix` (follow existing patterns)
2. Ensure secret loading logic uses `$XDG_CONFIG_HOME/sops-nix/secrets`

### Updating flake inputs

- **nvf (Neovim):** Before bumping the `nvf` input (`modules/neovim.nix`), **check
  the nvf release notes** for breaking option renames/removals:
  <https://github.com/NotAShelf/nvf/tree/main/docs/manual/release-notes> (e.g.
  `rl-0.9.md`). nvf changes `vim.*` option paths between releases (language
  modules, `lsp.presets.*`, removed plugins), and these surface as eval errors.
  Cross-reference `programs.nvf.settings` in `modules/neovim.nix` against the
  notes before building.

- **agent-browser:** pinned in **two** places. Bump the `agent-browser-src` tag in
  `flake.nix` (that tag is also where the version comes from — it is read out of the
  input's `package.json`), then run `just agent-browser-hashes <version>` and paste the
  printed `assets` attrset into `modules/agent-browser.nix`, then `just build`. Do
  **not** switch back to `nixpkgs-llm-agents.agent-browser` or `nixpkgs.agent-browser`
  without re-checking the pnpm dashboard FOD: it resolves time-dependently (pnpm
  `minimumReleaseAge`) and drifts off its pinned hash on its own. The release binary
  carries no skill bodies, so `modules/agent-browser.nix` points
  `AGENT_BROWSER_SKILLS_DIR` at `$out/skill-data` copied from the same tag — keep those
  two in sync or `agent-browser skills get` breaks.

- **Gram editor — cask, deliberately not nixpkgs.** Gram (Zed fork, replaced the `zed`
  cask) comes from the `gram` homebrew cask. nixpkgs *does* ship a working
  aarch64-darwin `gram`, and it is cached — but its darwin build symlinks a full `git`
  into the app bundle, which drags `python3 → clang → llvm → apple-sdk` and yields a
  **1.8 GiB closure** for a ~130 MiB app. `gram.override { git = gitMinimal; }` would
  cut ~1.3 GiB of that, but changes the store path and so forces a source build of a
  Zed-sized Rust tree (hours). Re-check this trade-off before moving Gram to nixpkgs.
  The theme in `modules/_files/gram/turbo-vision.json` *is* Nix-managed
  (`modules/gram.nix`) — a port of the VS Code theme
  (`modules/_files/vscode/turbo-vision-color-theme.json`); Gram consumes Zed's
  `zed.dev/schema/themes/v0.2.0.json` format verbatim. Gram's `settings.jsonc` is
  intentionally left unmanaged — Gram writes UI settings back to it.

### uv-based skill scripts (lockfiles + the read-only Nix store)

Some skill helpers under `modules/ai/_files/skills/*/scripts/` are self-contained
`uv` scripts (PEP-723 `# /// script` header) invoked from a thin zsh wrapper via
`gtimeout … script.py`. Two rules keep them working once deployed:

- **Always run with `--frozen`.** The shebang must be
  `#!/usr/bin/env -S uv --quiet run --frozen --script`. Deployed skill files land
  in `/nix/store` (**read-only**), so any attempt by `uv` to *update* the lockfile
  at runtime fails. `--frozen` reads the lock without writing it.
- **Commit the lockfile.** Each such script ships a sibling `script.py.lock`
  (generated with `uv lock --script script.py`). Regenerate and commit it whenever
  you change the PEP-723 `dependencies`. Like any new file, `git add -N` it so the
  flake build picks it up (see "New files: stage them before building").

Reference example: `modules/ai/_files/skills/grafana/scripts/grafana.py` (+`.lock`),
also `bitbucket-pr/scripts/bitbucket_pr_reviewers.py`.

### Closing a dependency advisory in `infra/`

`infra/` is the only npm tree in this repo (Pulumi, pnpm 11). GitHub Dependabot
watches `infra/pnpm-lock.yaml`; `just pulumi-audit` asks the same question
independently against OSV and additionally flags anything published inside the
cooldown window. Its script (`infra/scripts/osv-audit.py`) is stdlib-only on
purpose — an auditing tool that installs dependencies to run has a supply chain of
its own. Exit codes: `0` clean, `1` advisories found, `2` tool/network error.

**Work the ladder top-down and stop at the first rung that applies.**

1. **The fixed version fits the parent's declared semver range → lockfile only.**
   `cd infra && pnpm update <pkg> --depth Infinity`. `package.json` and
   `pnpm-workspace.yaml` stay untouched; `git diff --stat infra/` must show
   `pnpm-lock.yaml` alone. Check the range against the registry *before* editing —
   `curl -fsSL https://registry.npmjs.org/<parent>/<version>` and read
   `.dependencies`. This is the common case: `1c3d7cd` (tar, brace-expansion),
   `7dd7121` (seven advisories at once).
2. **It does not fit → bump the direct dependency** in `infra/package.json` so the
   floor is encoded where a human will see it (`^3.0.0` → `^3.252.0`). Example:
   `7902ef9`.
3. **`pnpm.overrides` / `resolutions`: no.** Never used here, and rejected once on
   evidence — pinning a transitive Pulumi dependency broke the SDK at load, because
   the 1.x OTel siblings import symbols removed in core 2.x. Bump the coordinated
   parent instead.
4. **The fix is younger than the cooldown** (`minimumReleaseAge: 4320`, three days,
   `infra/pnpm-workspace.yaml`) → exempt that one `package@version` via
   `minimumReleaseAgeExclude`. Never lower the floor itself, which would exempt
   everything. **This rung has a hard precondition — see below.**

#### Undercutting a cooldown: research first, fetch second

Not negotiable, and not a matter of taste. The cooldown *is* the control that
catches a compromised release, so exempting a package removes exactly that control
for exactly that package. "Just bump it and see if anything breaks" is not
available: `pnpm update` downloads and unpacks the tarball, and `tsc`/Pulumi then
import it. By the time a test could fail, the code has already run on a machine
holding this repo's SOPS secrets and its Cloudflare and AWS credentials. Research
that starts after the install starts too late.

1. **Research while fetching nothing.** Establish that this specific
   `package@version` is not part of a live supply-chain incident: read the upstream
   fix commit and the advisory; inspect the maintainer set, publish provenance and
   signatures through registry *metadata* only (`npm view <pkg>@<ver> --json`, or
   `curl -fsSL https://registry.npmjs.org/<pkg>`); check GitHub Security Advisories,
   the project's issue tracker, and current incident reporting (Socket,
   StepSecurity, Snyk, OpenSSF) for the **package and its maintainers** — a
   maintainer-account compromise shows up there before it shows up in the package.
   If anything looks off, diff the published tarball against the tagged source.
2. Only then add the `minimumReleaseAgeExclude` entry, run the update, and verify.
3. If the research cannot conclude cleanly, **wait out the cooldown** and mitigate
   another way: route around the vulnerable code path, disable the feature, or
   accept the risk explicitly and say so in the commit. Waiting is by far the
   cheaper failure mode.

The same rule governs every other cooldown here — the uv `exclude-newer-package`
overrides in `modules/ai/_files/skills/browser-use/scripts/browser-use.py` and the
global `exclude-newer` / `min-release-age` floors in
`modules/supply-chain-hardening.nix`. Any cooldown, same precondition.

#### Verifying and recording

Before committing: `just pulumi-audit` clean, `cd infra && pnpm audit` clean,
`pnpm exec tsc --noEmit` green.

Commit bodies here double as the runbook, so write them accordingly: the advisory
(severity, GHSA, CVSS vector), the dependency path that pulls the package in, which
rung you used and why the ones above it did not apply, and the publish age of the
version you moved to.
