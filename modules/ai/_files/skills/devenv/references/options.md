# Devenv Options Reference

Use `mcp__devenv__search_options` to search for options interactively.

## Common options

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

## Task options

| Option | Type | Description |
|---|---|---|
| `tasks.<name>.exec` | string | Command to execute |
| `tasks.<name>.before` | `[string]` | Run before these tasks/events |
| `tasks.<name>.after` | `[string]` | Run after these tasks |
| `tasks.<name>.status` | string | Skip exec if status exits 0 |
| `tasks.<name>.execIfModified` | `[string]` | Run only when files change |
| `tasks.<name>.package` | package | Interpreter for exec |
| `tasks.<name>.cwd` | string | Working directory |
| `tasks.<name>.input` | attrset | JSON input via `$DEVENV_TASK_INPUT` |

## Python-specific options

| Option | Type | Description |
|---|---|---|
| `languages.python.enable` | bool | Enable Python |
| `languages.python.package` | package | Python package (default: pkgs.python3) |
| `languages.python.venv.enable` | bool | Create virtualenv in `.devenv/state/venv` |
| `languages.python.uv.enable` | bool | Enable uv package manager |
| `languages.python.uv.sync.enable` | bool | Auto-run `uv sync` on shell entry |

## Java-specific options

| Option | Type | Description |
|---|---|---|
| `languages.java.enable` | bool | Enable Java |
| `languages.java.jdk.package` | package | JDK package (default: pkgs.jdk) |
| `languages.java.maven.enable` | bool | Enable Maven |
| `languages.java.gradle.enable` | bool | Enable Gradle |

## JavaScript/Node-specific options

| Option | Type | Description |
|---|---|---|
| `languages.javascript.enable` | bool | Enable Node.js |
| `languages.javascript.package` | package | Node package (default: pkgs.nodejs) |
| `languages.javascript.npm.install.enable` | bool | Auto-run `npm install` on shell entry |

Full reference: https://devenv.sh/reference/options/
