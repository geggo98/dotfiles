---
name: nix-shell
description: "Search Nix packages and run commands with packages from nixpkgs that are not installed locally. Use when you need a package not available locally or want to search nixpkgs."
argument-hint: "search <term> | locate <pattern> | run <packages...> -- <command> [args...] | versions <pkg> [<version>]"
allowed-tools: Bash(./scripts/nix_shell.sh *) Bash(zsh *)
dependencies: "nix"
---

# Nix Shell Skill

## Usage

Run the script:

```bash
zsh ${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh $ARGUMENTS
```

## 1. Purpose

Use this skill to search for Nix packages and run commands using tools that are not installed locally.
It wraps `nix search`, `nix-locate`, and `nix shell` to give the agent on-demand access to any package in nixpkgs,
and queries nixhub's version history to run or pin a **specific version** of a package.

## 2. Usage Scenarios

Run when:

- A command or tool is needed but not installed locally.
- You need to find which Nix package provides a specific binary.
- You need to run a one-off command with a tool from nixpkgs.
- You need multiple tools available together for a pipeline.
- You need a specific (usually older) version of a package, and want to know the nixpkgs commit that ships it and whether the binary cache still has it.

## 3. Helper Scripts

| Script                    | Purpose                                               | Arguments                                              |
| ------------------------- | ----------------------------------------------------- | ------------------------------------------------------ |
| `${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh`   | Search/locate packages, run commands in nix shell, look up versions | `search <term>`, `locate <pattern>`, `run <pkgs> -- <cmd>`, or `versions <pkg> [<version>]` |

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
- **`name@version`** (devbox syntax, e.g. `duckdb@1.5.3`) is resolved through nixhub's API to `github:NixOS/nixpkgs/<rev>#<attr>` — the commit that ships exactly that version — and the log line says whether cache.nixos.org has the build. `@latest` and a prefix such as `@1.5` work too.
- **`--` separator** is required between packages and the command.
- The process is replaced via `exec`, so the exit code comes directly from the executed command.

### `versions <pkg> [<version>] [--system SYS] [--limit N] [--json]`

Version history of a nixpkgs attribute from nixhub.io (backend: `https://search.devbox.sh/v2`, the API the devbox CLI uses).

- **Without a version:** one row per release, newest first (`--limit`, default 10): version, date, the nixpkgs commit nixhub recorded for `SYS`, and whether cache.nixos.org still serves that build (`yes` / `no` / `not built`).
- **With a version:** the flake ref `github:NixOS/nixpkgs/<rev>#<attr>`, the store path it yields on `SYS`, the cache status, and copy-paste lines for `nix shell`, a `flake.nix` input and a `devenv.yaml` input. `latest` and a prefix (`1.5`) resolve to the newest match.
- **`--system`** defaults to this machine (`builtins.currentSystem`). nixhub records a different commit per system; the newest one carries the version for every system, but the cache check is per system — run it for each target.
- **`--json`:** the raw API response.
- The cache check is one `HEAD` on the narinfo; no nixpkgs is evaluated or downloaded.

## 5. Examples

### Search for a package

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh search envsubst
```

### Search with JSON output

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh search envsubst --json
```

### Locate which package provides a binary

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh locate gtimeout
```

### Locate with exact basename match and limited results

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh locate gtimeout -w -n 10
```

### Locate regular files instead of executables

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh locate nginx.conf -t r
```

### Run a command with a single package

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh run envsubst -- envsubst --help
```

### Run with multiple packages

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh run envsubst jq -- sh -c 'echo "{}" | jq . && which envsubst'
```

### Use a full flake reference

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh run github:NixOS/nixpkgs#hello -- hello
```

### Run a specific version

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh run duckdb@1.5.3 -- duckdb --version
```

### Which nixpkgs commit ships a version, and is it cached?

```bash
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh versions duckdb              # history
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh versions duckdb 1.5.3        # one version, this machine
${CLAUDE_SKILL_DIR}/scripts/nix_shell.sh versions duckdb 1.5.3 --system x86_64-linux
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

### Versions (one version)

```
duckdb 1.5.3 for aarch64-darwin
  flake ref   : github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac#duckdb
  store path  : /nix/store/96682ys3320p24jm96k2hwl4dfjgy7jf-duckdb-1.5.3
  cached      : yes (https://cache.nixos.org)

  nix shell   : nix shell github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac#duckdb
  flake.nix   : inputs.nixpkgs-duckdb.url = "github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac";
  devenv.yaml : inputs: { nixpkgs-duckdb: { url: github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac } }
```

`cached: no` means nix would compile it. Pin a different commit, or accept the build.

### Versions (history)

```
version  date        commit (aarch64-darwin)  cached
1.5.5    2026-08-28  c27cdad491               yes
1.5.4    2026-08-11  8e2eeb9477               yes
1.5.3    2026-07-15  35d3407a38               yes
```

The commit is the last one at which nixhub saw that version, not the one that bumped it.

## 7. Exit Codes

| Code | Meaning                                             |
| ---- | --------------------------------------------------- |
| 0    | Success                                             |
| 1    | Invalid arguments / usage error                     |
| 2    | Missing prerequisite (`nix` not found)              |
| 3    | Nix command or version API failed (package/version not found, never built for the system, HTTP 429, network) |
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
| Wrong or too-new version      | `nixpkgs#pkg` is whatever the registry pins | `versions <pkg>` for the history, then `run pkg@<version>` |
| `cached: no` / `not built`    | Hydra never built it for that system, or the version is too old | Pick a neighbouring version with `cached: yes`, or accept a local build |
| `Rate limited by …` (HTTP 429)| 1000 requests per IP, refilled at 5/min | Wait a few minutes; use `--limit` to keep the history short |
| `missing '--' separator`      | Forgot `--` between pkgs and cmd   | Add `--` before the command                |
