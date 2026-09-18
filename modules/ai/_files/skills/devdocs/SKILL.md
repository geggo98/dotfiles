---
name: devdocs
description: Offline API reference from a local index — DevDocs (freeCodeCamp) for the JDK's own javadoc plus Kotlin, Groovy (GDK), Scala, Spring Boot's reference guide, Clojure, "Can I use" (as `browser_support_tables`), and ~35 other docs (Rust, Go, Python, TypeScript, Node, Deno, Bun, CSS, Web APIs, React, Vue, Playwright, PostgreSQL, MariaDB, SQLite, DuckDB, Docker, Kubernetes, Terraform, Git, shells, jq, man pages, Hammerspoon) — PLUS javadoc built straight from Maven Central for Apache Commons (~20 components: Lang3, IO, Collections4, Text, Codec, CSV, Compress, CLI, Net, Pool2, DBCP2, Configuration2, Validator, BeanUtils, Exec, VFS2, JEXL3, FileUpload, Numbers, RNG, Statistics), JUnit 5 (Jupiter/Platform), Groovy's own Java API (`groovy-api`, distinct from the GDK docs above), and Spring (Framework, Boot 4.x, Security, Data) — plus Gradle's own javadoc and Valkey's command reference (`valkey-commands`, a maintained Redis-compatible fork). Use whenever a class, method, function, command or signature from any of these comes up — even when you think you know the answer, your training data lags every one of them. NOT for nixpkgs packages, NixOS/home-manager/nix-darwin options or /nix/store paths — use the `nixos` skill for those. Anchor-scoped, so one member costs ~200 tokens instead of a whole page. Prefer this over the `javadocs` MCP for the JDK/Commons/JUnit/Spring (that MCP is remote and flaky; this index is offline and pinned), over context7 for exact signatures, and over WebSearch for anything the installed docs cover.
allowed-tools: Bash(+devdocs *) Read
dependencies: "+devdocs (installed by modules/devdocs.nix, my.devdocs.enable); doc databases live in /nix/store — no network, no API key"
---

# Offline API reference (DevDocs)

Your training data lags every one of these APIs, sometimes by years. This
index answers in milliseconds, entirely offline, and scopes to the single
member you asked for instead of dumping a whole page. Use it **even when you
think you know the signature**.

```bash
+devdocs docs                                   # what is installed, release, size
+devdocs search groupingBy                      # fuzzy over names and paths, all docs
+devdocs show 'java.util.List#add(int,E)'       # one member, ~200 tokens
+devdocs members java.util.List                 # every method on a class, names only
```

## The package lives in the path, not the name

The one fact that otherwise wastes a turn: index entries carry a **simple**
name, not a fully-qualified one — `List`, not `java.util.List`; `List.add()`,
not `java.util.List.add()`. The package only appears in the *path*
(`java.base/java/util/list#add(int,E)`). `+devdocs` resolves
`java.util.List` by matching it as a path suffix, so you can type the FQN you
already know and it works — but anchors contain `(`, `)`, `,`, `<`, `>`, so
**always single-quote a ref**:

```bash
+devdocs show 'java.util.stream.Collectors#groupingBy(java.util.function.Function)'
```

The Maven-Central-sourced docs (Commons, JUnit 5, Groovy's `groovy-api`,
Spring, Gradle) are real javadoc too, so the same path-suffix resolution
applies — just without OpenJDK's module prefix: `org/junit/jupiter/api/
assertions`, not `java.base/java/util/list`. A nested class keeps its dot
(`org/springframework/web/client/restclient.builder` for `RestClient.
Builder`), so both `RestClient.Builder` and the fully-qualified form resolve.

## Commands

| Intent | Command |
|---|---|
| list installed docs, release, size | `+devdocs docs` |
| fuzzy search names/paths | `+devdocs search QUERY [--doc SLUG]... [--type T] [--limit N]` |
| one member, anchor-scoped | `+devdocs show 'PAGE#ANCHOR'` |
| a page by FQN, no anchor | `+devdocs show java.util.List` |
| every member of a page | `+devdocs members REF [--doc SLUG]` |
| a whole page | `+devdocs page SLUG PATH` |
| a doc's category index | `+devdocs types SLUG` |
| a page not installed anywhere | `+devdocs show --online --doc SLUG 'PATH[#ANCHOR]'` |
| is the index healthy | `+devdocs doctor` |

`--doc` matches by unambiguous prefix (`--doc openjdk` → `openjdk~25`), same
convention as this repo's `+vault -address=`. Without `--doc`, `search` and
`show` check every installed doc — the doc name is always printed in the
result, so a hit tells you which one to pin down next time.

## When several members match

`#add` matches both `add(E)` and `add(int,E)` — DevDocs entries are simple
names, and `List.add()` is one entry covering every overload. Up to 3
same-page candidates render together, separated by `---`, with a note on
stderr; more than that, or matches spread across different pages or docs,
renders nothing and lists the candidates instead (exit 4) — copy the exact
`path#anchor` from that list for the follow-up call. `+devdocs members` is
the fast way to learn the exact anchor before calling `show`.

## Which tool for which question

| Question | Tool |
|---|---|
| Signature/behaviour from any doc `+devdocs docs` lists | **`+devdocs`** — offline, anchor-scoped, first choice |
| Javadoc for a third-party Maven artifact NOT in `+devdocs docs` | `javadocs` MCP — the only source for arbitrary GAV coordinates. Remote and prone to timeouts; check `+devdocs docs` first (JDK, Commons, JUnit 5, Groovy, Spring, Gradle are all offline here) |
| "How do I wire up X", version-specific framework guides | `context7` |
| Release notes, behaviour newer than the installed release | `WebSearch`/`tavily` — `+devdocs docs` prints the release and how old it is |
| nixpkgs, NixOS/home-manager/darwin options, flakes, /nix/store | the `nixos` skill, not this one |

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | success |
| 1 | searched, nothing matched — the population searched is always named |
| 3 | could not search at all: bad env, corrupt db, unknown/uninstalled slug, `search --online` |
| 4 | ambiguous — nothing rendered, candidates listed |
| 5 | slug is known upstream but not installed here |
| 6 | network error in `--online` mode |

Exit 1 means the index was searched and the answer is no. 3/5/6 mean it
could not be searched at all — do not treat them the same as "no match".

## Notes

- A whole class page can be tens of KB; never paste one into context blind —
  use `--output -` (byte-exact) or `--output FILE` if you need the full text
  rather than the default truncated stdout.
- `--format json` is never truncated and carries a `chars` field, so a large
  result can be size-checked before asking for the body.
- `--online` is opt-in per call and needs an explicit page path — there is
  no online *search*, only a direct page fetch for a doc not installed here.
