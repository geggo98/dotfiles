# Repository Guidelines

Nix-darwin configuration for Stefan Schwetschke's Macs (Nix flakes, flake-parts, nix-darwin,
Home Manager, Determinate Nix), organised by the **Dendritic Pattern** (`/dendritic-nix` skill).
`CLAUDE.md` is a symlink to this file.

**This file is the core, not the manual.** Codex truncates it silently past 32 KiB, and
`just check` fails above 16 KiB (`modules/agents-md-check.nix`). Details live in `docs/`. Find
the area in the index at the end and read that file *before* touching it. Claude loads many of
them automatically through `.claude/rules/`; Codex does so for `infra/`, `hosts/`, `scripts/`
and `modules/ai/`. For every other agent the index is the only trigger.

## Hosts

- `FCX19GT9XR` — personal Mac (user `stefan`).
- `DKL6GDJ7X1` — work Mac (user `stefan.schwetschke`): CHECK24 credentials, the only host with
  `my.ai.atlassian.enable`.
- `p-ion-berlin-xs56r6` — IONOS VPS, `x86_64-linux` NixOS. **Not applied with `just switch`.**
  See `docs/ionos-vps.md`.

## Hard rules

1. **Never run** `just switch`, `just switch-host`, `just daemon-restart`, `just nixos-deploy`,
   `just cache-prune … apply`, `just linux-builder-destroy`, or any `sudo` command. Print the
   command for the user. Apply the configuration only through `just switch`, never a bare
   `darwin-rebuild switch --flake .` (hostname drift breaks attribute selection).
2. **Stage new files before building:** `git add -N <paths>`. Flakes ignore untracked files
   silently. A build that "ignores" a change usually means an untracked file.
3. **Update inputs with `just update`, never `nix flake update`** (supply-chain cooldown).
4. **SOPS does not work in the agent sandbox.** Ask the user to edit secrets. Credentials
   never go into a config or a commit; use sops-nix files.
5. **Push only after `git push --dry-run` and explicit approval.** Never push tags or `--all`.
6. **`git diff` here runs difftastic and textconv.** For anything automated use
   `git diff --no-ext-diff --no-textconv --no-color`; otherwise a plus-line filter finds
   nothing, and SOPS files show decrypted plaintext.
7. **This repository is public.** See the next section.
8. **Lists and long jobs must be resumable:** classify each item as SUCCESS, SKIP, ERROR or
   CLEANUP, derive state from the work products, publish atomically. See `docs/scripting.md`.
   General form (progress with ETA, abort, `flock`, `--status`): global rule
   `long-running-scripts.md`. Wrap noisy commands in `+errlog -- <cmd>` (rule `errlog.md`).

## Public repository: what needs explicit clearance

`github.com/geggo98/dotfiles` is public and carries work configuration. Two kinds of content
need the user's explicit go-ahead **every time**; a clearance never carries over:

1. **Personal data of third parties:** names, email addresses, account ids, handles of anyone
   but the owner.
2. **Internal infrastructure:** hostnames, repository and product names, Jira project keys,
   cloud project ids, real ticket numbers, runbook names, workflow configuration.

Re-question what is already in the tree; it is rarely cleared, usually unseen. Identifiers
evade keyword search, so search for shapes: id-like strings, ticket patterns such as
`ABC-1234`, PR numbers, repo slugs, email addresses. Replace **all** real values on a pasted
example line with placeholders, not just the conspicuous ones. Before trusting "no hits", count
how many lines the filter saw. When in doubt, ask. Full rule: the global `third-party-data.md`.

## Everyday commands (all via `just`, no approval needed)

| Command | Purpose |
|---|---|
| `just build` / `just build-host <host>` | Build a host config without applying |
| `just eval` / `just fmt` / `just fmt-check` | Fast syntax check; format; format check |
| `just check` / `just ai-check` | `nix flake check` (includes the AGENTS.md budget); AI-aspect tests |
| `just diff` / `just verify-no-diff` | Package delta against the running system |
| `just update` / `just audit` | Cooldown-honouring input update; withdrawal audit |

