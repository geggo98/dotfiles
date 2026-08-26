# VS Code extensions — what is managed, what is not, and why

Inventory taken 2026-08-26 from `~/.vscode/extensions/extensions.json` (VS Code's own
register), not from the directory listing — that carries roughly 18 stale version
folders which VS Code garbage-collects on its own.

**The rule:** a general extension — one that is useful in any repository — is pinned in
`modules/vscode.nix` and comes from Nix. Anything with a language toolchain behind it is
project-specific and belongs in that project's `.vscode/extensions.json`. This split is
the one `scripts/supply-chain.toml` writes down: *"Nix manages the default extension
set; further extensions go in each project's `.vscode` metadata."*

## Managed by Nix (16)

Declared in `modules/vscode.nix`, audited by `just audit-extensions`, cooled down by the
age of the `nix-vscode-extensions` input.

| Group | Extensions |
|---|---|
| Markdown, docs, diagrams | `davidanson.vscode-markdownlint`, `yzhang.markdown-all-in-one`, `jebbs.plantuml`, `pomdtr.excalidraw-editor` |
| Containers, Kubernetes | `docker.docker`, `ms-azuretools.vscode-containers`, `ms-kubernetes-tools.vscode-kubernetes-tools` |
| Git | `eamodio.gitlens` |
| This repo's own languages | `jnoortheen.nix-ide`, `redhat.vscode-yaml`, `bmalehorn.vscode-fish` |
| Editor comfort | `vscode-icons-team.vscode-icons`, `christian-kohler.path-intellisense`, `marclipovsky.string-manipulation`, `ms-vscode.hexeditor`, `deerawan.vscode-dash` |

Plus `local-turbo-vision-theme`, which is built from files in this repo and exists in no
registry.

### Open VSX is not a faithful mirror — pick the registry per extension

This is the trap, and it is silent: choosing one registry for everything pins stale
versions without any error. Measured 2026-08-26 against both registries:

| Extension | Open VSX | Marketplace | used |
|---|---|---|---|
| `christian-kohler.path-intellisense` | 2.8.0 (2022-02) | 2.10.0 (2024-11) | marketplace |
| `yzhang.markdown-all-in-one` | 3.6.2 (2024-01) | 3.6.3 (2025-03) | marketplace |
| `pomdtr.excalidraw-editor` | 3.9.0 | 3.9.3 | marketplace |
| `ms-azuretools.vscode-containers` | 2.4.5 | 2.5.0 | marketplace |
| `deerawan.vscode-dash` | **404** | 2.4.0 | marketplace |
| the other eleven | current | — | open-vsx |

Two more facts from the same measurement:

- **Use the `-release` attribute sets.** `open-vsx` and `vscode-marketplace` include
  pre-releases; `open-vsx-release` and `vscode-marketplace-release` do not. Visible on
  GitLens, where the plain set yields `2026.8.251013` (the pre-release channel) and the
  `-release` set yields `18.3.0`.
- **Marketplace ids are case-insensitive but have a canonical casing.** A bulk query
  keyed on the lowercase id makes `ms-vsliveshare.vsliveshare` look withdrawn; the
  publisher is canonically `MS-vsliveshare`. Match case-insensitively before concluding
  an extension is gone.

## Deliberately NOT managed (3)

Same reasoning as Gram's `settings.jsonc` in `modules/gram.nix`: manage what only you
write; leave alone what something else writes back.

| Extension | Why not |
|---|---|
| `anthropic.claude-code` | Ships in lockstep with the CLI, which this repo pins through `nixpkgs-llm-agents`. Three versions were on disk at inventory time (2.1.210, 2.1.241, 2.1.243). A Nix pin would drift against the CLI it talks to. |
| `openai.chatgpt` | Same, for the ChatGPT CLI. |
| `ms-vscode-remote.remote-containers` | The only unfree one of the seventeen candidates (`meta.unfree = true`; every other is MIT or Apache-2.0). Building it locally would make the R2 `post-build-hook` publish a non-redistributable Microsoft binary into a world-readable bucket — the same reason VS Code itself stays on the Homebrew cask. A licence filter in the push hook is not available: `meta.license` is eval-time data and is not recorded in the store. |

Install these three by hand. To take `remote-containers` under Nix anyway, add
`vsmp.ms-vscode-remote.remote-containers` in `modules/vscode.nix` and accept the
publication — it is one line, and the decision belongs to whoever makes it.

## Project-specific — install per project, not globally (24)

