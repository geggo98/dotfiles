# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Nix-darwin configuration repository for managing macOS systems (Stefan Schwetschke's personal dotfiles). It uses Nix flakes, nix-darwin, Home Manager, and Determinate Nix for declarative system configuration on Apple Silicon Macs.

**Current Hosts:**
- `FCX19GT9XR` - Personal Mac (user: `stefan`)
- `DKL6GDJ7X1` - Work Mac (user: `stefan.schwetschke`)

## Essential Commands

### Building and Testing
```bash
# Preview changes with dry-run for current host.
darwin-rebuild build --flake .
# `sudo` is not possible in the AI agent sandbox. User must run this command manually.
sudo darwin-rebuild switch --flake . --dry-run

# If this fails, try building for one specific host.
nix build .#darwinConfigurations.DKL6GDJ7X1.system
nix build .#darwinConfigurations.FCX19GT9XR.system

# Apply configuration to the current host
# `sudo` is not possible in the AI agent sandbox. User must run this command manually.
sudo darwin-rebuild switch --flake .
```

### Updating Dependencies
```bash
# Update all flake inputs
nix flake update

# Update single input
nix flake lock --update-input <input-name>
```

### Code Quality
```bash
# Format Nix code
nix run nixpkgs#nixpkgs-fmt -- <files>

# Check all configurations
nix flake check
```

### Compare System Changes
```bash
# Show package delta between current and new system
nix store diff-closures /run/current-system result
```

## Architecture

### Entry Point
- **`flake.nix`** - Defines darwinConfigurations for each host, registers overlays, and configures inputs

### Core Configuration Files
- **`configuration.nix`** - Global defaults for all hosts (fonts, nix-index, TouchID sudo, keyboard shortcuts)
- **`darwin.nix`** - macOS-specific defaults (dock, finder, trackpad, system preferences)
- **`determinate.nix`** - Determinate Nix module settings (`nix.enable = false` lets Determinate manage Nix)
- **`home.nix`** - Base Home Manager profile (packages, shells, secrets management, MCP servers, nvf)

### Host-Specific Configuration
Each host has its own directory under `hosts/<serial>/`:
- `configuration.nix` - Host-specific nix-darwin settings (primaryUser, user home directory)
- `home.nix` - Host-specific Home Manager overrides (merged with base `home.nix`)
- `homebrew.nix` - Host-specific Homebrew casks and formulae

### Modules
- **`modules/homebrew-common.nix`** - Shared Homebrew configuration (common casks/brews across hosts)
- **`modules/aichat.nix`** - AI chat tool configuration

### Important: Nix Management by Determinate
This repository uses Determinate Nix to manage the Nix installation, **not** nix-darwin's built-in Nix management. Both `determinate.nix` and `configuration.nix` set `nix.enable = false`. Determinate settings go in `/etc/nix/nix.custom.conf` via `determinate-nix.customSettings`.

### Secret Management with SOPS
- **Location:** `secrets/secrets.enc.yaml`
- **Decryption keys:** SSH Ed25519 key at `~/.ssh/id_ed25519_sops_nopw` (passwordless)
- **Secrets declaration:** In `home.nix` under `sops.secrets`
- **Critical note:** SOPS does not work in the Claude Code sandbox - users must edit secrets manually
- **Edit command:** `env SOPS_AGE_KEY=$(ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key) sops edit secrets/secrets.enc.yaml`

### MCP Servers
MCP servers are defined in `home.nix` under `programs.claude-code.mcpServers`. Each server wrapper is a shell script that:
1. Loads secrets from `$XDG_CONFIG_HOME/sops-nix/secrets` (or `~/.config/sops-nix/secrets`)
2. Validates required environment variables
3. Executes the server (via Docker, Node.js, or native binaries)

Current MCP servers:
- `atlassian` - Docker-based, requires CONFLUENCE_*, JIRA_* environment variables
- `context7` - Node.js-based, requires CONTEXT7_API_KEY
- `javadocs` - Remote MCP via mcp-remote
- `nixos` - Native mcp-nixos binary
- `travily` - Node.js-based, requires TRAVILY_API_KEY
- `zai-search` - Remote MCP via mcp-remote, requires Z_AI_API_KEY
- `zai-vision` - Node.js-based (@z_ai/mcp-server), requires Z_AI_API_KEY
- `zai-web-reader` - Remote MCP via mcp-remote, requires Z_AI_API_KEY

### Neovim Configuration (nvf)
- Uses nvf (Neovim Framework) wrapper around `programs.nvf`
- Configuration in `home.nix` under `programs.nvf.settings.vim`
- Includes plugins for Git, LSP, autocomplete, UI enhancement, and AI assistance

## Coding Style

- **Indentation:** 2 spaces
- **Attribute sets:** Keep alphabetized within logical groups
- **Host naming:** Mirror host serials exactly (`FCX19GT9XR`, `DKL6GDJ7X1`)
- **Format before committing:** Use `nixpkgs-fmt`

## Commit Guidelines

Use Conventional Commits: `type(scope): subject` (imperative present tense, ≤72 chars)

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Common scopes:** `home`, `homebrew`, `darwin`, `flake`, `secrets`, `macos`, `env`, `project`, `docs`

**Examples:**
- `feat(home): Add Claude Code MCP servers for Atlassian and Context7`
- `fix(darwin): Correct Emoji & Symbols keyboard shortcut`
- `chore(flake): Update nixpkgs to 25.11`

Include host IDs and commands executed in commit body when relevant.

## Common Patterns

### Adding a New Host
1. Create `hosts/<serial>/` directory
2. Add `configuration.nix` with user home and primaryUser
3. Add optional `home.nix` for Home Manager overrides
4. Add optional `homebrew.nix` for host-specific brews/casks
5. Add host to `flake.nix` darwinConfigurations

### Adding a New Secret
1. User edits secrets with: `env SOPS_AGE_KEY=$(ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key) sops edit secrets/secrets.enc.yaml`
2. Agent adds secret to `home.nix` sops.secrets with explicit path and mode (0600 for sensitive data)
3. Access via `config.sops.secrets.<name>.path` in configurations

### Adding an MCP Server
1. Create shell wrapper script in `home.nix` (see existing mcp-* wrappers)
2. Add to `programs.claude-code.mcpServers` with command path
3. Ensure secret loading logic follows the pattern of existing wrappers
