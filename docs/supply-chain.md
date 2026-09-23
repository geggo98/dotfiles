# Updating flake inputs, the cooldown audit, and closing dependency advisories

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

### Updating flake inputs

**Use `just update`, not `nix flake update`.** They are not the same command any more.
`nix flake update` always jumps every input to the CURRENT head of its branch, which is
precisely the window a supply-chain attack lives in. `just update` runs
`scripts/supply-chain.py`, which resolves each input to the newest revision that is at
least N days old and writes those revisions into `flake.lock`.

**Policy lives in `scripts/supply-chain.toml`, not in the recipes or the code** — the
cooldowns, the per-input overrides and the freeze list, each with the measurement that
justifies it. The same file drives `just audit`, so the check and the thing being
checked cannot drift apart. Defaults: 5 days for flake inputs, 14 for npm packages and
VS Code extensions, matching `modules/supply-chain-hardening.nix`.

Measured on 2026-08-22, and the reason this exists: a plain `nix flake update` in this
repo moved six inputs to a HEAD committed the same day — worktrunk 0.1 days old,
home-manager 0.2, llm-agents 0.3, devenv 0.5, determinate 0.6, nix-homebrew 0.8 — while
the ChainDrop/Shai-Hulud npm campaign was live and still classified active by CSA
advisory AD-2026-009. Nothing in the repo said a word about it.

**Why a cooldown rather than a scanner.** The poisoned ChainDrop tarballs carried valid
npm provenance and SLSA L3 attestations, signed by GitHub Actions through Sigstore: every
cryptographic check passed, because the source was trojanized before the build ran. A
vulnerability scanner answers "clean" for exactly as long as it matters. Age is the one
signal an attacker cannot forge — malicious releases are typically pulled within hours to
days, so declining to be the first consumer turns most of these incidents into a
non-event. This is the same reasoning `modules/supply-chain-hardening.nix` already
applies to npm/pnpm/bun/uv, moved one level up to the flake inputs.

Four behaviours worth knowing, each of which cost a measurement:

- **The cooldown lives in `flake.lock`, not `flake.nix`.** `nix flake lock
  --override-input <name> github:<o>/<r>/<rev>` writes the explicit rev while leaving
  `original` as plain branch-tracking. The consequence: **a bare `nix flake update`
  silently discards the cooldown.** `just update` is the only update path that honours
  it, exactly as `just switch` is the only supported apply path.
- **nixpkgs channel branches are exempt, automatically, and must stay that way.**
  `nixos-26.05` and `nixos-unstable` advance only to revisions Hydra has built and
  tested; their HEAD is the published channel. The commits *between* two heads were never
  published as a channel, so they are neither Hydra-validated nor covered by
  cache.nixos.org. Cooling nixpkgs down trades "2 days old and fully cached" for "5 days
  old, never validated, rebuild the world". Verified:
  `channels.nixos.org/nixos-26.05/git-revision` returned exactly the branch head a plain
  update had locked, while a 5-day cooldown selected the intermediate commit `5c11f83f0`.
  The script detects this via channels.nixos.org and reports those inputs as `channel`.
- **A `ref` may be a branch or a tag, and guessing from the string does not work** —
  `6.0.17` and `release-26.05` are both plausible either way. Each `ref` is resolved
  against the GitHub branches endpoint: branch → cooldown applies, tag → immutable, `nix
  flake update` never moved it anyway.
- **"Immutable" says `just update` will not move it — not that it is soaked.** Skipping
  tag pins in layer 1 is right, but it leaves the bar to whatever moves them by hand, and
  for a long time nothing did: `just brew-bump` took `releases/latest`. Measured
  2026-09-01, that resolved to Homebrew 6.0.21 **twelve hours** after publication, in the
  repo whose entire update path exists to avoid being the first consumer of anything.
  The four tag pins therefore now split into two classes. `brew-src` and `devenv` are
  scripted and cooled: each recipe calls `supply-chain.py release <owner>/<repo>`, which
  picks the newest release clearing `[cooldown] inputs` and prints every candidate it
  declined and why — a silent skip would read as "not published yet". A tag passed as an
  argument still overrides the bar, and says so on stderr. `yt-dlp-src` and
  `agent-browser-src` are edited by hand and have **no** gate at all; check the release
  date yourself before bumping either.
- **`devenv` is pinned for a second reason, and it is not soak.** Its main branch carries
  a Cargo version with no release behind it, so branch-tracking deployed a version that
  exists nowhere upstream: measured 2026-09-03, `home-manager-path` pointed at
  `devenv-wrapped-2.2.3` while cachix/devenv's releases ended at v2.2.2 (2026-08-13) —
  no release notes to read, nothing to file a bug against. **A cooldown cannot fix that,
  because it selects an age, not a publication.** The same day `just update-preview`
  offered `ed3d140a9 → eeced8155`: another arbitrary main commit, merely an older one.
  Adopting the tag moved the input backwards by two weeks, deliberately and by hand.
