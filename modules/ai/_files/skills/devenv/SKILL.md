---
name: devenv
description: >
  Nix-based declarative developer environments with devenv (v2.0+). Use this skill whenever devenv.nix,
  devenv.yaml, devenv shell, devenv processes, devenv services, devenv tasks, devenv containers, or
  devenv options are mentioned or implied. Also trigger when the user asks about setting up reproducible
  development environments with Nix, configuring languages/services/processes declaratively, managing
  secrets with SecretSpec, integrating with direnv, devcontainers, or Claude Code in a devenv context,
  or when .envrc files reference `use devenv`. Trigger for ad-hoc Nix environments (`devenv -O`),
  polyrepo/monorepo setups, devenv profiles, devenv outputs, or devenv LSP/MCP. Even if the user just
  says "set up my project environment" or "I need MySQL and Java for local dev", consider this skill.
allowed-tools: Read(references/*) mcp__devenv__search_options mcp__devenv__search_packages Bash(zsh *) Read
---

# Devenv — Nix-Based Declarative Developer Environments

## What devenv is

Devenv is an abstraction over Nix that provides declarative, reproducible developer environments
via a module system (`devenv.nix` + `devenv.yaml`). It supports 50+ languages, 40+ services,
a native process manager, tasks, containers, secrets, git-hooks, and more — all configured in Nix
but without requiring deep Nix expertise.

**Version context**: devenv 2.0 was released on 2026-03-05 and is the current version.

## Core files

| File | Purpose |
|---|---|
| `devenv.nix` | Main configuration (Nix module: `{ pkgs, config, lib, inputs, ... }: { ... }`) |
| `devenv.yaml` | Inputs, imports, and overrides (YAML) |
| `devenv.lock` | Pinned input versions (auto-generated, commit this) |
| `.envrc` | Direnv integration (optional since 2.0) |
| `.devenv/` | Generated state directory (gitignored) |
| `secretspec.toml` | Secret declarations (SecretSpec, optional) |

## Key devenv 2.0 features

1. **Incremental evaluation caching**: C FFI backend via `nix-bindings-rust`. Sub-100ms for cached evaluations.
2. **Terminal UI (TUI)**: Live structured progress, dependency hierarchy, auto-expanding errors.
3. **Native shell reloading** (bash only, zsh/fish planned): Background rebuild, apply with `Ctrl+Alt+R`.
4. **Native Rust process manager**: Dependency ordering, restart policies, readiness probes, socket activation, file watching, automatic port allocation.
5. **Polyrepo support**: Reference outputs from other devenv projects via `inputs.<name>.devenv.config`.
6. **Out-of-tree devenvs**: `devenv --from github:myorg/configs shell`
7. **Ad-hoc environments**: `devenv -O languages.rust.enable:bool true -O packages:pkgs "ncdu git" shell`
8. **LSP for devenv.nix**: Autocomplete, hover docs, go-to-definition via bundled `nixd`.
9. **MCP server**: AI agents can query/manipulate devenv configuration programmatically.

## Minimal example

```nix
# devenv.nix
{ pkgs, config, ... }:
{
  languages.java = { enable = true; jdk.package = pkgs.jdk21; };
  services.mysql = { enable = true; initialDatabases = [{ name = "myapp"; }]; };
  packages = [ pkgs.kubectl pkgs.kubernetes-helm ];

  processes.backend = {
    exec = "mvn spring-boot:run";
    ports.http.allocate = 8080;
    ready.http.get = {
      port = config.processes.backend.ports.http.value;
      path = "/actuator/health";
    };
  };

  enterShell = ''
    echo "Dev environment ready. Java $(java --version | head -1)"
  '';
}
```

## Running commands

```bash
devenv shell                          # Enter environment
devenv shell -- mvn test              # Run command inside environment
devenv up                             # Start all processes (native manager)
devenv test                           # Run tests defined in devenv.nix
devenv search <package>               # Search nixpkgs
devenv info                           # Show environment info
devenv update                         # Update inputs from devenv.yaml
devenv container <name> --docker-run  # Build & run container
```

## Setup

For full setup instructions with language-specific examples: read `references/setup.md`.

1. Check the version, must be 2.x: `devenv --version`
2. Run `devenv init`
3. Update generated files
    - `devenv.nix`: use the devenv MCP server (`mcp__devenv__search_packages`, `mcp__devenv__search_options`) to find packages and options
    - `devenv.yaml`: probably no changes needed
4. Test the configuration:
    - `devenv shell -- pwd`
    - Depending on installed packages: `devenv shell -- python --version`, `devenv shell -- node --version`, etc.
    - Fix all errors until these commands work
5. Add and test typical tasks for development (the user can allowlist them for efficient development)
6. (Optional, ask user) Setup direnv — see Direnv section below
7. If git repo:
    - Add `devenv.nix`, `devenv.yaml`, `devenv.lock`, `.envrc` to git
    - Ignore `.devenv/` `.direnv/`: Ask the user if you should add them to `.gitignore` or `.git/info/exclude`

## Ad-hoc environments (no devenv.nix needed)

```bash
devenv -O languages.python.enable:bool true \
       -O packages:pkgs "ncdu ripgrep" \
       shell -- python script.py
```

`packages:pkgs` appends; `packages:pkgs!` replaces. Types: `string`, `int`, `float`, `bool`, `path`, `pkg`, `pkgs`.

## Direnv integration

Since devenv 2.0, direnv is **optional** — `devenv shell` with native reloading is the primary workflow.
Direnv remains useful for auto-activation on directory change and editor integration.

Quick setup (`.envrc`):

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
```

Then run `direnv allow`.

For layouts, pinned versions, decision table, and known issues: read `references/direnv.md`.

## Tasks

Tasks enable dependency-ordered, parallel execution of commands. Wrap agent commands as tasks
so the user can allowlist `Bash(devenv tasks run agent:*)`:

```nix
{
  tasks."agent:build" = { exec = "mvn package -DskipTests"; };
  tasks."agent:test"  = { exec = "mvn test"; };
}
```

```bash
devenv tasks run agent:build
```

For lifecycle events, status/caching, input/output, and namespace conventions: read `references/tasks.md`.

## Git hooks

Devenv integrates git-hooks.nix for declarative linting/formatting at commit time.
Hooks install automatically on `devenv shell`.

```nix
{ git-hooks.hooks = { nixpkgs-fmt.enable = true; prettier.enable = true; }; }
```

For built-in hooks, custom hooks, and Claude Code auto-format: read `references/git-hooks.md`.

## Secrets management

- **SecretSpec** (devenv-native): read `references/secretspec.md`
- **Sops-nix** alternative: `dotenv.enable = true; dotenv.filename = "~/.config/sops-nix/secrets/.env";`

## Claude Code integration

Devenv has a first-class Claude Code integration module (`integrations/claude.nix`).
For hooks, agents, MCP servers, and workflow patterns: read `references/claude-code.md`.

## Devcontainer integration

```nix
{ devcontainer.enable = true; }
```

Run `devenv shell` to generate `.devcontainer.json`, then commit it.

## Monorepo & Polyrepo setups

For monorepo imports, polyrepo inputs, and out-of-tree devenvs: read `references/monorepo-polyrepo.md`.

## Using devenv with Nix Flakes

For flake.nix integration, flake-parts setup, and trade-off comparison: read `references/flakes.md`.

**Key trade-off**: Flake integration loses evaluation caching (the big 2.0 feature), lazy trees,
GC protection, SecretSpec, and processes-during-tests. Use Flakes only when you have an existing
flake ecosystem or need the dev environment consumable by downstream flakes.

## Useful options reference

For the full options table: read `references/options.md`.

Common options: `packages`, `languages.<lang>.enable`, `services.<svc>.enable`,
`processes.<name>.exec`, `env.<VAR>`, `enterShell`, `dotenv.enable`, `git-hooks.hooks.<hook>`,
`tasks.<name>`, `scripts.<name>.exec`.

Full reference: https://devenv.sh/reference/options/

## Documentation links

- Getting started: https://devenv.sh/getting-started/
- Options reference: https://devenv.sh/reference/options/
- Languages: https://devenv.sh/languages/
- Services: https://devenv.sh/services/
- Processes: https://devenv.sh/processes/
- Tasks: https://devenv.sh/tasks/
- Containers: https://devenv.sh/containers/
- Direnv: https://devenv.sh/integrations/direnv/
- Git hooks: https://devenv.sh/git-hooks/
- Claude Code: https://devenv.sh/integrations/claude-code/
- SecretSpec: https://devenv.sh/integrations/secretspec/
- Devcontainer: https://devenv.sh/integrations/codespaces-devcontainer/
- Migration 1.x→2.0: https://devenv.sh/guides/migrating-to-2.0/
- MCP: https://devenv.sh/mcp/

## Skill references (load on demand)

| File | Content |
|---|---|
| `references/setup.md` | Setup instructions, language-specific examples (Python/uv, Node, Bun, Scala CLI, Java/Gradle) |
| `references/options.md` | Options reference table with types and descriptions |
| `references/secretspec.md` | SecretSpec: toml structure, all providers, CLI, devenv integration |
| `references/claude-code.md` | Claude Code: hooks (all types), agents, MCP servers, workflow patterns |
| `references/monorepo-polyrepo.md` | Monorepo imports, polyrepo inputs, out-of-tree devenvs |
| `references/direnv.md` | Direnv: all layouts, stdlib commands, combining with devenv, known issues |
| `references/git-hooks.md` | Git hooks: built-in hooks, custom hooks, Claude Code auto-format, per-language recipes |
| `references/flakes.md` | Nix Flakes: plain flake.nix, flake-parts, feature comparison, multiple shells |
| `references/tasks.md` | Tasks: defining, dependencies, lifecycle events, agent-friendly patterns, allowlisting |
