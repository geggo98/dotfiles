# Reviewed extensions

Review of 2026-11-05: per extension one reviewer and one adversarial second reviewer,
checking licence, maintenance, known incidents, runtime downloads and pack members. Every
entry below also cleared the 14-day cooldown on the Marketplace that day. A verdict is a
snapshot — `+vscode-ext scan` re-checks the cooldown and withdrawal on every run, the
rest ages. Licences are the upstream ones; **unfree** extensions are marked because they
must never be built through Nix here (a local build would be pushed into the public binary
cache); a runtime install of them is the user's decision.

Extensions that Nix already provides in every profile are not listed
(`modules/_files/vscode/EXTENSIONS.md` has that inventory).

## Nix stack profiles (`code --profile <name> <repo>`)

| Profile | Extensions |
|---|---|
| `java` | redhat.java, vscjava.vscode-java-debug, -java-test, -java-dependency, -maven, -gradle, vmware.vscode-spring-boot, vscjava.vscode-spring-boot-dashboard, redhat.vscode-xml, ivory-lab.jenkinsfile-support |
| `python` | ms-python.python, ms-python.debugpy, charliermarsh.ruff, ms-python.mypy-type-checker, ms-toolsai.jupyter-renderers |
| `web` | dbaeumer.vscode-eslint, esbenp.prettier-vscode, vitest.explorer, ms-playwright.playwright, Vue.volar, bradlc.vscode-tailwindcss |
| `slidev` | the `web` set without Tailwind, plus antfu.slidev, github.vscode-github-actions, mkhl.direnv, ltex-plus.vscode-ltex-plus |
| `nix` | ms-python.python, charliermarsh.ruff, timonwong.shellcheck, mkhl.shfmt, idleberg.applescript, nefrob.vscode-just-syntax, editorconfig.editorconfig, sumneko.lua |

## Recommend

Free, maintained, no uncontrolled runtime download.

| Stack | Extension | Note |
|---|---|---|
| Java | redhat.java | EPL-2.0, embeds a JRE. Runs the project's Gradle/Maven build on import, so Workspace Trust is the guard. CVE-2026-12856 (CVSS 8.8, 2026-06-29): hover Markdown trusted, a crafted link in a JavaDoc hover runs VS Code commands. **The fixed version is not confirmed** (NVD names no vscode-java range, the changelog 1.56–1.58 mentions no fix): open Java code of unknown origin in Restricted Mode |
| Java | vscjava.vscode-java-debug, -java-test, -java-dependency | MIT. Test and debug run project code by design |
| Java | vscjava.vscode-maven, vscjava.vscode-gradle | MIT. The Marketplace is ahead of Open VSX; the wrapper downloads a build tool distribution |
| Java | vmware.vscode-spring-boot, vscjava.vscode-spring-boot-dashboard, redhat.vscode-xml | EPL / MIT / EPL |
| Jenkins | ivory-lab.jenkinsfile-support | MIT, syntax and snippets only, Marketplace only |
| Python | ms-python.python | MIT. Its pack names Pylance (unfree); `+vscode-ext` pulls the cooled members, so Pylance arrives in a `oneoff` install but never through Nix |
| Python | ms-python.debugpy, ms-python.mypy-type-checker, charliermarsh.ruff, ms-toolsai.jupyter-renderers | MIT |
| Web | dbaeumer.vscode-eslint, esbenp.prettier-vscode, bradlc.vscode-tailwindcss, vitest.explorer, Vue.volar, denoland.vscode-deno | MIT, no pack |
| Web | ms-playwright.playwright | Apache-2.0. Newest **stable** is 1.1.19; 1.1.20 is a pre-release |
| Infra | hashicorp.terraform | MPL-2.0, verified vendor |
| Infra | mkhl.direnv | 0BSD, tiny surface, dormant since 2024 but feature-complete |
| General | usernamehw.errorlens, streetsidesoftware.code-spell-checker, editorconfig.editorconfig, github.vscode-github-actions, mechatroner.rainbow-csv | MIT (spell checker GPL-3.0-or-later) |
| General | nefrob.vscode-just-syntax | MIT, the maintained successor of the archived skellock.just |
| Shell | timonwong.shellcheck | MIT, org-owned. Bundled binary; point `shellcheck.executablePath` at a Nix one |
| Shell | mkhl.shfmt | 0BSD, no binary of its own; set `shfmt.executablePath` |
| macOS | idleberg.applescript | MIT, grammar plus `osascript` build tasks |
| Rust | rust-lang.rust-analyzer | MIT/Apache. Take a stable 0.3.x, not the 0.4.x nightlies |
| Scala | scalameta.metals | Apache-2.0. Newest **stable** is 1.72.0; 1.72.1–3 are pre-releases. Marketplace only |
| Scala | scala-lang.scala | MIT, grammar only |

