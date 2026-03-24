# Direnv Reference

Documentation:
- Devenv + direnv: https://devenv.sh/integrations/direnv/
- Direnv stdlib (layouts, commands): https://direnv.net/man/direnv-stdlib.1.html
- Direnv wiki: https://github.com/direnv/direnv/wiki

## Role of direnv with devenv 2.0

Since devenv 2.0, direnv is **optional** for the primary workflow. `devenv shell`
with native background reloading (bash only) is the default. Direnv remains
useful for:

- Automatic activation when `cd`-ing into a project directory
- Editor integration (VS Code, IntelliJ, Zed — they detect direnv)
- zsh/fish users (native shell reloading is bash-only for now)
- Combining devenv with direnv layouts (see below)

## .envrc setup

### Recommended (devenv 2.0+, auto-updates)

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
```

### Pinned version (auditable, manual update)

```bash
#!/usr/bin/env bash
source_url "https://raw.githubusercontent.com/cachix/devenv/<COMMIT>/direnvrc" "<SHA256>"
use devenv
```

After creating `.envrc`: `direnv allow`

## Direnv layouts

Direnv's `layout` command sets up language-specific directory structures.
These are independent of devenv and can be **combined** with `use devenv`
in the same `.envrc`.

### layout node

Adds `$PWD/node_modules/.bin` to PATH.

This is essential for projects where tools are installed via `package.json`
(e.g., `eslint`, `prettier`, `tsc`, `vitest`). Without this, locally installed
npm binaries are not on PATH unless you use `npx`.

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
layout node
```

### layout python / layout python3

Creates and activates a virtualenv under `$PWD/.direnv/python-$version`.
Forces all pip installs into the project subfolder.

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
layout python3
```

Note: devenv has its own `languages.python.venv.enable = true` which manages
a venv at `.devenv/state/venv/`. Using both simultaneously is redundant.
Prefer devenv's venv for Nix-managed Python; use `layout python3` only if
you need direnv-managed venv without devenv's Python integration.

### layout go

Adds `$(direnv_layout_dir)/go` to GOPATH and `$PWD/bin` to PATH.

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
layout go
```

### layout ruby

Sets GEM_HOME to `$PWD/.direnv/ruby/RUBY_VERSION`. Forces gems into
the project subfolder. Bundler wrapper programs are invocable directly.

### layout php

Adds `$PWD/vendor/bin` to PATH (Composer binaries).

### layout perl

Sets up `local::lib` environment.

### layout pipenv

Like `layout python` but uses Pipenv and `Pipfile`.

### layout pyenv [version ...]

Like `layout python` but uses pyenv to build the virtualenv.

## Combining layouts with devenv

The typical pattern: devenv provides the **base toolchain** (compilers, system
packages, services), while `layout` adds **project-local binaries** to PATH.

Example: Java/Spring Boot project with a Node.js frontend build:

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv          # Provides JDK, Maven, MySQL, kubectl from devenv.nix
layout node         # Adds node_modules/.bin to PATH for npm-installed tools
```

Example: Python project with pip-managed tools:

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv          # Provides Python, system libs from devenv.nix
# Don't use layout python3 here — devenv manages the venv via
# languages.python.venv.enable = true
```

## Useful stdlib commands

### PATH_add

Manually add directories to PATH:

```bash
PATH_add bin                    # $PWD/bin
PATH_add scripts                # $PWD/scripts
PATH_add .gradle/bin            # Gradle wrapper
```

### dotenv / dotenv_if_exists

Load `.env` files (separate from devenv's `dotenv.enable`):

```bash
dotenv_if_exists .env.local     # Load local overrides if present
```

### source_env_if_exists

Load a private/local `.envrc` that is gitignored:

```bash
source_env_if_exists .envrc.local   # Developer-specific overrides
```

### source_up

Load a parent directory's `.envrc` (useful in monorepos):

```bash
source_up                       # Loads ../.envrc if it exists
```

### env_vars_required

Validate required environment variables:

```bash
source_env_if_exists .envrc.private
env_vars_required GITHUB_TOKEN API_KEY
```

## Known issues

### devcontainer + direnv + VS Code

The combination of devenv inside a devcontainer with the VS Code direnv
extension can cause infinite Nix process spawning (GitHub issue #1824).
Workaround: disable the VS Code direnv extension inside the container.

### Shell freeze during rebuild

Classic direnv problem: prompt locks up during Nix evaluation. Devenv 2.0's
native shell reloading solves this for bash users. For zsh/fish, the freeze
persists when using direnv.