**All 24 were removed from the global install on 2026-08-26.** They are listed here as
the record of what belongs where, not as what is installed. Put them in the project's
`.vscode/extensions.json`. VS Code then offers them when the
folder is opened, and the pinning question stays with the project that needs them:

```json
{
  "recommendations": ["scalameta.metals", "scala-lang.scala"]
}
```

| Stack | Extensions |
|---|---|
| Scala | `scala-lang.scala`, `scalameta.metals` |
| Clojure | `betterthantomorrow.calva`, `betterthantomorrow.calva-spritz` |
| Java | `redhat.java`, `vscjava.vscode-java-pack`, `vscjava.vscode-java-debug`, `vscjava.vscode-java-dependency`, `vscjava.vscode-java-test`, `vscjava.vscode-maven`, `vscjava.vscode-gradle` |
| Python | `ms-python.python`, `ms-python.debugpy`, `ms-python.vscode-pylance`, `ms-python.vscode-python-envs` |
| Go | `golang.go` |
| Rust | `rust-lang.rust-analyzer` |
| Web / Vue | `vue.volar`, `dbaeumer.vscode-eslint`, `esbenp.prettier-vscode`, `zenclabs.previewjs`, `nicoespeon.abracadabra` |
| Slides | `antfu.slidev` |
| AWS | `amazonwebservices.aws-toolkit-vscode` |
| XML | `dotjoshjohnson.xml` (Maven POMs) |
| Nix | `jnoortheen.nix-ide` — cross-listed, see below |

**`jnoortheen.nix-ide` appears in both lists on purpose**, and the two entries mean
different things. It is in the managed set because this machine edits Nix everywhere, so
the editor should always have it. It belongs in a Nix project's `.vscode/extensions.json`
regardless: that file states what the PROJECT expects, for a colleague or for this user on
a machine without the managed set. The managed set is a property of the machine; the
recommendation is a property of the repository. `bbenoist.nix` is the one it replaces —
syntax highlighting only, last published 2020, no LSP.

```json
{
  "recommendations": ["jnoortheen.nix-ide"]
}
```

`ms-python.vscode-pylance` is proprietary and exists only on the marketplace — another
reason it is not a candidate for the managed set.

## Removed 2026-08-26 (9 dormant + the 24 above)

Nine extensions were dormant at inventory time. All nine are gone. Four of them were
researched for a replacement first; the answer for three of those four was **no
replacement needed**, which is why this table has an "instead" column rather than a list
of new extensions to install.

| Removed | Finding | Instead |
|---|---|---|
| `rubbersheep.gi` | last commit 2017-05-22; PR #8 implementing the one open feature has sat unmerged since 2025-08-04 | `gh api /gitignore/templates/Node --jq .source`; for several templates at once `curl 'https://www.toptal.com/developers/gitignore/api/node,macos'`; for one entry the built-in `git.ignore` command |
| `p42ai.refactor` | vendor wound down, `p42.ai` has no A record, calls a dead cloud endpoint, open bug "crashes TS language server" | the built-in TypeScript service covers 15 refactorings; `biome check --write .` / `eslint --fix .` cover the bulk rewrites; `nicoespeon.abracadabra` covers the rest — **project-specific**, listed above |
| `randomfractalsinc.vscode-data-preview` | last functional release 2021-02-28, 69 open issues, and it bundles `xlsx@0.16.7` + `lodash@4.17.15` + `js-yaml@3.14.0` — 15 OSV advisories, 6 HIGH, in 136 MB of webview code whose whole job is parsing untrusted data files | `duckdb`: `FROM 'x.parquet' LIMIT 3`, `SUMMARIZE`, `INSTALL excel` + `read_xlsx()`, and `duckdb -ui` for the grid. Gap: Avro, where `uv run --with fastavro` covers it |
| `jrebocho.vscode-random` | last *human* merge 2024-08-16; all six open PRs are Dependabot | VS Code's snippet variables `$UUID`, `$RANDOM`, `$RANDOM_HEX`, bound in `keybindings.json`; plus `uuidgen`, `openssl rand -hex 8`, `jot -r 3 1 100`, and `uv run --with faker` |
| `bbenoist.nix` | 2020, syntax only | `jnoortheen.nix-ide` (managed) |
| `ms-azuretools.vscode-docker` | superseded | `docker.docker` + `ms-azuretools.vscode-containers` (both managed) |
| `emmanuelbeziat.vscode-great-icons` | second icon theme, and neither was active | `vscode-icons-team.vscode-icons` (managed), now named in `workbench.iconTheme` |
| `humy2833.ftp-simple` | 2021-03-09 | — |
| `ms-vsliveshare.vsliveshare` | still published, unused here | — |

