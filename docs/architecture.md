---
paths:
  - "flake.nix"
  - "modules/hosts/**"
  - "modules/flake-parts.nix"
  - "modules/*-wiring.nix"
---

# Architecture: Dendritic Pattern, module list, hosts, adding modules and hosts

This is a Nix-darwin repository for macOS on Apple Silicon (Stefan Schwetschke's personal
dotfiles). It uses Nix flakes, flake-parts, nix-darwin, Home Manager and Determinate Nix.
The `/dendritic-nix` skill has the full guidance for creating and changing modules.

## Hosts

- `FCX19GT9XR` — personal Mac (user `stefan`).
- `DKL6GDJ7X1` — work Mac (user `stefan.schwetschke`). Holds the CHECK24 work credentials
  (`jira_*`, `confluence_*`, `absence_io_*`, `c24_bi_kfz_*`) in
  `hosts/DKL6GDJ7X1/secrets.enc.yaml`, and is the only host with `my.ai.atlassian.enable`.
- `p-ion-berlin-xs56r6` — IONOS Core VPS, `x86_64-linux` (NixOS). Named per
  `infra/Naming.md`. Not a darwin host: it is selected by name rather than hardware serial
  and is **not** applied with `just switch`. Full detail: `docs/ionos-vps.md`.

## Dendritic Pattern with flake-parts

Every file in `./modules/` is a flake-parts module organized by feature (aspect), not by
configuration class. `flake.nix` uses `flake-parts.lib.mkFlake` and auto-imports all
modules via `import-tree ./modules`. Each module defines one aspect across all relevant
classes (darwin, homeManager, …) with `flake.modules.<class>.<name>`.

## Module structure (`modules/`)

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
| `errlog.nix` | `+errlog`: stderr of noisy commands into a file, masked, exit code kept; ships its own global rule |
| `secrets.nix` | SOPS declarations, per-host merging (**home-manager only** — servers use `nixos-secrets.nix`) |
| `nixos-wiring.nix` | Defines `configurations.nixos` and wires `flake.nixosConfigurations`/`deployTargets` |
| `nixos-base.nix` | Baseline for every NixOS host: sshd, authorized keys, lockout assertions, serial getty |
| `nixos-tailscale.nix` | Tailscale SSH — userspace, not sshd, not firewall-gateable. See `docs/ionos-vps.md` |
| `nixos-wireguard-home.nix` | WireGuard to the home FRITZ!Box, proxy-ARP addressing |
| `nixos-backup-copy.nix` | Second restic copy, R2 → Dropbox; ciphertext only |
| `nixos-secrets.nix` | sops-nix on the **nixos** class — decrypts to `/run/secrets/`, host-generated key |
| `stream-deck.nix` | Pinned release builds of own Stream Deck plugins, copied (not symlinked) into the app's Plugins directory; option `my.streamDeck.enable`, work Mac only |
| `misc.nix` | Key remapping, Hammerspoon, misc home config |
| `iterm2-claude-hooks.nix` | iTerm2's Claude Code status hooks, option `my.iterm2.claudeCodeHooks.enable` ([docs](https://iterm2.com/claude-code-integration.html)) |
| `onepassword.nix` | Generates `~/.config/1Password/ssh/agent.toml`. See `docs/ionos-vps.md` |
| `aichat.nix` / `ai-tools.nix` | AI chat tool config; general AI tool packages (`llm`, Ollama, `+nix-query`) |
| `boundary.nix` | HashiCorp Boundary PM2-managed proxies (work host) |
| `vault.nix` | `+vault`/`+vault-login` wrappers. See `docs/secrets.md` |
| `vscode.nix` | VS Code extensions + settings.json + theme. See `docs/vscode.md` |
| `overlays.nix` / `formatter.nix` | Nixpkgs overlays; `nix fmt` formatter |

## Host definitions (`modules/hosts/`)

Each host is a flake-parts module that composes aspect modules:

- `modules/hosts/FCX19GT9XR.nix` — personal Mac: imports `darwin.{macos,determinate,homebrew}`
  and `homeManager.{shell,git,neovim,mcp-servers,aichat,ai-tools,packages,misc,secrets-FCX19GT9XR}`.
- `modules/hosts/DKL6GDJ7X1.nix` — work Mac: same pattern plus
  `homeManager.{boundary,vault,stream-deck}`.

Host-specific secrets declarations live in `hosts/<serial>/secrets.nix`.

## Key architectural decisions

- **Value sharing:** through `let` bindings and `config.flake.modules` — never through `specialArgs`.
- **Module type:** `deferredModule`, for its merge semantics.
- **Auto-import:** `import-tree ./modules` discovers all module files.
- **Nix management:** Determinate Nix manages the Nix installation, not nix-darwin's built-in `nix.enable`.
- **SIP restriction:** `launchd.envVariables` is blocked by macOS SIP. For GUI-app env vars
  (for example PATH), use a `launchd.user.agents` entry that runs `/bin/launchctl setenv` at login.
- **launchd jobs get no shell environment:** the converse of the SIP restriction. An
  agent/daemon inherits only `PATH`, `SSH_AUTH_SOCK` and the XPC keys, never
  `home.sessionVariables` or an rc file's exports, and must never fall back silently when one
  is missing. Worked examples (with a caught bug): `docs/launchd.md`.
- **Binary cache (R2):** both hosts share a Cloudflare R2 cache. Push is async via the
  `nix-cache-drain` LaunchDaemon, not the build itself. First enabling it needs one
  `just daemon-restart`. Full detail: `docs/nix-cache.md`.

## Coding style

- 2-space indentation; keep attribute sets alphabetized within logical groups.
- Format before committing: `just fmt` or `nix run nixpkgs#nixpkgs-fmt -- <files>`.
- Each module file exports `flake.modules.<class>.<name>`.
- Macs mirror their hardware serial exactly; everything else follows `infra/Naming.md`.

## Adding a new module

1. Create `modules/<aspect>.nix`.
2. Export `flake.modules.<class>.<name>` (for example `flake.modules.homeManager.my-feature`).
3. Import it in the relevant host files under `modules/hosts/<serial>.nix`.
4. `git add -N` the new file (see `docs/commands.md`).

## Adding a new host

1. Create `modules/hosts/<serial>.nix` composing existing aspect modules.
2. Create `hosts/<serial>/secrets.nix` for host-specific secret declarations.
3. `import-tree` discovers the host.

## Special-purpose areas

- **iTerm2 Web profile:** `modules/misc.nix` installs a `Web` profile whose `Initial URL`
  carries DuckDuckGo's `k*` settings params. Detail: `docs/iterm2-duckduckgo.md`.
- **DevDocs offline index:** `modules/devdocs.nix`, 39 doc families, hash-pinned in
  `modules/_files/devdocs/docs.lock.json`. Detail: `docs/devdocs.md`.
- **VS Code extensions:** pinned in `modules/vscode.nix`. VS Code itself stays a Homebrew
  cask, deliberately not nixpkgs. Detail: `docs/vscode.md`.
