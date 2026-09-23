# DevDocs offline index

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

### DevDocs offline index

`modules/devdocs.nix` builds an offline [DevDocs](https://github.com/freeCodeCamp/devdocs)
lookup (`+devdocs`) from 39 doc families declared in `modules/_files/devdocs/families.nix`,
resolved and hash-pinned in the checked-in `modules/_files/devdocs/docs.lock.json`. It exists
because the `javadocs` MCP server (`modules/mcp-servers.nix`) fails/times out repeatedly —
this **complements** it, it does not replace it: DevDocs covers the JDK's own API plus
Kotlin, Groovy, Scala, Spring Boot and Clojure, but no arbitrary third-party Maven artifact,
which stays the MCP server's job.

**Own namespace, `my.devdocs`, deliberately not `my.ai.devdocs`.** `ai-options.nix`'s
`key = "nix-darwin-ai-options"` exists because four AI aspects read each other's settings;
devdocs reads none of theirs and none of them reads devdocs — it only sits near the AI
tooling because its skill lives under `modules/ai/_files/skills/devdocs/`, which
`agent-content.nix` already picks up with no registration needed.

**Compression: zlib with a per-doc trained preset dictionary, not zstd/brotli.** Measured
against real OpenJDK/CSS/man pages: DevDocs' redundancy is almost entirely CROSS-page
boilerplate (navigation, headers, repeated CSS classes), which no per-blob-independent
codec can see regardless of algorithm — zlib alone compresses at 0.182, zstd alone at
0.173, but zlib **with** a trained 32 KiB preset dictionary (`zlib.compressobj(...,
zdict=...)`, a stdlib feature since Python 3.3) reaches 0.117, nearly matching zstd+dict's
0.093 for zero runtime dependencies. The dictionary is trained by the `zstd` CLI
(`zstd --train -r <dir>`) purely as a **build-time tool** — no zstd runtime library is ever
loaded, at build time or by `+devdocs` itself. Full measurement in `build-index.py`'s module
docstring. `-r <directory>`, not a directory listing expanded on the command line: passing
~12,600 individual file paths (the `man` doc) blew `ARG_MAX` inside the Nix build sandbox
even though the identical approach succeeded in an interactive shell — the sandbox's larger
`PATH`-like environment eats into the same combined argv+envp budget.

**Bump ritual** (family → newest slug, mirrors `agent-browser-hashes`'s `nix store
prefetch-file` pattern):

```bash
just devdocs-list           # what's pinned vs. what upstream serves — no download
just devdocs-lock           # re-resolve every family, prefetch hashes, rewrite the lock
just devdocs-lock openjdk   # or just one/a few families
just devdocs-check          # hermetic pipeline test before relying on the result
```

**`downloads.devdocs.io` is not content-addressed and upstream rebuilds a doc in place** —
unlike every other pinned artifact in this repo (GitHub release assets, npm tarballs,
Camoufox zips), the pinned hash can stop fetching once upstream moves on, because the old
bytes are simply gone. `docs.lock.json`'s `mtime` field is the only warning signal
(`just devdocs-list` diffs it against upstream); R2 is what makes a stale lock harmless in
practice — once a doc is built and pushed there, a machine substituting from the cache never
touches `downloads.devdocs.io` at all.

**`documents.devdocs.io` needs a real User-Agent for `--online` fetches.** Cloudflare returns
403 to Python's default `Python-urllib/…` UA on some (not all) paths while `curl` with no UA
at all gets 200 — the same class of block `nix-cache-prune.py` already documents against
narinfo fetches. `devdocs-cli.py`'s `fetch_online()` sets `User-Agent: Mozilla/5.0`.

