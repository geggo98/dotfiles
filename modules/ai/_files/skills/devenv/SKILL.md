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

1. **Inkrementelles Evaluation-Caching**: C FFI backend via `nix-bindings-rust` instead of spawning
   multiple `nix` CLI processes. Sub-100ms for cached evaluations. Each attribute cached individually
   with content-hash verification.

2. **Terminal UI (TUI)**: Every command shows live structured progress, dependency hierarchy,
   and auto-expanding errors.

3. **Native shell reloading** (bash only, zsh/fish planned): Background rebuild with status line,
   apply with `Ctrl+Alt+R`. Shell stays interactive during rebuild.

4. **Native Rust process manager**: Replaces process-compose. Supports dependency ordering,
   restart policies, readiness probes (exec/HTTP/systemd-notify), socket activation, watchdog
   heartbeats, file watching, automatic port allocation.

5. **Polyrepo support**: Reference outputs from other devenv projects via `inputs.<name>.devenv.config`.

6. **Out-of-tree devenvs**: `devenv --from github:myorg/configs shell` — use configs from other repos.

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

## Ad-hoc environments (no devenv.nix needed)

```bash
devenv -O languages.python.enable:bool true \
       -O packages:pkgs "ncdu ripgrep" \
       shell -- python script.py
```

`packages:pkgs` appends; `packages:pkgs!` replaces. Types: `string`, `int`, `float`, `bool`, `path`, `pkg`, `pkgs`.

## Direnv integration

Since devenv 2.0, direnv is **optional** — `devenv shell` with native reloading is the primary workflow.
Direnv remains useful for automatic activation on directory change and for editors that depend on it.

### Setup (recommended for 2.0+)

```bash
# .envrc
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
```

### Setup (pinned version)

```bash
# .envrc
#!/usr/bin/env bash
source_url "https://raw.githubusercontent.com/cachix/devenv/<COMMIT>/direnvrc" "<SHA256>"
use devenv
```

After creating `.envrc`, run `direnv allow`.

### When to use direnv vs native shell

| Scenario | Recommendation |
|---|---|
| Primary dev workflow (bash) | `devenv shell` with native reloading |
| zsh or fish users | Direnv (native reloading is bash-only for now) |
| Editor integration (VS Code, IntelliJ) | Direnv + editor extension |
| CI / scripting | `devenv shell -- <command>` |
| Multiple projects, frequent switching | Direnv |

### Direnv layouts — project-local binaries on PATH

Direnv's `layout` command adds language-specific local binaries to PATH.
This is **independent of devenv** but combinable with `use devenv` in the same `.envrc`.

Common layouts:

| Layout | Effect |
|---|---|
| `layout node` | Adds `$PWD/node_modules/.bin` to PATH (npm/yarn-installed tools like eslint, tsc, vitest) |
| `layout python3` | Creates/activates virtualenv under `$PWD/.direnv/python-$version` |
| `layout go` | Adds `$(direnv_layout_dir)/go` to GOPATH, `$PWD/bin` to PATH |
| `layout ruby` | Sets GEM_HOME to `$PWD/.direnv/ruby/RUBY_VERSION` |
| `layout php` | Adds `$PWD/vendor/bin` to PATH (Composer) |

Example: devenv provides JDK + MySQL, `layout node` adds npm-installed frontend tools:

```bash
# .envrc
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
layout node
```

Note: For Python, prefer devenv's `languages.python.venv.enable = true` over `layout python3`.
They both manage venvs — using both is redundant.

For full direnv stdlib reference (PATH_add, dotenv, source_up, etc.): read `references/direnv.md`.

### Known issue: devcontainer + direnv + VS Code