Everything else (Linux builder, R2 cache, DevDocs, VS Code, credentials checks) and the
commands reserved for the user: `docs/commands.md`.

## Architecture in brief

- `flake.nix` uses `flake-parts.lib.mkFlake` and `import-tree ./modules`. Every file in
  `modules/` is a flake-parts module for one feature and exports `flake.modules.<class>.<name>`
  (`darwin`, `homeManager`, `nixos`).
- Hosts compose aspects in `modules/hosts/<serial>.nix`; host secrets declarations live in
  `hosts/<serial>/secrets.nix`.
- Share values through `let` bindings and `config.flake.modules`, **never** `specialArgs`.
- Determinate Nix manages Nix (`nix.enable = false`).
- launchd jobs inherit no shell environment, and SIP blocks `launchd.envVariables`.
  Read `docs/launchd.md` before adding a scheduled job.
- Style: 2-space indent, alphabetised attribute sets, `just fmt` before committing.
- Scripts: perl one-liners over sed/awk, zsh over bash, Python with a PEP-723 header beyond
  trivial size. `pkgs.writeShellApplication` stays bash. Details: `docs/scripting.md`.
- Macs are named by hardware serial; everything else follows `infra/Naming.md`.

Module list, host composition and how to add a module or host: `docs/architecture.md`.

## Commits and pull requests

Conventional Commits: `type(scope): subject`, imperative, ≤72 characters. Types: `feat`, `fix`,
`docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. Common scopes:
`home`, `homebrew`, `darwin`, `flake`, `secrets`, `macos`, `env`, `project`, `docs`. Run
`just fmt` first. Put host ids and the commands you ran in the body when relevant. Iterate
with `fixup!` commits.

Use the generic trailer `Co-Authored-By: Claude <noreply@anthropic.com>`. Never embed a model
name, version or context label: a content guardrail may reject it as impersonation, and it does
so non-deterministically.

## Index: read before touching …

Claude loads the files marked **auto** when it reads a matching path.

| Area | File | Auto paths (abridged) |
|---|---|---|
| `just` recipes, applying the config, new files | `docs/commands.md` | `justfile` |
| Module list, hosts, adding modules/hosts | `docs/architecture.md` | `flake.nix`, `modules/hosts/**` |
| `infra/`: naming, Pulumi, advisories | `docs/infra.md` | `infra/**` |
| DNS names, rebind exceptions | `docs/dns-realms.md` | `infra/**` |
| NixOS hosts, VPS, Tailscale, WireGuard | `docs/ionos-vps.md` | `modules/nixos-*.nix` |
| Docker Linux builder, cross-arch builds | `docs/linux-builder.md` | `modules/linux-builder.nix` |
| R2 binary cache, push/prune scripts | `docs/nix-cache.md` | `modules/nix-cache.nix` |
| `auto-optimise-store`, garbage collection | `docs/nix-store.md` | `modules/nix-gc.nix` |
| launchd agents and daemons | `docs/launchd.md` | `modules/boundary.nix`, `modules/nix-*.nix` |
| Shell/Python scripts, resumable jobs, uv scripts | `docs/scripting.md` | `scripts/**` |
| Secrets, SOPS, Vault, Atlassian tokens | `docs/secrets.md` | `**/*.enc.yaml`, `**/secrets.nix` |
| MCP servers, agent/AI aspects | `docs/ai-tooling.md` | `modules/ai/**`, `modules/mcp-*.nix` |
| DevDocs offline index | `docs/devdocs.md` | `modules/devdocs.nix` |
| VS Code, extensions, profiles, `+vscode-ext` | `docs/vscode.md` | `modules/vscode.nix` |
| iTerm2 `Web` profile, DuckDuckGo | `docs/iterm2-duckduckgo.md` | `modules/misc.nix` |
| `just update`, `just audit`, advisories | `docs/supply-chain.md` | `scripts/supply-chain.*` |
