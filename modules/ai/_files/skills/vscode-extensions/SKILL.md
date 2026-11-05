---
name: vscode-extensions
description: >-
  Install VS Code extensions for ONE repository, with a supply-chain cooldown, into a
  separate VS Code profile — never into the default profile. Reads the repo's
  .vscode/extensions.json (or explicit ids), shows what is already provided by Nix,
  resolves extension packs and dependencies so nothing arrives uncooled, and installs
  through `+vscode-ext`. Use when the user wants editor support for a repo, asks which
  VS Code extensions to recommend for a project, wants to open a repo with the right
  extensions, or wants to try an extension once. Triggers on: VS Code extension, vscode
  plugin, recommend extensions, extensions.json, install extension for this repo,
  profile, one-off extension, supply chain extension.
allowed-tools: Bash(+vscode-ext *) Read
dependencies: "+vscode-ext (installed by modules/vscode.nix); network access to the VS Code Marketplace"
---

# VS Code extensions per repository, with a cooldown

The default profile holds only what Nix pins (`modules/vscode.nix`). Everything with a
toolchain behind it belongs to a repository, so it goes into a **profile**, installed by
`+vscode-ext` — which enforces the cooldown itself.

## Hard rules

1. **Never run `code --install-extension`.** It honours one version; whatever the
   extension pulls in (pack members, `extensionDependencies`) arrives in the newest
   version, cooldown or not. Measured: installing `ms-python.python` brought a
   one-day-old, unreviewed `ms-python.vscode-python-envs` along. `+vscode-ext` resolves the
   whole closure and installs each member pinned and checksummed.
2. **Never pass a version or a number of days.** The cooldown is read by the script from
   `scripts/supply-chain.toml`. If an extension is blocked, report it; do not look for
   another way in.
3. **Never touch the `default` profile**, and never install into a Nix-managed stack
   profile (`java`, `python`, `web`, `slidev`, `nix`). The script refuses both.
4. **Do not install what `references/recommended.md` rejects.** Tell the user why instead.
5. **Always ask which route (below), every time.** A choice made once does not carry over.

## Procedure

1. **Identify.** Look at the repo's marker files (`build.gradle*`, `pom.xml`,
   `pyproject.toml`, `package.json`, `*.nix`, `*.vue`, …) and read
   `.vscode/extensions.json` if there is one. Then:

   ```bash
   +vscode-ext scan --from-repo <repo>            # or: +vscode-ext scan <id> <id> …
   ```

   `scan` changes nothing. Per entry it says `INSTALL` (with the cooled version, its age,
   whether the publisher is verified, installs, and every pack member or dependency that
   would be pulled in), `SKIP` (provided by Nix, or already installed) or `BLOCKED`
   (inside the cooldown, or withdrawn upstream).
2. **Assess.** Compare every `INSTALL` entry with `references/recommended.md`
   (recommend / caution / reject, with the reason). Entries the file does not know:
   apply `references/risk-checks.md`. Report `caution` and `reject` verdicts to the user
   with their reason, quoted from the file.
3. **Ask** (AskUserQuestion), with this guidance:

   | Route | Choose it when |
   |---|---|
   | **Nix stack profile** (`java`, `python`, `web`, `slidev`, `nix`) | The repo is worked on for good and its stack has a profile. Strongest: hash-pinned by Nix, not installed at runtime. Open with `code --profile <stack> <repo>`. If something the repo needs is missing from the profile, say so — it is a candidate for the profile in `modules/vscode.nix`, not for a runtime install. |
   | **`oneoff`** (default) | One-off: a workshop, a demo, a quick look, trying an extension. Disposable: `+vscode-ext prune --profile oneoff` empties it. |
   | **Own profile** | A long-lived repo with needs no stack profile covers. Needs VS Code **closed** once: `+vscode-ext profile create <name>`; VS Code rewrites the file that registers profiles when it exits. |
4. **Install.**

   ```bash
   +vscode-ext install --profile oneoff --from-repo <repo>
   +vscode-ext install --profile oneoff <id> <id>
   ```

   The summary reads `N ok, N skip, N error, N cleanup, N left`. Exit 0 = done or nothing
   to do; 1 = at least one extension failed or was blocked; 2 = environment problem
   (e.g. the profile does not exist); 75 = another run holds the lock.
5. **Report** the counts verbatim, name every blocked or failed extension with its reason
   (a blocked one stays out until it clears the cooldown — do not retry in a loop), then
   offer `+vscode-ext open --profile <P> <repo>`. A window that already uses the profile
   needs *Developer: Reload Window*.

## Other commands

```bash
+vscode-ext list   --profile oneoff     # [nix] = pinned by Nix, [installed] = runtime
+vscode-ext prune  --profile oneoff     # removes runtime installs, keeps the Nix entries
+vscode-ext status                      # is an install running? (pid, elapsed)
```

An interrupted run is safe to repeat: finished extensions are skipped, a half-unpacked one
never gets its final name.

## Recording what was installed

If the user wants the repo to remember it, offer to add the ids to the repo's
`.vscode/extensions.json` `recommendations`, and rejected ones to
`unwantedRecommendations` with a comment saying why. The file has no versions, so the
cooldown still applies at install time. Do **not** write internal repo names, ticket
numbers or hostnames into a repository that may be public.