The combination of devenv inside a devcontainer with the VS Code direnv extension can cause
infinite Nix process spawning and host crashes (GitHub issue #1824). If using devcontainers,
consider disabling the VS Code direnv extension inside the container.

## Python — IDE virtual environment symlink

For Python projects, IDEs (IntelliJ/PyCharm) need access to the virtual environment.
Devenv stores it in `.devenv/state/venv/`. Create a symlink for IDE compatibility:

```nix
{
  languages.python = {
    enable = true;
    venv.enable = true;
  };

  enterShell = ''
    if [ ! -L "$DEVENV_ROOT/venv" ]; then
        ln -s "$DEVENV_STATE/venv/" "$DEVENV_ROOT/venv"
    fi
  '';
}
```

Then configure IntelliJ/PyCharm to use `./venv` as the Python interpreter path.

## Tasks

Tasks enable dependency-ordered, parallel execution of commands. They integrate with
shell entry (`devenv:enterShell`), tests (`devenv:enterTest`), and processes.

```nix
{
  tasks."myapp:build" = {
    exec = "npm run build";
    before = [ "devenv:enterShell" ];
  };

  tasks."myapp:test" = {
    exec = "npm test";
    before = [ "devenv:enterTest" ];
  };
}
```

```bash
devenv tasks run myapp:build          # Run a single task
devenv tasks run myapp                # Run all tasks in namespace
devenv tasks run myapp:build --input key=value  # Pass input (2.0+)
```

Tasks support `status` (skip if exit 0), `execIfModified` (skip if files unchanged),
`package` (language-specific interpreter), `cwd`, and JSON input/output via environment
variables. Processes become tasks automatically with the `devenv:processes:` prefix.

### Agent-friendly tasks

Wrap frequently used agent commands as devenv tasks so the user can allowlist
`Bash(devenv tasks run agent:*)` in Claude Code permissions — avoiding repeated
security prompts:

```nix
{
  tasks."agent:build" = { exec = "mvn package -DskipTests"; };
  tasks."agent:test"  = { exec = "mvn test"; };
  tasks."agent:lint"  = { exec = "npm run lint"; };
  tasks."agent:fmt"   = { exec = "prettier --write ."; };
}
```

The agent should prefer `devenv tasks run agent:<name>` over raw shell commands
when a matching task exists. Benefits: declarative, cached, dependency-ordered,
and allowlistable with a single permission rule.

For full details (lifecycle events, status/caching, input/output, process integration,
namespace conventions): read `references/tasks.md`.

## Git hooks

Devenv integrates git-hooks.nix for declarative linting/formatting at commit time.
Hooks install automatically on `devenv shell`. For full details, language-specific
recipes, and custom hook fields: read `references/git-hooks.md`.

```nix
{
  git-hooks.hooks = {
    nixpkgs-fmt.enable = true;
    prettier.enable = true;
    shellcheck.enable = true;
    google-java-format.enable = true;
  };
}
```

Verify in CI: `devenv test` runs all hooks against the full codebase.

**Agent integration**: When both `git-hooks` and `claude.code` are enabled,
devenv auto-configures a PostToolUse hook that runs formatting after every
Claude Code file edit. No extra configuration needed — the agent's output
conforms to project style automatically. See `references/git-hooks.md` and
`references/claude-code.md` for details.

## Secrets management

Read the dedicated references for details:
- **SecretSpec** (devenv-native): `references/secretspec.md`
- **Sops-nix** (NixOS-based alternative): see section below

### SecretSpec (quick overview)

SecretSpec separates secret declaration (`secretspec.toml`) from provisioning (providers).
The `secretspec.toml` is committed to git — it contains no actual values.

```toml
# secretspec.toml
[project]
name = "my-app"

[profiles.default]
DATABASE_URL = { description = "DB connection string", required = true }
API_KEY = { description = "External API key", required = true }

[profiles.development]
DATABASE_URL = { default = "mysql://localhost/myapp_dev" }
```

Providers: keyring, dotenv, env, pass, 1Password, LastPass, GCP/AWS Secret Manager, Vault/OpenBao.

For full provider reference and configuration: read `references/secretspec.md`.

### Sops-nix secrets as .env files

When using sops-nix, decrypted secrets are available as files under
`~/.config/sops-nix/secrets/` (or wherever `sops.defaultSecretsMountPoint` is set).

```nix
{
  dotenv.enable = true;
  dotenv.filename = "~/.config/sops-nix/secrets/.env";
}
```

Note: sops-nix and SecretSpec are independent systems. Choose based on deployment context.

## Claude Code integration

Devenv has a first-class Claude Code integration module (`integrations/claude.nix`).

For full details: read `references/claude-code.md`.

### Quick setup

```nix
{
  claude.code = {
    enable = true;

    commands = {
      test = "Run tests\n```bash\nmvn test\n```";
      build = "Build project\n```bash\nmvn package -DskipTests\n```";
    };

    agents.code-reviewer = {
      description = "Reviews code for quality and security";
      proactive = true;
      tools = [ "Read" "Grep" "TodoWrite" ];
      prompt = "You are an expert code reviewer...";
    };
  };
}
```

### Global CLAUDE.md for devenv-aware agents

Create `~/.claude/CLAUDE.md`:

```markdown
When devenv.nix doesn't exist and a command/tool is missing, create ad-hoc environment:
    $ devenv -O languages.rust.enable:bool true -O packages:pkgs "mypackage" shell -- cli args
When the setup becomes complex, create `devenv.nix` and run commands within:
    $ devenv shell -- cli args
See https://devenv.sh/ad-hoc-developer-environments/
```

### Agent workflow patterns

1. **Ad-hoc** (no config): `devenv -O ... shell -- <command>`
2. **Project-bound**: `devenv shell -- <command>` (uses existing devenv.nix)
3. **Declarative agent config**: Hooks, commands, sub-agents in devenv.nix (versioniert, reproduzierbar)

## Devcontainer integration

```nix
{ devcontainer.enable = true; }
# Generates .devcontainer.json (image: ghcr.io/cachix/devenv/devcontainer:latest)
```

Run `devenv shell` to generate `.devcontainer.json`, then commit it.

## Monorepo & Polyrepo setups

For full details with examples: read `references/monorepo-polyrepo.md`.

### Monorepo (single repo, multiple services)

Use `imports` in each service's `devenv.yaml` to share config. Absolute paths
(starting with `/`) resolve from the repo root (where `.git` is).

```
my-monorepo/
├── shared/devenv.nix           # Common packages, services, git-hooks
├── services/api/devenv.yaml    # imports: [/shared]
├── services/api/devenv.nix     # API-specific config
└── services/frontend/...
```

Use `config.git.root` to reference paths relative to the repo root in processes.

### Polyrepo (multiple repos, devenv 2.0)

Two approaches:

1. **Import** (merge entire remote config): Add to `devenv.yaml` as input + import
2. **Reference** (access specific outputs): Use `inputs.<n>.devenv.config.outputs.<x>`

```yaml
# devenv.yaml
inputs:
  my-service:
    url: github:myorg/my-service
    flake: false
imports:         # Approach 1: merge everything
  - my-service
```

```nix
# devenv.nix — Approach 2: reference specific output
{ inputs, ... }:
let svc = inputs.my-service.devenv.config.outputs.my-service;
in { packages = [ svc ]; }
```

Caveat: remote repo must use `devenv.nix` only — `devenv.yaml` is NOT evaluated (#2205).

### Out-of-tree devenvs

Use a devenv configuration from another repo: `devenv --from github:myorg/configs shell`

## Using devenv with Nix Flakes

Devenv can be integrated into a `flake.nix` as a `devShell` output. This allows
using devenv's module system (languages, services, processes) inside an existing
Flake-based project, entered via `nix develop --no-pure-eval`.

For full details, examples, and the feature comparison table: read `references/flakes.md`.

### Trade-offs vs standalone devenv CLI

Flake integration loses: evaluation caching (the big 2.0 feature), lazy trees, GC protection,
SecretSpec, and processes-during-tests. Use Flakes only when you have an existing flake ecosystem
or need the dev environment consumable by downstream flakes.

### Plain flake.nix (single system or manual iteration)

```nix
# flake.nix (minimal)
{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
  };
  outputs = { self, nixpkgs, devenv, ... } @ inputs:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = devenv.lib.mkShell {
        inherit inputs pkgs;
        modules = [{
          languages.java.enable = true;
          services.mysql.enable = true;
        }];
      };
    };
}
```

### flake-parts (recommended for multi-platform)

flake-parts eliminates `forEachSystem` boilerplate. The `systems` attribute defines
which platforms (x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin) to build for.

```nix
# flake.nix with flake-parts
{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    devenv.url = "github:cachix/devenv";
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
  };
  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.devenv.flakeModule ];
      systems = nixpkgs.lib.systems.flakeExposed;

      perSystem = { config, pkgs, ... }: {
        devenv.shells.default = {
          languages.java.enable = true;
          services.mysql.enable = true;
        };
      };
    };
}
```

Enter with `nix develop --no-pure-eval`. Multiple named shells via `devenv.shells.<name>`,
entered as `nix develop .#<name> --no-pure-eval`.

Scaffold: `nix flake init --template github:cachix/devenv` (plain) or
`nix flake init --template github:cachix/devenv#flake-parts` (flake-parts).

## Useful options reference

| Option | Type | Description |
|---|---|---|
| `packages` | `[pkgs.*]` | Packages available in shell |
| `languages.<lang>.enable` | bool | Enable language toolchain |
| `services.<svc>.enable` | bool | Enable managed service |
| `processes.<name>.exec` | string | Process command |
| `processes.<name>.ports.<n>.allocate` | int | Auto-allocate port (hint) |
| `processes.<name>.after` | `[string]` | Dependency ordering |
| `processes.<name>.ready.http.get` | attrset | HTTP readiness probe |
| `env.<VAR>` | string | Environment variable |
| `enterShell` | string | Bash on shell entry |
| `enterTest` | string | Bash for `devenv test` |
| `dotenv.enable` | bool | Load `.env` file |
| `git-hooks.hooks.<hook>` | attrset | Git hook config |
| `devcontainer.enable` | bool | Generate `.devcontainer.json` |
| `scripts.<name>.exec` | string | Named script |
| `tasks.<name>` | attrset | Task with dependencies |
| `tasks.<name>.before` | `[string]` | Run before these tasks/events |
| `tasks.<name>.after` | `[string]` | Run after these tasks |
| `tasks.<name>.status` | string | Skip exec if status exits 0 |
| `tasks.<name>.execIfModified` | `[string]` | Run only when files change |
| `tasks.<name>.package` | package | Interpreter for exec |
| `tasks.<name>.cwd` | string | Working directory |
| `tasks.<name>.input` | attrset | JSON input via `$DEVENV_TASK_INPUT` |

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
- Direnv stdlib (layouts): https://direnv.net/man/direnv-stdlib.1.html
- Git hooks: https://devenv.sh/git-hooks/
- Claude Code: https://devenv.sh/integrations/claude-code/
- SecretSpec: https://devenv.sh/integrations/secretspec/ / https://secretspec.dev/
- SecretSpec providers: https://secretspec.dev/reference/providers/
- Devcontainer: https://devenv.sh/integrations/codespaces-devcontainer/
- Migration 1.x→2.0: https://devenv.sh/guides/migrating-to-2.0/
- Polyrepo: https://devenv.sh/guides/polyrepo/
- Monorepo: https://devenv.sh/guides/monorepo/
- Using with Flakes: https://devenv.sh/guides/using-with-flakes/
- Using with flake-parts: https://devenv.sh/guides/using-with-flake-parts/
- flake-parts docs: https://flake.parts/
- MCP: https://devenv.sh/mcp/
- LSP: https://devenv.sh/lsp/

## Skill references (load on demand)

| File | Content |
|---|---|
| `references/secretspec.md` | SecretSpec: toml structure, all providers, CLI, devenv integration, auto-generation |
| `references/claude-code.md` | Claude Code: hooks (all types), agents, MCP servers, workflow patterns |
| `references/monorepo-polyrepo.md` | Monorepo imports, polyrepo inputs, out-of-tree devenvs, config.git.root |
| `references/direnv.md` | Direnv: all layouts, stdlib commands, combining with devenv, known issues |
| `references/git-hooks.md` | Git hooks: built-in hooks, custom hooks, package overrides, Claude Code auto-format, per-language recipes |
| `references/flakes.md` | Nix Flakes: plain flake.nix, flake-parts, feature comparison, multi-platform, multiple shells |
| `references/tasks.md` | Tasks: defining, dependencies, lifecycle events, status/caching, input/output, agent-friendly patterns, allowlisting |
