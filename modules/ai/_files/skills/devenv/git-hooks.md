# Git Hooks in Devenv

Documentation:
- Git hooks guide: https://devenv.sh/git-hooks/
- Available hooks list: https://devenv.sh/reference/options/#git-hooks
- Underlying library: https://github.com/cachix/git-hooks.nix

## Overview

Devenv integrates git-hooks.nix (formerly pre-commit-hooks.nix) for declarative
linting and formatting at commit time. Hooks are installed automatically when
entering `devenv shell`. Since 2025, the default runner is `prek` (Rust reimplementation)
instead of Python's `pre-commit`.

## Basic setup

```nix
{
  git-hooks.hooks = {
    # Formatters
    nixpkgs-fmt.enable = true;       # Nix formatting
    prettier.enable = true;          # JS/TS/CSS/HTML/JSON/YAML
    black.enable = true;             # Python
    google-java-format.enable = true; # Java

    # Linters
    shellcheck.enable = true;        # Shell scripts
    eslint.enable = true;            # JavaScript/TypeScript
    clippy.enable = true;            # Rust

    # Other
    mdsh.enable = true;              # Execute code blocks in Markdown
    check-merge-conflicts.enable = true;
    trim-trailing-whitespace.enable = true;
  };
}
```

When you enter the shell, devenv outputs:
```
pre-commit installed at .git/hooks/pre-commit
```

Hooks then run automatically on `git commit` for matching files.

## Verifying in CI

```bash
devenv test
```

This runs all enabled hooks against the entire codebase, not just staged files.

## Package overrides

```nix
{
  git-hooks.hooks = {
    # Override the default package version
    ormolu.enable = true;
    ormolu.package = pkgs.haskellPackages.ormolu;

    # Some hooks have multiple packages
    clippy.enable = true;
    clippy.packageOverrides.cargo = pkgs.cargo;
    clippy.packageOverrides.clippy = pkgs.clippy;
    clippy.settings.allFeatures = true;
  };
}
```

## Custom hooks

Define project-specific hooks that don't exist in git-hooks.nix:

```nix
{
  git-hooks.hooks.unit-tests = {
    enable = true;
    name = "Unit tests";
    entry = "make check";
    files = "\\.(c|h)$";             # Regex pattern for matching files
    types = [ "text" "c" ];          # File type filter (alternative to files)
    excludes = [ "irrelevant\\.c" ]; # Exclusion patterns
    language = "system";             # How pre-commit installs the hook
    pass_filenames = false;          # Don't pass changed files to command
  };
}
```

### Custom hook fields

| Field | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | — | Enable/disable the hook |
| `name` | string | — | Display name in reports |
| `entry` | string | — | Command to execute (mandatory) |
| `files` | string | `""` (all) | Regex for matching files |
| `types` | list | `["file"]` | File type filter |
| `excludes` | list | `[]` | Exclusion patterns |
| `language` | string | `"system"` | Hook language (how to install) |
| `pass_filenames` | bool | `true` | Pass changed files as args |
| `stages` | list | `["pre-commit"]` | Git hook stages to run in |

## .pre-commit-config.yaml

This file is a symlink to an auto-generated file in the Nix store.
It does NOT need to be committed. `devenv init` adds it to `.gitignore`.

## Switching the runner package

Since 2025, devenv defaults to `prek` (Rust). To use the original Python `pre-commit`:

```nix
{
  git-hooks.package = pkgs.pre-commit;
}
```

## Integration with Claude Code (cross-reference)

When `git-hooks.enable` is true and `claude.code.enable` is true, devenv
automatically configures a Claude Code PostToolUse hook that runs git-hooks
after every file edit (Edit/MultiEdit/Write). This means:

1. Claude Code edits a file
2. The PostToolUse hook fires
3. Git-hooks run on the edited file (formatting, linting)
4. The file is auto-formatted before Claude continues

This is the default behavior — no extra configuration needed.

For details on the Claude Code hook mechanism: see `references/claude-code.md`
(section "Automatic formatting").

### Explicit configuration (shown for clarity)

```nix
{
  git-hooks.hooks = {
    nixpkgs-fmt.enable = true;
    prettier.enable = true;
  };

  claude.code.enable = true;
  # The following is auto-generated when both git-hooks and claude.code are enabled:
  # claude.code.hooks.postEdit = {
  #   enable = config.git-hooks.enable;
  #   hookType = "PostToolUse";
  #   matcher = "^(Edit|MultiEdit|Write)$";
  #   command = "cd \"$DEVENV_ROOT\" && prek run";
  # };
}
```

### Why this matters for agents

Without this integration, an AI agent would write unformatted code that fails
lint checks on commit. With it, every file the agent touches is immediately
auto-formatted by the project's declared hooks. The agent's output conforms
to project style without explicit prompting.

For agents that commit directly (e.g., in CI or automated workflows), this
also prevents lint failures in the commit hook — the code is already clean.

## Common hook combinations by language

### Java / Spring Boot
```nix
{
  git-hooks.hooks = {
    google-java-format.enable = true;
    check-merge-conflicts.enable = true;
    trim-trailing-whitespace.enable = true;
    nixpkgs-fmt.enable = true;  # For devenv.nix itself
  };
}
```

### JavaScript / TypeScript
```nix
{
  git-hooks.hooks = {
    prettier.enable = true;
    eslint.enable = true;
    check-merge-conflicts.enable = true;
  };
}
```

### Python
```nix
{
  git-hooks.hooks = {
    black.enable = true;
    ruff.enable = true;          # Fast Python linter
    mypy.enable = true;          # Type checking
    check-merge-conflicts.enable = true;
  };
}
```

### Rust
```nix
{
  git-hooks.hooks = {
    rustfmt.enable = true;
    clippy.enable = true;
    clippy.settings.allFeatures = true;
  };
}
```

### Nix
```nix
{
  git-hooks.hooks = {
    nixpkgs-fmt.enable = true;   # Or: alejandra.enable = true;
    deadnix.enable = true;       # Find unused Nix code
    statix.enable = true;        # Nix anti-pattern linter
  };
}
```

### Multi-language project
```nix
{
  git-hooks.hooks = {
    # Universal
    check-merge-conflicts.enable = true;
    trim-trailing-whitespace.enable = true;
    end-of-file-fixer.enable = true;
    check-added-large-files.enable = true;

    # Per-language
    google-java-format.enable = true;
    prettier.enable = true;
    nixpkgs-fmt.enable = true;
    shellcheck.enable = true;
  };
}
```