- **FlakeHub inputs are covered too, and yanks are honoured.** `determinate` is a semver
  *range* (`…/determinate/3`), so it re-resolves on every lock — a floating range on the
  root `nix-daemon` would defeat every cooldown in the repo. It moved 3.21.8 → 3.22.2
  (0.7 days old) on that same update. The script reads FlakeHub's releases endpoint,
  which carries `published_at` **and `yanked_at`**, and pins `=<version>`. That yank
  filter earned its keep immediately: determinate 3.22.0 was old enough at 15 days but
  had been yanked on 2026-08-17, so the script correctly fell back to 3.21.9.

- **An update never moves an input BACKWARDS.** Raising a bar — say `nixpkgs-llm-agents`
  from 5 to 14 days — would otherwise roll the lock back to a revision that has already
  been built, cached and possibly deployed, to fix a problem that waiting fixes anyway.
  The regression is reported, not silent: *"5b3a7eff4 (5.2d) is NEWER than the 14d bar's
  pick df0664e9f (14.5d) — not rolled back; it clears the bar on its own in 8.8d."*
  `--allow-rollback` forces it, for the one case that wants it: a lock polluted by a
  bare `nix flake update`.

`just update-preview` shows the decision without writing anything, and re-running
`just update` when there is nothing to do exits 0 and says so. `just update-head` is the
deliberate bypass — if you use it, write down why in the commit body.

#### `just audit` — the other half, and a different question

`just pulumi-audit` asks *"is anything KNOWN-bad?"* against OSV. `just audit` asks *"is
anything suspiciously NEW, or has upstream WITHDRAWN it?"*. Do not let one be reported
as if it answered the other: on 2026-08-04 ChainDrop's poisoned tarballs carried valid
npm provenance and SLSA L3 attestations, and every scanner said clean.

The second half of that question is the one a cooldown alone misses. **A withdrawn
artifact is the strongest signal available**, because the ecosystem emits it *after*
someone found the problem — and age cannot express it, since a malicious version pulled
yesterday is still "old enough" tomorrow. So each layer checks presence as well as age:
FlakeHub `yanked_at`, npm `unpublished` or a version missing from the registry's `time`
map, and for a VS Code extension a 404, a `deprecated` flag, or a chosen version that
has vanished from `allVersions` while the extension itself survives. That is not
hypothetical — on its first real run it rejected determinate 3.22.0, comfortably old
enough at 15 days and yanked on 2026-08-17.

Layer 2 exists because **an input's age bounds its contents only from below, and
loosely.** Measured with `nixpkgs-llm-agents` at 5.2 days old, the npm packages inside
it were claude-code 7.9 d, opencode 9.6 d, gemini-cli 10.8 d, ccusage 7.1 d — every one
still inside the 14-day npm bar. Hence the per-input override raising that input to 14.

Each `[[packages]]` entry names the one place it is dated against: `npm = "<package>"`,
or `github = "<owner>/<repo>"` for a vendor binary that never touches a registry —
`antigravity-cli` is a tarball off Google Cloud Storage, and its GitHub release tagged
with the bare version is the only dated, listed record of what was published. A release
that vanishes reads as WITHDRAWN, like an npm version missing from the `time` map; an
entry naming neither — or both — is FAILED, never silently dated against whichever key
the code looks at first. **Mind what the date proves**:
for codex the npm entry is only a proxy — llm-agents builds it from the GitHub tag
`rust-v<version>`, npm never enters that chain.

Two traps in layer 3, both found by testing rather than reading docs:

- **Open VSX `allVersions` begins with ALIASES, not versions** — measured,
  `['latest', 'pre-release', '0.4.3022', …]`. Both resolve to a real manifest, so a
  naive walk "finds" one and pins the literal string `latest`: a floating pointer, i.e.
  exactly what this tool exists to prevent. Only keys starting with a digit are used.
- **The per-version walk is capped at 40 and says so.** Open VSX costs one request per
  version and some extensions ship nightlies (rust-analyzer lists 100). A bounded search
  that reports "no suitable version" without saying how far it looked is
  indistinguishable from a real absence.

`[[extensions]]` in the manifest is deliberately empty until the default-extension set
is actually wired into a module; `just audit-extensions <id>…` exercises the machinery
meanwhile.

The cooldown bounds the age of everything *inside* an input from below (a llm-agents.nix
rev from 14 days ago cannot pin an npm version published yesterday), but it is a soak,
not a verdict: it says nothing about whether that older code is malicious, and it cannot
help against an attack nobody notices for longer than the threshold.