Two candidates were considered and **rejected on evidence**, which is worth recording so
they are not proposed again. `qcz.text-power-tools` fits functionally but its maintainer
has not answered an issue since 2025-04-14 — the exact pattern being escaped here — and
its fake-data engine is `"faker": "github:qcz/faker#v5.2.0-tpt-3"`, a personal fork of the
dead faker.js pulled around npm, and therefore invisible to `pnpm audit`, to npm
cooldowns and to `just audit`. `biomejs.biome` publishes only CalVer pre-releases, so
under this repo's `-release` convention both registries resolve to **1.6.2**, a 2024
build; the value is in `biome check --write .` from nixpkgs anyway.

Two corrections to widely repeated claims, both measured against the installed
VS Code 1.134.0 rather than assumed: there is **no** built-in `.gitignore` template
picker — enumerating `contributes.commands` across all 97 bundled extensions yields
exactly one match, `git.ignore` — and `$UUID` resolves through `crypto.randomUUID()`
while `$RANDOM` is `Math.random()`, so the latter is never suitable for a secret.

## Working on the managed set

**Adding one.** Check both registries first — the table above exists because they
disagree. Then add the entry to `modules/vscode.nix` *and* to `[[extensions]]` in
`scripts/supply-chain.toml`; the second is what `just audit-extensions` reads, and an
extension missing there is simply never audited.

```bash
just audit-extensions <publisher>.<name>                     # Open VSX
python3 scripts/supply-chain.py audit --extensions-only \
  --registry vscode-marketplace --extension <publisher>.<name>
```

The `just` recipe always asks Open VSX; the marketplace needs the script directly,
because `--registry` applies to the whole invocation rather than per id.

**Moving the set forward.** `just update` advances `nix-vscode-extensions` to the newest
revision at least 14 days old, which is what gives every extension its cooldown. There
are no version strings to edit.

**The failure mode to recognise.** A gallery copy sitting next to the Nix symlink wins,
because VS Code loads the higher version and the gallery copy carries a version suffix
in its directory name while the Nix one does not. The pin then exists and does nothing.

```bash
find ~/.vscode/extensions -maxdepth 1 -type l ! -name '.*' | wc -l   # expect 16
ls ~/.vscode/extensions | grep -E '^(docker\.docker|eamodio\.gitlens)-'  # expect nothing
```

`! -name '.*'` excludes `.nix-managed-extensions.json`, the hook's trigger file, which is
a symlink too — without it the count is 17 and the check fails on a healthy machine.

`find`, deliberately, not `ls -l | grep -- '->'`: the latter reported 0 on a correctly
switched machine because the interactive `ls` renders symlinks with `⇒`. A shell alias
must not decide whether a check passes.

**`code --uninstall-extension` reporting success is not proof the directory is gone.**
Two failure modes were measured on 2026-08-26 while clearing 33 extensions. First, an
uninstall normally only queues the directory in `.obsolete` and VS Code deletes it at its
next start — so "uninstalled" and "removed from disk" are different states. Second, and
worse, `jrebocho.vscode-random` reported `OK` while its directory was neither deleted nor
queued, and a later rescan duly registered it again. Check the directory, never the exit
code:

```bash
ls ~/.vscode/extensions | grep -E '^<publisher>\.<name>-'   # expect nothing
```

Uninstall dependents before dependencies, too: `ms-azuretools.vscode-containers` cannot
be removed while `ms-azuretools.vscode-docker` declares it in `extensionDependencies`,
and the same holds for `ms-python.debugpy` → `ms-python.python` and
`vscjava.vscode-java-test` → `redhat.java`, `vscjava.vscode-java-debug`.

`extensions.autoUpdate` and `extensions.autoCheckUpdates` are both off in
`modules/vscode.nix` for exactly this reason. The cost is deliberate and worth stating:
hand-installed project extensions stop updating themselves too.

Note the two are off in different **types**: `extensions.autoCheckUpdates` is a boolean,
`extensions.autoUpdate` is the string `"off"`. VS Code turned the latter into a
`["on", "off"]` enum and ships a migration that rewrites a leftover `false` — which it
then cannot save here, because settings.json is a read-only `/nix/store` symlink, so it
retries on every start. `just vscode-settings-check` is the check for that.
