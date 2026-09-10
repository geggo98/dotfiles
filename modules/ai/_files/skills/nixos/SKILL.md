---
name: nixos
description: Query nixpkgs packages, NixOS / Home Manager / nix-darwin / Nixvim / NVF options, flakes, FlakeHub, NixHub version history, the binary cache and /nix/store paths. Use whenever a Nix package name, attribute path, option, channel (unstable, 25.11, 26.05), flake input or /nix/store path comes up — including "which version of X is in nixpkgs", "which commit shipped X", "what is the home-manager option for X", "is X cached". Prefer this over `nix search`, over scraping search.nixos.org, and over `gh api` against NixOS/nixpkgs.
allowed-tools: Bash(+nix-query *) Bash(zsh *) Read
dependencies: "+nix-query (installed by modules/mcp-servers.nix)"
---

# NixOS / nixpkgs queries

Your training data lags nixpkgs by months. Use this for anything touching
nixpkgs, channels, flakes, NixOS / home-manager / darwin options, the binary
cache or store paths — **even when you think you know the answer**.

```bash
+nix-query search ripgrep                      # packages matching a keyword
+nix-query info ripgrep --type package         # details for an exact name
+nix-query versions duckdb                     # which commit shipped which version
```

This used to be an MCP server. It is a CLI now because the queries are
stateless HTTP lookups: as a server it held a resident process in every agent
session (measured 15.2 MiB × 9 sessions) and computed nothing between calls.
The CLI calls the *same* upstream code, so answers are identical.

## Commands

`+nix-query <action> [query] [--source …] [--type …] [--channel …] [--limit N]`

| Intent | Command |
|---|---|
| search for a package | `+nix-query search X` |
| is package X in channel Y? | `+nix-query info X --channel Y` |
| search NixOS options | `+nix-query search X --type options` |
| option details | `+nix-query info X --type option` |
| what programs does a package provide? | `+nix-query search X --type programs` |
| home-manager option | `+nix-query search X --source home-manager` |
| nix-darwin option | `+nix-query search X --source darwin` |
| Nixvim / NVF option | `+nix-query search X --source nixvim` / `--source nvf` |
| walk an option tree by prefix | `+nix-query browse programs.git --source home-manager` |
| which channels exist? | `+nix-query channels` |
| package/option counts | `+nix-query stats` |
| is it in the binary cache? | `+nix-query cache X [--system x86_64-linux]` |
| a flake's inputs | `+nix-query flake-inputs [name] [--source PATH]` |
| read a store path | `+nix-query store /nix/store/… --type read` |
| version history | `+nix-query versions X [--pkg-version 1.5.3]` |

`--source` takes: `nixos` (default), `home-manager`, `darwin`, `flakes`,
`flakehub`, `nixvim`, `nvf`, `wiki`, `nix-dev`, `noogle`, `nixhub`.

`--type` means different things per action: for `search --source nixos` it is
`packages|options|programs|flakes`; for `info` it is `package|option`; for
`flake-inputs` and `store` it is `list|ls|read`.

## Notes

- **`--pkg-version`, not `--version`.** `--version` would collide with argparse's
  own flag, so the package version is spelled `--pkg-version` on `cache` and
  `versions`.
- **Pinning a package to an exact version** is `versions` plus an overlay — the
  `devenv` skill's `references/pinning.md` has the worked recipe.
- Every action goes over the network. There is no local index, so results follow
  whatever search.nixos.org and NixHub currently serve.
- `channels` distinguishes the *indexed* commit from the branch HEAD. For the
  question "will this build from cache", the indexed commit is the one that
  matters.
