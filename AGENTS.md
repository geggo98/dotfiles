# Repository Guidelines

This file provides guidance to AI coding agents when working with code in this repository.
It is kept under Codex's 32 KiB project-doc budget (`project_doc_max_bytes = 32768`,
measured via `~/.codex/logs_2.sqlite`: `project doc exceeds remaining budget; truncating
… remaining_bytes=32768` — anything past that line was invisible to Codex). Deep dives with
the full measurements and incident reports live under `docs/`; read the linked file before
touching the area it covers.

## Repository Overview

This is a Nix-darwin configuration repository for managing macOS systems (Stefan Schwetschke's personal dotfiles). It uses Nix flakes, flake-parts, nix-darwin, Home Manager, and Determinate Nix for declarative system configuration on Apple Silicon Macs.

The repository follows the **Dendritic Pattern** for Nix flake structure — use the `/dendritic-nix` skill for detailed guidance on creating and modifying modules.

**Current Hosts:**
- `FCX19GT9XR` - Personal Mac (user: `stefan`)
- `DKL6GDJ7X1` - Work Mac (user: `stefan.schwetschke`). Holds the CHECK24 work credentials
  (`jira_*`, `confluence_*`, `absence_io_*`, `c24_bi_kfz_*`) in
  `hosts/DKL6GDJ7X1/secrets.enc.yaml`, and is the only host with
  `my.ai.atlassian.enable`
- `p-ion-berlin-xs56r6` - IONOS Core VPS, `x86_64-linux` (NixOS). Named per
  `infra/Naming.md`. Not a darwin host: it is selected by name rather than hardware
  serial and is **not** applied with `just switch`. Full detail: `docs/ionos-vps.md`.

## Deep dives — read before touching …

| Area | Read first |
|---|---|
| `modules/nixos-*.nix`, `hosts/p-ion-*` | `docs/ionos-vps.md` |
| Docker Linux builder, cross-arch builds | `docs/linux-builder.md` |
| `modules/nix-cache.nix`, the R2 push/prune scripts | `docs/nix-cache.md` |
| `auto-optimise-store`, `nix-collect-garbage` timing | `docs/nix-store.md` |
| launchd agents/daemons, anything scheduled | `docs/launchd.md` |
| Shell/Python scripts, resumable batch jobs | `docs/scripting.md` |
| DNS names, `infra/Naming.md` rebind exceptions | `docs/dns-realms.md` |
| Secrets, SOPS, Vault, Atlassian tokens | `docs/secrets.md` |
| MCP servers, agent/AI aspect toggles | `docs/ai-tooling.md` |
| `modules/devdocs.nix` | `docs/devdocs.md` |
| `modules/vscode.nix`, extensions, settings.json | `docs/vscode.md` |
| iTerm2 `Web` profile / DuckDuckGo settings | `docs/iterm2-duckduckgo.md` |
| `just update`, `just audit`, dependency advisories | `docs/supply-chain.md` |

## Build, Test, and Development Commands

A `justfile` provides safe, pre-approved commands that agents can run without user approval. Raw `nix` and `darwin-rebuild` commands require user approval. The **only** exceptions in the justfile are `just switch` / `just switch-host`, which apply the system config, and `just daemon-restart`, which restarts the nix-daemon — all three use `sudo` and are for the user to run interactively, not agents. `just switch` is also the *only* supported way to apply the config: it selects the flake attribute by hardware serial, which a bare `darwin-rebuild switch --flake .` cannot do reliably (see "Applying the configuration").

### Safe commands (via justfile, no approval needed)

| Command | Description |
|---|---|
| `just build` / `just build-host <host>` | Build (current or a specific) host config without applying |
| `just check` / `just ai-check` / `just fmt-check` / `just eval` | `nix flake check`; isolated AI-aspect tests; format check; fast syntax check |
| `just fmt` | Format all Nix files with `nixpkgs-fmt` |
| `just update` / `-preview` / `-input <i>` / `-head` | Update flake inputs honouring the supply-chain cooldown (`-head` bypasses it) |
| `just audit` / `-inputs` / `-extensions [ids…]` | Cooldown + withdrawal audit: inputs, npm/GitHub package ages, VS Code extensions |
| `just creds-check` | Do the long-lived credentials still authenticate? (jira, confluence, bb) |
| `just vscode-settings-check` | Has VS Code been trying to write the Nix-managed settings.json? |
| `just devdocs-list` / `-lock [families…]` / `-check` | DevDocs offline index: drift, re-lock, hermetic pipeline test |
| `just diff` / `just verify-no-diff` | Package delta vs. current system; assert no delta |
| `just deps` / `just show-derivation` | Flake dependency tree; derivation of current host build |
| `just cache-queue` / `just cache-prune <cat>` | R2 push queue depth/age; dry-run removal (`apply` is NOT agent-safe) |
| `just gc` / `just optimise` | User-level GC (7d) + sweep any running builder; hand store dedup |
| `just linux-builder-up/-status/-probe/-gc/-down [arch]` | Docker Linux builder lifecycle — see `docs/linux-builder.md` |
| `just linux-build <attr> [arch] false` | Build a flake attribute for Linux — trailing `false` skips the R2 push |

Four Linux-builder recipes are deliberately **absent** from that list, and not because
they need sudo:

- `just linux-build`/`nixos-build` **without** `push="false"`, and `just linux-push`,
  publish **signed** artifacts into the shared cache. An agent should not push there
  unsupervised — build with `push="false"` and let a human do the push.
- `just linux-builder-destroy` deletes a Docker volume and the keypair, and leaves a
  stale entry that needs a root `ssh-keygen -R` to clear.
- `just nixos-deploy <host>` activates a production system over ssh. Print it for the
  user instead, like `just switch`.

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

These cannot run inside the agent sandbox or need explicit confirmation — **agents must
not run them**, they need `sudo` and are interactive; print the command for the user
instead:

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

### Applying the configuration

Always apply via **`just switch`**, never a bare `sudo darwin-rebuild switch --flake .`.
A bare `--flake .` lets darwin-rebuild pick the flake attribute from the current
hostname, and macOS transiently renames the host (a `-2` Bonjour suffix on collision),
breaking attribute selection mid-switch. `just switch` reads the hardware serial
(`IOPlatformSerialNumber`) instead and passes `.#<serial>` explicitly — exactly how
host attributes are named. Extra arguments are forwarded (`just switch --dry-run`).
Outside the repo directory, the fish function `+darwin-rebuild-switch`
(`modules/shells.nix`) does the same serial lookup.

## Architecture

### Dendritic Pattern with flake-parts

This repository uses the **Dendritic Pattern**: every file in `./modules/` is a
flake-parts module organized by feature (aspect), not by configuration class. The
`/dendritic-nix` skill provides full documentation on this pattern.

### Entry Point
- **`flake.nix`** - Uses `flake-parts.lib.mkFlake` and auto-imports all modules via `import-tree ./modules`

### Module Structure (`modules/`)

Each module defines a single aspect across all relevant configuration classes (darwin, homeManager, etc.) using `flake.modules.<class>.<name>`.

| Module | Description |
|---|---|
| `flake-parts.nix` | Registers `flake-parts.flakeModules.modules`, sets target systems |
| `darwin-wiring.nix` | Defines `configurations.darwin` and wires it to `flake.darwinConfigurations` |
| `macos.nix` | macOS defaults (dock, finder, trackpad, …) via `flake.modules.darwin.macos` |
| `determinate.nix` | `nix.enable = false` — Determinate manages Nix instead |
| `nix-cache.nix` | Shared Cloudflare R2 binary cache (substituter + async push). See `docs/nix-cache.md` |
| `linux-builder.nix` | Registers the Docker Linux builders with the daemon. See `docs/linux-builder.md` |
| `homebrew-common.nix` | Shared Homebrew configuration |
| `shells.nix` | Fish/Zsh/Bash config via `flake.modules.homeManager.shell` |
| `git.nix` | Git configuration |
| `neovim.nix` | nvf in two variants: `neovim` (workstation) and `neovim-server` (no language toolchains) |
| `packages.nix` | Common packages |
| `agents.nix` | Nix-managed agent packages, settings, version assertions, `+agent-*` wrappers |
| `agent-content.nix` | Standalone skills and global rules, incl. the host-specific Atlassian filter |
| `mcp-servers.nix` / `mcp-clients.nix` | Shared MCP catalog; client renderers and portable exports — see `docs/ai-tooling.md` |
| `agent-integration.nix` | Delivers content/MCP to enabled Nix agents; removes owned entries when disabled |
| `devdocs.nix` | Offline DevDocs lookup (`+devdocs`), own namespace `my.devdocs`. See `docs/devdocs.md` |
| `secrets.nix` | SOPS declarations, per-host merging (**home-manager only** — servers use `nixos-secrets.nix`) |
| `nixos-wiring.nix` | Defines `configurations.nixos` and wires `flake.nixosConfigurations`/`deployTargets` |
| `nixos-base.nix` | Baseline for every NixOS host: sshd, authorized keys, lockout assertions, serial getty |
| `nixos-tailscale.nix` | Tailscale SSH — userspace, not sshd, not firewall-gateable. See `docs/ionos-vps.md` |
| `nixos-wireguard-home.nix` | WireGuard to the home FRITZ!Box, proxy-ARP addressing |
| `nixos-backup-copy.nix` | Second restic copy, R2 → Dropbox; ciphertext only |
| `nixos-secrets.nix` | sops-nix on the **nixos** class — decrypts to `/run/secrets/`, host-generated key |
| `misc.nix` | Key remapping, Hammerspoon, misc home config |
| `onepassword.nix` | Generates `~/.config/1Password/ssh/agent.toml`. See `docs/ionos-vps.md` |
| `aichat.nix` / `ai-tools.nix` | AI chat tool config; general AI tool packages (`llm`, Ollama, `+nix-query`) |
| `boundary.nix` | HashiCorp Boundary PM2-managed proxies (work host) |
| `vault.nix` | `+vault`/`+vault-login` wrappers. See `docs/secrets.md` |
| `vscode.nix` | VS Code extensions + settings.json + theme. See `docs/vscode.md` |
| `overlays.nix` / `formatter.nix` | Nixpkgs overlays; `nix fmt` formatter |

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
- **SIP restriction:** `launchd.envVariables` is blocked by macOS SIP. For GUI-app env vars (e.g. PATH), use a `launchd.user.agents` entry running `/bin/launchctl setenv` at login instead
- **launchd jobs get no shell environment:** the converse of the SIP restriction above — an agent/daemon inherits only `PATH`, `SSH_AUTH_SOCK` and the XPC keys, never `home.sessionVariables` or an rc file's exports, and must never fall back silently when one is missing. Full worked examples (with a caught bug): `docs/launchd.md`
- **Binary cache (R2):** both hosts share a Cloudflare R2 cache; push is async via the `nix-cache-drain` LaunchDaemon, not the build itself. First enabling it needs one `just daemon-restart`. Full detail: `docs/nix-cache.md`

## Coding Style & Naming Conventions

- **Indentation:** 2 spaces
- **Attribute sets:** Keep alphabetized within logical groups
- **Host naming:** see "Host and DNS naming" below — Macs mirror their serial exactly
  (`FCX19GT9XR`, `DKL6GDJ7X1`), everything else follows the scheme in `infra/Naming.md`
- **Format before committing:** `just fmt` or `nix run nixpkgs#nixpkgs-fmt -- <files>`
- **Module pattern:** Each module file exports `flake.modules.<class>.<name>` — see `/dendritic-nix` skill

### Host and DNS naming

The full rule, with the evidence behind each part of it, is **`infra/Naming.md`**. It is
enforced by `infra/src/inventory.ts`, which validates every name when the module loads —
a malformed name breaks `tsc` and `pulumi preview` rather than reaching a zone file.

```
p-<provider>-<site>-<rand6>     physical    p-ion-berlin-xs56r6, p-own-muenchen-j5jghb
[vc]-<arch>-<rand6>             VM / container   v-amd64-k9y25p, c-arm64-h6pedq
<SERIAL>                        Macs, exempt     FCX19GT9XR, DKL6GDJ7X1
```

Physical machines carry where they stand; virtual ones carry the only thing migration
cannot change — the virtualization ecosystem (VMware/KVM/Proxmox/…) is deliberately
absent from names, since it lives in the inventory instead.

DNS puts the network in the label (`<name>.pub.0xf1a5c0.net`, `.tailnet.`, `.muenchen.`),
so a name never means "it depends where you ask". `0xf1a5c0.net` is the machine domain;
`schwetschke.dev` is the published one — that split exists because the home FRITZ!Box
strips private addresses out of public DNS answers, and the rebind exception that
re-enables them is granted per domain. Full detail, including the MagicDNS/rebind
measurements: `docs/dns-realms.md`.

### Script style (shell, Python, regex)

The general perl/zsh/Python conventions (BSD-vs-GNU divergence, named capture groups,
the `/x`-commented regex rule) live in the global agent rule `script-style.md`
(`~/.claude/rules/`), shared across every repo on this machine. What follows is only
what is specific to *this* repo's Nix-built scripts:

- **Carve-out — `pkgs.writeShellApplication` stays bash.** It is a bash-only nixpkgs
  builder with no zsh counterpart: `shellcheck` runs over the source, `set -euo
  pipefail` is injected, and every `runtimeInputs` tool resolves to a pinned store
  path. ~20 call sites (`modules/mcp-servers.nix`, `modules/vault.nix`,
  `modules/nix-tarball-cache-repack.nix`, …) rely on this.
- **Other Nix-built scripts use zsh.** `writeShellScriptBin` hardcodes bash; prefer
  `writeTextFile` with an explicit `#!${pkgs.zsh}/bin/zsh` — pinned, not `/bin/zsh`.
  See `mkZshScript` in `modules/nix-cache.nix`.
- **`justfile` shebang recipes use `#!/bin/zsh`** + `set -euo pipefail`. Non-shebang
  recipes run under just's default `sh -cu`.
- **When converting bash → zsh, the trap is word splitting.** zsh does *not*
  word-split unquoted parameters — use `${=VAR}` where the old code relied on it. It
  bit the R2 post-build hook's `$OUT_PATHS` (a space-separated path list); measured,
  `V="x y z"; set -- $V` gives `argc=1` under zsh against `3` under bash.

Full incident reports (the `.otrkey` decoder miscount, the R2 hook's zsh trap, and
more) live in `docs/scripting.md`.

### Any script that processes a list must be resumable

Four rules, each paid for by a real incident — full write-ups in `docs/scripting.md`:

- **Classify every item as SUCCESS, SKIP, ERROR or CLEANUP, never collapse two.** A
  skip counted as a failure made two runs report rising "failures" while more files
  finished.
- **Derive state from the work products, not from a file the script wrote.** A
  progress/marker file is missing exactly when the run died badly.
- **"The output file exists" is a weak predicate — prefer "the output verifies".** A
  truncated write can look finished; use a checksum or at least a size check.
- **Publish atomically: write to a temp name, then `mv` into place.** Clean stale temp
  files at start-up and count that as CLEANUP.

Plus: make the summary self-describing (print all four counts and what a re-run would
do), and use exit codes to distinguish "did work" / "nothing to do" / "failed" — a
resumable script run twice must exit 0 the second time.

## Commit & Pull Request Guidelines

Use Conventional Commits: `type(scope): subject` (imperative present tense, ≤72 chars)

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Common scopes:** `home`, `homebrew`, `darwin`, `flake`, `secrets`, `macos`, `env`, `project`, `docs`

**Examples:**
- `feat(home): Add Claude Code MCP servers for Atlassian and Context7`
- `fix(darwin): Correct Emoji & Symbols keyboard shortcut`
- `chore(flake): Update nixpkgs to 25.11`

Include host IDs and commands executed in commit body when relevant. Iterate with fixups (`git commit -m "fixup! …"`); run `git push --dry-run` and wait for explicit approval before pushing.

**`git diff | grep '^+'` does not work on these machines.** `modules/git.nix` sets
`diff.external` to difftastic in `~/.config/git/config`, so `git diff` emits a structural
view rather than a unified diff and any plus-line filter silently returns nothing. Use
`git diff --no-ext-diff`, or `git grep` against the commit. `git show` and `git log -p`
are unaffected. Full rule, with measurements, in
`modules/ai/_files/rules/git-external-diff.md`, which is also installed globally to
`~/.claude/rules/`.

**`Co-Authored-By` trailer (Claude Code):** Use only the generic form — `Co-Authored-By: Claude <noreply@anthropic.com>`. Do **not** embed a specific model name, version, or context label (e.g. `Claude Opus 4.7 (1M context)`): Claude's content-integrity guardrail may block such trailers as impersonation of a "fabricated model". The block is non-deterministic (observed: the same string passed in one turn and was rejected in another), so even "it worked last time" is not a safe signal. The generic form always passes.

## This repository is PUBLIC — what needs explicit clearance

`github.com/geggo98/dotfiles` is public, and it carries work configuration. Two kinds of
content therefore need the user's **explicit** go-ahead before they are committed, every
single time. **A clearance given once does not carry over to the next occurrence.**

1. **Personal data of third parties** — names, email addresses, account ids, handles, of
   anyone other than the repository owner. They did not agree to be published here.
2. **Internal infrastructure** — hostnames, repository and product names, Jira project
   keys, cloud project ids, real ticket numbers, runbook names, workflow configuration.

**Re-question these at every review, including what is already in the tree.** That
something sits in the repo is not evidence that anyone cleared it; far more often it
means nobody looked.

**Identifiers evade keyword search.** An account id is a bare string with no company name
anywhere near it, so no search for an employer or for "internal" will ever surface it.
Grepping for suspicious words is not enough — search for the shapes: id-like strings,
ticket patterns such as `ABC-1234`, PR numbers, repo slugs, email addresses.

**Pasted example output is the usual way in**, because it carries whatever happened to be
on the line. Before committing an example, replace real ticket keys, PR numbers, repo
slugs and account ids with placeholders — **all of them on the line, not just the
conspicuous ones**. The characteristic mistake is to sanitise the branch name and the
issue id and leave the repo slug and the PR number beside them untouched.

**Validate the scan before believing "no hits".** A filter that structurally cannot match
reports the same thing as a clean result, so count how many lines it sees before treating
an empty result as a finding. See the global agent rule on `git diff` and difftastic
(`modules/ai/_files/rules/git-external-diff.md`) for a measured case where exactly that
happened during a pre-push scan.

When in doubt, ask. The cost of asking is one question; the cost of not asking is a
history rewrite and a force-push.

## Secrets & Configuration Tips

**Files are the default source. An environment variable is a deliberate manual
override.** A credential chain gets exactly one env name and one file — no generic
aliases, no cross-product fallback tiers. `modules/shells.nix` exports **no secret
values**, only `*_PATH`; every consumer reads its sops-nix file through
`load_from_secret`. Note **Jira answers 404, not 401** on an invalid token (it hides
issue existence from unauthenticated callers), so a 404 on a ticket that exists is
usually a dead/misrouted credential, not a missing ticket. Full detail — the Atlassian
token/scheme split, the `+vault -address` trap, the dead-alias incident — in
`docs/secrets.md`.

- **Location:** `secrets/secrets.enc.yaml` (global), `hosts/<serial>/secrets.enc.yaml` (per-host)
- **Decryption keys:** SSH Ed25519 key at `~/.ssh/id_ed25519_sops_nopw` (passwordless)
- **Secrets declaration:** In `modules/secrets.nix` and `hosts/<serial>/secrets.nix`
- **Critical note:** SOPS does not work in the agent sandbox — ask the user to edit secrets manually
- **Edit command:** `sops edit secrets/secrets.enc.yaml` — **no `env` prefix.**
  `SOPS_AGE_SSH_PRIVATE_KEY_FILE` is already exported from `home.sessionVariables`
  (`modules/shells.nix`), so sops finds the identity on its own.
- **Changing recipients:** after editing a rule in `.sops.yaml`, existing files
  are NOT re-encrypted automatically — `sops updatekeys -y <file>`. Without `-y`
  it asks `Is this okay? (y/n)` and dies on `EOF` when run without a terminal.
- Ensure new secrets are declared with explicit paths and modes; avoid committing derived plaintext files
- When provisioning a new machine, confirm the correct host serial directory under `hosts/` before switching

## Common Patterns

### Adding a New Module

Use the `/dendritic-nix` skill for guidance. In short:

1. Create `modules/<aspect>.nix`
2. Export `flake.modules.<class>.<name>` (e.g. `flake.modules.homeManager.my-feature`)
3. Import the module in the relevant host file(s) under `modules/hosts/<serial>.nix`

### Adding a New Host

1. Create `modules/hosts/<serial>.nix` composing existing aspect modules
2. Create `hosts/<serial>/secrets.nix` for host-specific secret declarations
3. The host is auto-discovered via `import-tree`

### Adding a New Secret

1. User edits secrets with `sops edit secrets/secrets.enc.yaml` (no `env` prefix —
   see "Secrets & Configuration Tips" above)
2. Add secret declaration in `modules/secrets.nix` or `hosts/<serial>/secrets.nix`
3. Access via `config.sops.secrets.<name>.path` in configurations

**Group related secrets in the YAML with `key`, keep the attribute name flat** (e.g.
`r2_access_key_id.key = "nix_cache/r2/access_key_id"`) — `key` addresses a value
*inside* the encrypted file, `path` still defaults from `name`, so nesting never moves
a file on disk. On the home-manager class a mismatch fails `just build`; on the NixOS
class the same mistake surfaces only at activation. Full detail, including the
`age1…`/`ssh-ed25519` `.sops.yaml` trap: `docs/secrets.md`.

### Moving a secret between SOPS files

Host-scoping a credential is four steps in a fixed, safe-to-stop-after order —
`.sops.yaml` + `updatekeys` first, copy the value, flip the Nix declarations, only
then `sops unset` the source — using `sops set --value-stdin`/`unset`, never `sops
edit`. **Watch for Nix-side references**: a secret dereferenced as
`config.sops.secrets.<name>.path` from a module both hosts import breaks the *other*
host's build if moved without checking
(`grep -rn --include='*.nix' 'sops\.secrets\.' modules/`). Full script and the
three measured gotchas (`--value-stdin` wants JSON, never `v=$(sops -d …)`,
`--idempotent`): `docs/secrets.md`.

### Adding an MCP Server

**Prefer a remote endpoint to a local process** — claude-code starts stdio servers at
session start but connects remote HTTP servers lazily, on first tool use (measured:
seven stdio servers cost 13 processes and 491 MiB RSS per session). POST an
`initialize` at the vendor's endpoint before writing a stdio wrapper. **Credentials
never go in the config** — `remote.auth` names a sops *file*, never a value.

1. Add the server entry through `my.ai.mcp.servers`, with a `stdio` wrapper and,
   where supported, a `remote` endpoint.
2. Load credentials at runtime from `$XDG_CONFIG_HOME/sops-nix/secrets`.
3. Gate host-specific servers with their feature option (`my.ai.atlassian.enable`).
4. Use `my.ai.mcp.clients.<name>.exclude` / `my.ai.mcp.servers.<name>.enable = false`
   to hide a server from one client / from every client.

Full detail — the Antigravity CLI plugin layout, `just mcp-check`, and the
`my.ai.*` independent-aspect option table — in `docs/ai-tooling.md`.

### DevDocs offline index

`modules/devdocs.nix` builds an offline [DevDocs](https://github.com/freeCodeCamp/devdocs)
lookup (`+devdocs`) from 39 doc families, hash-pinned in `modules/_files/devdocs/docs.lock.json`.
Complements, does not replace, the `javadocs` MCP server. Bump ritual: `just devdocs-list`
(drift, no download) → `just devdocs-lock [families…]` → `just devdocs-check`. Full detail
— the zlib-preset-dictionary compression measurement, the Cloudflare User-Agent trap — in
`docs/devdocs.md`.

### VS Code extensions

The general set is pinned in `modules/vscode.nix` via `nix-vscode-extensions`; anything
with a language toolchain is project-specific (`.vscode/extensions.json`). VS Code itself
stays a Homebrew cask, deliberately not nixpkgs (unfree, would be built locally and
pushed into the public R2 cache). After a switch, verify with
`find ~/.vscode/extensions -maxdepth 1 -type l ! -name '.*' | wc -l` (expect 18) — not
`ls -l | grep '->'`, which silently reports 0 here because the interactive `ls` alias
renders symlinks with `⇒`. `settings.json` is a read-only `/nix/store` symlink; a write
attempt fails silently in the UI (only the renderer log shows `EACCES`) — see
`just vscode-settings-check`. Full detail — the extensions.json regeneration trap,
Settings Sync as a second writer, the `[Theme]`-scoped colour-warning VS Code bug — in
`docs/vscode.md`.

### The iTerm2 Web profile carries its DuckDuckGo settings in the URL

`modules/misc.nix` installs a `Web` profile whose `Initial URL` carries DuckDuckGo's
`k*` settings params (`kae` theme, `kbi` compact, `kp` safe search, `kpsb` reminder) —
they ride in the URL because the settings cookies are host-only on `duckduckgo.com` and
`start.duckduckgo.com` never receives them. Full detail — which params survive a search,
Cloud Save as a bearer-token credential, and how to read the current values out of
iTerm2's WebKit store — in `docs/iterm2-duckduckgo.md`.

### Updating flake inputs

**Use `just update`, never `nix flake update`.** The latter always jumps every input to
the current branch HEAD — exactly the window a supply-chain attack lives in; measured
2026-08-22, a plain `nix flake update` here moved six inputs to same-day HEADs during a
live, still-active npm supply-chain campaign. `just update` runs
`scripts/supply-chain.py`, resolving each input to the newest revision at least N days
old (`scripts/supply-chain.toml`: 5 days for flake inputs, 14 for npm/VS Code
extensions) and **never rolls an input backwards** without `--allow-rollback`.
`just audit` additionally asks whether anything was *withdrawn* upstream (a yank, an
unpublish) — age alone cannot express that. Full detail — nixpkgs channel-branch
exemption, tag-vs-branch resolution, FlakeHub yank handling, the per-package npm/GitHub
audit layer, and the pin rituals for nvf/Pulumi/agent-browser/Gram — in
`docs/supply-chain.md`.

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

`infra/` is the only npm tree in this repo (Pulumi, pnpm 11). `just pulumi-audit` checks
against OSV and additionally flags anything published inside the cooldown window.
**Work the ladder top-down, stop at the first rung that applies:** (1) fixed version
fits the parent's declared semver range → `pnpm update <pkg> --depth Infinity`,
lockfile only; (2) it doesn't fit → bump the direct dependency in `package.json`;
(3) `pnpm.overrides`/`resolutions` — **never**, rejected once on evidence (broke the
Pulumi SDK at load); (4) fix is younger than the 3-day cooldown → exempt via
`minimumReleaseAgeExclude`, **never lower the floor itself**.

**Undercutting a cooldown is not negotiable: research first, fetch second.** `pnpm
update` downloads and unpacks the tarball, and `tsc`/Pulumi then import it — by the
time a test could fail, the code has already run on a machine holding this repo's SOPS
secrets and cloud credentials. Establish via registry *metadata only* (no install) that
the specific `package@version` is not part of a live supply-chain incident — maintainer
set, provenance, GitHub Security Advisories, Socket/StepSecurity/Snyk/OpenSSF — *before*
adding the exclude entry. If research can't conclude cleanly, wait out the cooldown and
mitigate another way. The same precondition governs every other cooldown here (the uv
`exclude-newer-package` overrides, `modules/supply-chain-hardening.nix`'s floors). Before
committing: `just pulumi-audit` clean, `cd infra && pnpm audit` clean, `pnpm exec tsc
--noEmit` green. Full ladder detail and worked commit examples: `docs/supply-chain.md`.