**The date is attacker-settable, and that defines what the cooldown is for.** The
committer date this sorts by is chosen by whoever makes the commit — measured
2026-08-22, `GIT_COMMITTER_DATE=2019-01-01 git commit` yields an input this tool reports
as 2790 days old. So anyone who already controls the upstream repo walks through the
bar, and the same holds one level down: npm's `time` map and GitHub's `published_at` are
supplied by the party being audited. What the cooldown *does* defend against is the
common shape of these incidents — a compromised account publishes, the release is live
for hours, someone notices, it gets pulled — where simply not being an early consumer
takes you out of the blast radius. Do not present it as more than that.

**The largest uncovered surface is Homebrew, not Nix.** The generated Brewfile carries
83 casks and **zero version strings** (`cask "1password", trusted: true`); Homebrew 6
resolves them from a rolling JSON API at `just switch` time
(`~/Library/Caches/Homebrew/api/cask.jws.json`, ~20 MB), entirely outside `flake.lock`.
1Password, Firefox, Brave, Chrome and ChatGPT install whatever that API serves at
activation. No cooldown, pin or audit in this repo covers any of it.

- **nvf variants:** `modules/neovim.nix` exports `neovim` *and* `neovim-server`,
  built from a shared `common` plus a `workstation` overlay. When adding a
  plugin, decide which of the two it belongs in — anything with a language
  toolchain, a second editor, or a desktop assumption behind it goes in
  `workstation`. `common` must never gain anything of its own, or both hosts
  change at once. The header comment in that file gives the two commands that
  verify the workstation is unaffected (compare *content*, not the system
  `drvPath` — splitting the module shifts one entry in `home.packages` and moves
  the hash without changing what is installed).

- **nvf (Neovim):** Before bumping the `nvf` input (`modules/neovim.nix`), **check
  the nvf release notes** for breaking option renames/removals:
  <https://github.com/NotAShelf/nvf/tree/main/docs/manual/release-notes> (e.g.
  `rl-0.9.md`). nvf changes `vim.*` option paths between releases (language
  modules, `lsp.presets.*`, removed plugins), and these surface as eval errors.
  Cross-reference `programs.nvf.settings` in `modules/neovim.nix` against the
  notes before building.

- **Pulumi provider SDKs (`infra/package.json`):** pinned in **two** places, and npm is
  not the authority. Nix's `pulumi-bin` ships a fixed set of provider *plugins* in its
  `bin/` directory, and those are what actually talk to the cloud API — the npm
  `@pulumi/<provider>` package is only the typed client. Taking npm `latest` therefore
  desynchronises them and Pulumi warns: `resource plugin cloudflare is expected to have
  version >=6.19.0, but has 6.17.0`. Pin each provider SDK with `~` to the plugin
  version Nix provides, so patches are allowed but the minor cannot drift:

  ```bash
  # the authority — read the versions Nix actually ships, then match package.json
  for f in "$(dirname "$(readlink -f "$(command -v pulumi)")")"/pulumi-resource-*; do
    printf '%-34s %s\n' "$(basename "$f")" "$("$f" --version 2>/dev/null | head -1)"
  done
  ```

  To move a provider forward, bump `nixpkgs-unstable` (which carries `pulumi-bin`)
  first, re-read the plugin versions, then raise `infra/package.json` to match. Note
  `@pulumi/pulumi` itself is the core SDK, not a plugin, and is not part of this
  coupling.

