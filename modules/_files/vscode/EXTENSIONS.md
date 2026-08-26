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

Put them in the project's `.vscode/extensions.json`. VS Code then offers them when the
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
| Web / Vue | `vue.volar`, `dbaeumer.vscode-eslint`, `esbenp.prettier-vscode`, `zenclabs.previewjs` |
| Slides | `antfu.slidev` |
| AWS | `amazonwebservices.aws-toolkit-vscode` |
| XML | `dotjoshjohnson.xml` (Maven POMs) |

`ms-python.vscode-pylance` is proprietary and exists only on the marketplace — another
reason it is not a candidate for the managed set.

## Dormant at inventory time (9) — candidates for removal

Not acted on: it is a personal editor, and removal is a decision, not a cleanup.

| Extension | Finding |
|---|---|
| `rubbersheep.gi` | last published **2017-05-09** |
| `humy2833.ftp-simple` | 2021-03-09 |
| `p42ai.refactor` | 2023-03-13 |
| `randomfractalsinc.vscode-data-preview` | Open VSX 2020-11-29 |
| `jrebocho.vscode-random` | 2024-08-16 |
| `bbenoist.nix` | 2020; superseded by `jnoortheen.nix-ide` |
| `ms-azuretools.vscode-docker` | superseded by `docker.docker` + `ms-azuretools.vscode-containers` |
| `emmanuelbeziat.vscode-great-icons` | second icon theme |
| `ms-vsliveshare.vsliveshare` | still published (1.1.122), unused here |

`settings.json` set no `workbench.iconTheme` at all until 2026-08-26, so **both** icon
themes were inert. It now names `vscode-icons`, which is the managed one.

```bash
code --uninstall-extension rubbersheep.gi     # …and so on
```

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
find ~/.vscode/extensions -maxdepth 1 -type l | wc -l     # expect 16
ls ~/.vscode/extensions | grep -E '^(docker\.docker|eamodio\.gitlens)-'  # expect nothing
```

`find`, deliberately, not `ls -l | grep -- '->'`: the latter reported 0 on a correctly
switched machine because the interactive `ls` renders symlinks with `⇒`. A shell alias
must not decide whether a check passes.

`extensions.autoUpdate` and `extensions.autoCheckUpdates` are both off in
`modules/vscode.nix` for exactly this reason. The cost is deliberate and worth stating:
hand-installed project extensions stop updating themselves too.
