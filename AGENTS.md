# Repository Guidelines

This file provides guidance to AI coding agents when working with code in this repository.

## Repository Overview

This is a Nix-darwin configuration repository for managing macOS systems (Stefan Schwetschke's personal dotfiles). It uses Nix flakes, flake-parts, nix-darwin, Home Manager, and Determinate Nix for declarative system configuration on Apple Silicon Macs.

The repository follows the **Dendritic Pattern** for Nix flake structure — use the `/nix-dendritic-pattern` skill for detailed guidance on creating and modifying modules.

**Current Hosts:**
- `FCX19GT9XR` - Personal Mac (user: `stefan`)
- `DKL6GDJ7X1` - Work Mac (user: `stefan.schwetschke`)

## Build, Test, and Development Commands

A `justfile` provides safe, pre-approved commands that agents can run without user approval. Raw `nix` and `darwin-rebuild` commands require user approval.

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

### Commands requiring user approval

These cannot run inside the agent sandbox or need explicit confirmation:

```bash
# Apply configuration (requires sudo)
sudo darwin-rebuild switch --flake .

# Dry-run switch (requires sudo)
sudo darwin-rebuild switch --flake . --dry-run

# Build for a specific host directly
nix build .#darwinConfigurations.DKL6GDJ7X1.system
nix build .#darwinConfigurations.FCX19GT9XR.system

# Show package delta between current and new system
nix store diff-closures /run/current-system result
```

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

## Coding Style & Naming Conventions

- **Indentation:** 2 spaces
- **Attribute sets:** Keep alphabetized within logical groups
- **Host naming:** Mirror host serials exactly (`FCX19GT9XR`, `DKL6GDJ7X1`)
- **Format before committing:** `just fmt` or `nix run nixpkgs#nixpkgs-fmt -- <files>`
- **Module pattern:** Each module file exports `flake.modules.<class>.<name>` — see `/nix-dendritic-pattern` skill

## Commit & Pull Request Guidelines

Use Conventional Commits: `type(scope): subject` (imperative present tense, ≤72 chars)

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Common scopes:** `home`, `homebrew`, `darwin`, `flake`, `secrets`, `macos`, `env`, `project`, `docs`

**Examples:**
- `feat(home): Add Claude Code MCP servers for Atlassian and Context7`
- `fix(darwin): Correct Emoji & Symbols keyboard shortcut`
- `chore(flake): Update nixpkgs to 25.11`

Include host IDs and commands executed in commit body when relevant. Iterate with fixups (`git commit -m "fixup! …"`); run `git push --dry-run` and wait for explicit approval before pushing.

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
