# Devenv Setup Guide

## Quick start

1. Check the version: `devenv --version` (must be 2.x)
2. Run `devenv init` in the project directory
3. Edit `devenv.nix` — use the devenv MCP server to search for packages and options
4. Test: `devenv shell -- pwd`
5. Test language tools: `devenv shell -- python --version`, `devenv shell -- node --version`, etc.
6. Fix errors until all commands work

## Language-specific examples

### Python with uv

```nix
# devenv.nix
{ pkgs, ... }:
{
  languages.python = {
    enable = true;
    uv.enable = true;
    # uv.sync.enable = true;  # uncomment once pyproject.toml exists
  };
}
```

Test: `devenv shell -- uv --version && devenv shell -- python --version`

Notes:
- Only enable `uv.sync.enable = true` when the project has a `pyproject.toml` — without it, the task fails with "No pyproject.toml found"
- For IDE compatibility (IntelliJ/PyCharm), create a symlink to the venv:
  ```nix
  enterShell = ''
    if [ ! -L "$DEVENV_ROOT/venv" ]; then
        ln -s "$DEVENV_STATE/venv/" "$DEVENV_ROOT/venv"
    fi
  '';
  ```
- Prefer `languages.python.venv.enable` or `uv.sync.enable` over direnv `layout python3`

### Node.js

```nix
# devenv.nix
{ pkgs, ... }:
{
  languages.javascript = {
    enable = true;
    npm.install.enable = true;  # auto-run npm install on shell entry
  };
}
```

Test: `devenv shell -- node --version && devenv shell -- npm --version`

Notes:
- Combine with direnv `layout node` to add `node_modules/.bin` to PATH
- For Yarn or pnpm, add them to `packages`: `packages = [ pkgs.yarn ];`

### Bun

```nix
# devenv.nix
{ pkgs, ... }:
{
  packages = [ pkgs.bun ];
}
```

Test: `devenv shell -- bun --version`

Notes:
- Bun does not have a dedicated `languages.bun` module yet — use `packages` directly
- Use `mcp__devenv__search_packages` to check for the latest bun package name
- For projects using both Node and Bun, enable `languages.javascript` and add bun to packages

### Scala CLI

```nix
# devenv.nix
{ pkgs, ... }:
{
  languages.scala = {
    enable = true;
  };
  packages = [ pkgs.scala-cli ];
}
```

Test: `devenv shell -- scala-cli --version && devenv shell -- scala --version`

Notes:
- `languages.scala.enable` provides JDK + Scala compiler
- Add `scala-cli` separately via packages (not part of the language module)
- Use `mcp__devenv__search_options` with query `languages.scala` to discover all options

### Java with Gradle

```nix
# devenv.nix
{ pkgs, ... }:
{
  languages.java = {
    enable = true;
    jdk.package = pkgs.jdk21;
    gradle.enable = true;
  };
}
```

Test: `devenv shell -- java --version && devenv shell -- gradle --version`

Notes:
- `gradle.enable` provides the Gradle wrapper; uses the project's `gradle-wrapper.properties` if present
- For Maven instead: `languages.java.maven.enable = true;`
- Specify JDK version explicitly via `jdk.package` (defaults to pkgs.jdk)

## Agent-friendly tasks

After setting up a language, add tasks for common operations so the user can allowlist
`Bash(devenv tasks run agent:*)`:

```nix
{
  # Python/uv
  tasks."agent:test"  = { exec = "uv run pytest"; };
  tasks."agent:lint"  = { exec = "uv run ruff check ."; };
  tasks."agent:fmt"   = { exec = "uv run ruff format ."; };

  # Node
  tasks."agent:test"  = { exec = "npm test"; };
  tasks."agent:lint"  = { exec = "npm run lint"; };
  tasks."agent:build" = { exec = "npm run build"; };

  # Java/Gradle
  tasks."agent:test"  = { exec = "gradle test"; };
  tasks."agent:build" = { exec = "gradle build -x test"; };
}
```

## Direnv setup (optional)

Create `.envrc`:

```bash
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
```

Add layouts for language-specific local binaries:

```bash
# .envrc — Node project
eval "$(devenv direnvrc)"
use devenv
layout node
```

Then: `direnv allow .`

## Git repo integration

After setup is working:
- Add `devenv.nix`, `devenv.yaml`, `devenv.lock`, `.envrc` to git
- Ignore `.devenv/` and `.direnv/`: ask the user whether to use `.gitignore` or `.git/info/exclude`