## Caution — ask before installing, say why

| Extension | Reason |
|---|---|
| ms-toolsai.jupyter | MIT, but no stable release since 2025-10, only pre-releases; its pack pulls four more extensions; runs notebook kernels |
| ms-python.vscode-pylance | **Unfree** (Microsoft). Alternatives: detachhead.basedpyright (MIT), astral-sh.ty (MIT) |
| betterthantomorrow.calva | Downloads the *latest* clojure-lsp at runtime and has telemetry on; set `calva.clojureLspPath` and `calva.telemetryEnabled` |
| NicolasVuillamy.vscode-groovy-lint | MIT, effectively one maintainer, installs a JDK itself when none is found |
| marlon407.code-groovy | Dormant 2019–2026-09, then revived by new contributors — the takeover pattern; pulls redhat.java and the debugger |
| mathiasfrohlich.Kotlin | Grammar only but abandoned since 2020 on a 2 M-install id |
| JetBrains.kotlin-server | The official Kotlin LSP, but **unfree** |
| biomejs.biome | Every build is flagged pre-release; writes user settings on activation, which are a read-only store file here |
| antfu.slidev | Official repo, MIT, but the publisher is not domain-verified and releases are very frequent — which is why it lives in a hash-pinned Nix profile instead of a runtime install |
| oven.bun-vscode | Official, stuck at 0.0.32 since 2025-12, activates on every start |
| pulumi.pulumi-vscode-tools | A pack: pulls pulumi-lsp-client (last release 2024-09), which only supports Pulumi YAML |
| arrterian.nix-env-selector | Duplicates direnv and runs `nix-shell` on workspace files without a gate |
| mtxr.sqltools | Activates on `*`; drivers npm-install native modules at runtime |
| ms-ossdata.vscode-pgsql | **Unfree** (Microsoft licence), no source |
| ltex-plus.vscode-ltex-plus | MPL-2.0. Downloads ltex-ls-plus from GitHub at runtime unless `ltex.ltex-ls.path` points at one — Nix provides it |
| tamasfe.even-better-toml | No release since 2024-12; tombi-toml.tombi is an alternative (its newest release was inside the cooldown on 2026-11-05 — re-check) |
| sumneko.lua | MIT, but bundles a binary and an addon manager that clones unpinned definitions from GitHub; set `Lua.misc.executablePath` and `Lua.addonManager.enable = false` |
| golang.go | MIT, runs `go install` for gopls/dlv/staticcheck at runtime |
| graphql.vscode-graphql | Executes JS/TS GraphQL config files from the workspace |
| vaadin.vaadin-vscode | Telemetry; downloads JetBrains Runtime and HotswapAgent |
| vscjava.vscode-java-pack, vmware.vscode-boot-dev-pack | Packs: install the members individually so each is cooled and visible |

## Reject — do not install; tell the user why

| Extension | Reason |
|---|---|
| signageos.signageos-vscode-sops | Writes the **decrypted** file as `.decrypted~<name>` into the working directory, next to the encrypted one; deleted only on a focus change, not on crash or quit, and no `.gitignore` entry. That is a secret in the git working tree and in agent context. Use `sops edit` in a terminal; `git dsops` shows decrypted diffs |
| foxundermoon.shell-format | Downloads shfmt without a checksum into `/usr/local/bin`; mkhl.shfmt does the job |
| vscjava.vscode-lombok | Redundant: redhat.java supports Lombok by default |
| fwcd.kotlin | Upstream declared it deprecated in favour of the official LSP |
| janjoerke.jenkins-pipeline-linter-connector | Abandoned since 2019; wants Jenkins credentials in settings.json |
| humao.rest-client | Abandoned (2022), open issue "This is DEAD. Ask for new maintainers", and a fork is being promoted — the takeover pattern. Check anweber.vscode-httpyac before suggesting it |
| cweijan.vscode-database-client2 | **Unfree**; the 9.x code is closed while the repo stays at 3.9.8 |
| skellock.just | Archived, single release 2017; use nefrob.vscode-just-syntax |
| ms-vsliveshare.vsliveshare | **Unfree**; relays workspace content through a Microsoft service. typefox.open-collaboration-tools is an open alternative (not reviewed) |