- **agent-browser:** pinned in **two** places. Bump the `agent-browser-src` tag in
  `flake.nix` (that tag is also where the version comes from — it is read out of the
  input's `package.json`), then run `just agent-browser-hashes <version>` and paste the
  printed `assets` attrset into `modules/agent-browser.nix`, then `just build`. Do
  **not** switch back to `nixpkgs-llm-agents.agent-browser` or `nixpkgs.agent-browser`
  without re-checking the pnpm dashboard FOD: it resolves time-dependently (pnpm
  `minimumReleaseAge`) and drifts off its pinned hash on its own. The release binary
  carries no skill bodies, so `modules/agent-browser.nix` points
  `AGENT_BROWSER_SKILLS_DIR` at `$out/skill-data` copied from the same tag — keep those
  two in sync or `agent-browser skills get` breaks.

- **Gram editor — cask, deliberately not nixpkgs.** Gram (Zed fork, replaced the `zed`
  cask) comes from the `gram` homebrew cask. nixpkgs *does* ship a working
  aarch64-darwin `gram`, and it is cached — but its darwin build symlinks a full `git`
  into the app bundle, which drags `python3 → clang → llvm → apple-sdk` and yields a
  **1.8 GiB closure** for a ~130 MiB app. `gram.override { git = gitMinimal; }` would
  cut ~1.3 GiB of that, but changes the store path and so forces a source build of a
  Zed-sized Rust tree (hours). Re-check this trade-off before moving Gram to nixpkgs.
  The theme in `modules/_files/gram/turbo-vision.json` *is* Nix-managed
  (`modules/gram.nix`) — a port of the VS Code theme
  (`modules/_files/vscode/turbo-vision-color-theme.json`); Gram consumes Zed's
  `zed.dev/schema/themes/v0.2.0.json` format verbatim. Gram's `settings.jsonc` is
  intentionally left unmanaged — Gram writes UI settings back to it.


### Closing a dependency advisory in `infra/`

`infra/` is the only npm tree in this repo (Pulumi, pnpm 11). GitHub Dependabot
watches `infra/pnpm-lock.yaml`; `just pulumi-audit` asks the same question
independently against OSV and additionally flags anything published inside the
cooldown window. Its script (`infra/scripts/osv-audit.py`) is stdlib-only on
purpose — an auditing tool that installs dependencies to run has a supply chain of
its own. Exit codes: `0` clean, `1` advisories found, `2` tool/network error.

**Work the ladder top-down and stop at the first rung that applies.**

1. **The fixed version fits the parent's declared semver range → lockfile only.**
   `cd infra && pnpm update <pkg> --depth Infinity`. `package.json` and
   `pnpm-workspace.yaml` stay untouched; `git diff --stat infra/` must show
   `pnpm-lock.yaml` alone. Check the range against the registry *before* editing —
   `curl -fsSL https://registry.npmjs.org/<parent>/<version>` and read
   `.dependencies`. This is the common case: `2c665a6` (tar, brace-expansion),
   `964d3c9` (seven advisories at once).
2. **It does not fit → bump the direct dependency** in `infra/package.json` so the
   floor is encoded where a human will see it (`^3.0.0` → `^3.252.0`). Example:
   `430370e`.
3. **`pnpm.overrides` / `resolutions`: no.** Never used here, and rejected once on
   evidence — pinning a transitive Pulumi dependency broke the SDK at load, because
   the 1.x OTel siblings import symbols removed in core 2.x. Bump the coordinated
   parent instead.
4. **The fix is younger than the cooldown** (`minimumReleaseAge: 4320`, three days,
   `infra/pnpm-workspace.yaml`) → exempt that one `package@version` via
   `minimumReleaseAgeExclude`. Never lower the floor itself, which would exempt
   everything. **This rung has a hard precondition — see below.**

#### Undercutting a cooldown: research first, fetch second

Not negotiable, and not a matter of taste. The cooldown *is* the control that
catches a compromised release, so exempting a package removes exactly that control
for exactly that package. "Just bump it and see if anything breaks" is not
available: `pnpm update` downloads and unpacks the tarball, and `tsc`/Pulumi then
import it. By the time a test could fail, the code has already run on a machine
holding this repo's SOPS secrets and its Cloudflare and AWS credentials. Research
that starts after the install starts too late.

1. **Research while fetching nothing.** Establish that this specific
   `package@version` is not part of a live supply-chain incident: read the upstream
   fix commit and the advisory; inspect the maintainer set, publish provenance and
   signatures through registry *metadata* only (`npm view <pkg>@<ver> --json`, or
   `curl -fsSL https://registry.npmjs.org/<pkg>`); check GitHub Security Advisories,
   the project's issue tracker, and current incident reporting (Socket,
   StepSecurity, Snyk, OpenSSF) for the **package and its maintainers** — a
   maintainer-account compromise shows up there before it shows up in the package.
   If anything looks off, diff the published tarball against the tagged source.
2. Only then add the `minimumReleaseAgeExclude` entry, run the update, and verify.
3. If the research cannot conclude cleanly, **wait out the cooldown** and mitigate
   another way: route around the vulnerable code path, disable the feature, or
   accept the risk explicitly and say so in the commit. Waiting is by far the
   cheaper failure mode.

The same rule governs every other cooldown here — the uv `exclude-newer-package`
overrides in `modules/ai/_files/skills/browser-use/scripts/browser-use.py` and the
global `exclude-newer` / `min-release-age` floors in
`modules/supply-chain-hardening.nix`. Any cooldown, same precondition.

#### Verifying and recording

Before committing: `just pulumi-audit` clean, `cd infra && pnpm audit` clean,
`pnpm exec tsc --noEmit` green.

Commit bodies here double as the runbook, so write them accordingly: the advisory
(severity, GHSA, CVSS vector), the dependency path that pulls the package in, which
rung you used and why the ones above it did not apply, and the publish age of the
version you moved to.

