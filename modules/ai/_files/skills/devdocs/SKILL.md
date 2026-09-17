---
name: devdocs
description: Offline API reference from a local DevDocs (freeCodeCamp) index — the JDK's own javadoc plus Kotlin, Groovy, Scala, Spring Boot, Clojure, and ~35 other docs (Rust, Go, Python, TypeScript, Node, Deno, Bun, CSS, Web APIs, React, Vue, Playwright, PostgreSQL, SQLite, DuckDB, Redis, Docker, Kubernetes, Terraform, Git, shells, jq, man pages, Hammerspoon). Use whenever a class, method, function, option or signature from any of these comes up — even when you think you know the answer, your training data lags every one of them. NOT for nixpkgs packages, NixOS/home-manager/nix-darwin options or /nix/store paths — use the `nixos` skill for those. Anchor-scoped, so one member costs ~200 tokens instead of a whole page. Prefer this over the `javadocs` MCP for the JDK itself (that MCP is remote, flaky, and only useful for third-party Maven artifacts this index does not carry), over context7 for exact signatures, and over WebSearch for anything the installed docs cover.
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
| Javadoc for a third-party Maven artifact (not the JDK itself), or its source | `javadocs` MCP — the only source for arbitrary GAV coordinates. Remote and prone to timeouts; check whether devdocs already covers the JDK part first |
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
