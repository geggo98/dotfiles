# DevDocs (https://github.com/freeCodeCamp/devdocs) families installed by
# `modules/devdocs.nix`, default for `my.devdocs.docs`.
#
# A name here without `~` is a FAMILY: `just devdocs-lock` re-resolves it to
# the newest slug in https://devdocs.io/docs.json on every run — a bare slug
# if devdocs.io publishes one (`node`, `typescript`, `git`), otherwise the
# highest `<family>~*`, compared numerically. A name WITH `~` is a PIN and is
# never re-resolved; none of the defaults below use one, but a host override
# can pass one to freeze a specific release.
#
# This is the first `.nix` file under a `_files/` directory in this repo.
# `import-tree` is supposed to skip leading-underscore paths (that is the
# whole reason `_files`/`_tests` are named that way), and `just eval` in the
# commit that added this file is what actually proved it. If that ever
# surprises us, the fallback is `families.json` + `lib.importJSON` — costs the
# per-family comments below, nothing else.
#
# Chosen 2026-09-17 with the user, license-cleared per family (see the plan
# under ~/.claude/plans at the time, or `git log -- modules/devdocs.nix`):
# every family below carries an explicit redistribution license except `man`,
# whose per-page licenses (GPL/BSD/MIT) are individually attributed but not
# summarized by DevDocs' own catalog — devdocs.io serves it unauthenticated
# regardless, the same basis AGENTS.md already argues from for this cache.
[
  # --- JVM ---
  "openjdk" # the JDK's own javadoc — the reason this module exists
  "kotlin"
  "groovy"
  "scala"
  "spring_boot" # upstream doc frozen at 3.1.3 (2023); still the only offline Spring Boot reference
  "clojure"

  # --- Languages ---
  "rust"
  "go"
  "python"
  "typescript"
  "javascript" # MDN JS reference, distinct from the TypeScript doc above
  "node"
  "deno"
  "bun"

  # --- Web (MDN, CC-BY-SA 2.5+) ---
  "html"
  "css"
  "svg"
  "dom" # "Web APIs" in the DevDocs catalog
  "web_extensions"
  "react"
  "vue"
  "playwright"
  "http"

  # --- Data ---
  "postgresql"
  "sqlite"
  "duckdb"
  "redis"

  # --- Infrastructure ---
  "docker"
  "kubernetes"
  "kubectl"
  "terraform"
  "git"

  # --- Shell & system ---
  "bash"
  "zsh"
  "fish"
  "jq"
  "man" # Linux man pages — not a duplicate of macOS `man`, which serves BSD pages
  "nix"
  "hammerspoon"

  # --- Added 2026-09-18: hides under a non-obvious slug ---
  "browser_support_tables" # "Can I use" (caniuse.com); CC-BY-4.0. This IS the
  # caniuse-db data devdocs.io already carries, just not under the name
  # "caniuse" -- the slug alone made it look absent. Zeal/Dash's own CanIUse
  # docset (a 2017 snapshot) would be nine years staler than this.
]
