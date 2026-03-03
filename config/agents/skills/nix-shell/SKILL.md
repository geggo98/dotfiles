---
name: nix-shell
description: Search Nix packages and run commands with packages from nixpkgs that are not installed locally
argument-hint: "search <term> | locate <pattern> | run <packages...> -- <command> [args...]"
allowed-tools:
  - "Bash(./scripts/nix_shell.sh)"
  - "Bash(bash ./scripts/nix_shell.sh)"
---

# Nix Shell Skill

## 1. Purpose

Use this skill to search for Nix packages and run commands using tools that are not installed locally.
It wraps `nix search`, `nix-locate`, and `nix shell` to give the agent on-demand access to any package in nixpkgs.

## 2. Usage Scenarios

Run when:

- A command or tool is needed but not installed locally.
- You need to find which Nix package provides a specific binary.
- You need to run a one-off command with a tool from nixpkgs.
- You need multiple tools available together for a pipeline.

## 3. Helper Scripts

| Script                    | Purpose                                               | Arguments                                              |
| ------------------------- | ----------------------------------------------------- | ------------------------------------------------------ |
| `scripts/nix_shell.sh`   | Search/locate packages or run commands in nix shell    | `search <term>`, `locate <pattern>`, or `run <pkgs> -- <cmd>` |

## 4. Subcommands

### `search <term> [--json] [--timeout DURATION]`

Search nixpkgs for packages matching `<term>`.

- **Default output:** Clean table with package name, version, and description.
- **`--json`:** Raw JSON output from `nix search`.
- **`--timeout DURATION`:** Override the search timeout (default: `5m`). Format follows GNU coreutils (e.g. `30s`, `5m`, `1h`).
- If no packages match, prints a message and exits 0.

### `locate <pattern> [-t TYPE] [-n LIMIT] [--timeout SECS] [-w]`

Find which Nix package provides a specific file or binary. Uses `nix-locate` with `--minimal` output.

- **Default type:** `x` (executable). Other types: `r` (regular file), `d` (directory), `s` (symlink).
- **Default limit:** 100 results (use `-n` to change).
- **Default timeout:** 60 seconds (use `--timeout` to change).
- **`-w` / `--whole-name`:** Only match files whose basename matches the pattern exactly.
- Output is one attribute name per line (e.g. `coreutils-prefixed.out`).

### `run <packages...> -- <command> [args...]`

Run a command with specified Nix packages available on PATH.

- **Packages:** Bare names are auto-prefixed with `nixpkgs#` (e.g. `envsubst` becomes `nixpkgs#envsubst`). Full flake references (containing `#` or `:`) pass through unchanged.
- **`--` separator** is required between packages and the command.
- The process is replaced via `exec`, so the exit code comes directly from the executed command.

## 5. Examples

### Search for a package

```bash
scripts/nix_shell.sh search envsubst
```

### Search with JSON output

```bash
scripts/nix_shell.sh search envsubst --json
```

### Locate which package provides a binary

```bash
scripts/nix_shell.sh locate gtimeout
```

### Locate with exact basename match and limited results

```bash
scripts/nix_shell.sh locate gtimeout -w -n 10
```

### Locate regular files instead of executables

```bash
scripts/nix_shell.sh locate nginx.conf -t r
```

### Run a command with a single package

```bash
scripts/nix_shell.sh run envsubst -- envsubst --help
```

### Run with multiple packages

```bash
scripts/nix_shell.sh run envsubst jq -- sh -c 'echo "{}" | jq . && which envsubst'
```

### Use a full flake reference

```bash
scripts/nix_shell.sh run github:NixOS/nixpkgs#hello -- hello
```

## 6. Output Format

### Search (default table)

```
envsubst            1.4.3     Substitute environment variables in a string
```

### Search (--json)

```json
{
  "legacyPackages.aarch64-darwin.envsubst": {
    "pname": "envsubst",
    "version": "1.4.3",
    "description": "Substitute environment variables in a string"
  }
}
```

### Locate

One attribute name per line (minimal output):

```
coreutils-prefixed.out
```

### Run

Outputs whatever the executed command produces (stdout and stderr pass through).

## 7. Exit Codes

| Code | Meaning                                             |
| ---- | --------------------------------------------------- |
| 0    | Success                                             |
| 1    | Invalid arguments / usage error                     |
| 2    | Missing prerequisite (`nix` not found)              |
| 3    | Nix command failed (package not found, network, etc)|
| *    | For `run`: exit code from the executed command       |

## 8. Environment Variables

| Variable | Description                                |
| -------- | ------------------------------------------ |
| `NIX`    | Path to `nix` binary (default: `nix`)      |

## 9. Troubleshooting

| Problem                       | Possible Cause                     | Fix                                        |
| ----------------------------- | ---------------------------------- | ------------------------------------------ |
| `nix: command not found`      | Nix not installed                  | Install Nix or Determinate Nix             |
| `nix-locate not found`        | nix-index not installed            | Install nix-index package                  |
| Slow first run                | Nixpkgs flake being evaluated      | Normal on first use; cached afterward      |
| Package not found             | Wrong package name                 | Use `search` to find the correct name      |
| `locate` timed out            | Pattern too broad, many results    | Use `-w` for exact match or `--timeout`    |
| `missing '--' separator`      | Forgot `--` between pkgs and cmd   | Add `--` before the command                |
