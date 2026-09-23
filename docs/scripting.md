# Script style and resumable scripts — full incident reports

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

### Script style (shell, Python, regex)

macOS ships a BSD userland. GNU tools exist only inside the devenv shell or under
`g`-prefixed names, and are on `PATH` only if someone installed them. Anything that
runs outside a Nix wrapper must not assume either flavour.

- **Short scripts → zsh** (`#!/bin/zsh`), not bash. zsh is the macOS default login
  shell and a current release; `/bin/bash` is frozen at 3.2 (2007), so no associative
  arrays, `${var@Q}`, `readarray`, or `wait -n`. zsh also does not word-split
  unquoted parameters, which removes a whole class of quoting bugs.
- **Longer scripts → `python3` with a PEP-723 `uv` header**, stdlib-preferred. Once a
  script grows argument parsing, JSON handling, or more than a couple of branches, the
  shell version stops being readable or testable. See "uv-based skill scripts" below
  for the `--frozen` and lockfile rules.
- **Prefer a `perl` one-liner to `sed` / `awk` / `grep` / `cut` / `tr`** wherever
  performance allows. Perl is in the macOS base system, implements `-i`, `-n`, `-p`
  and PCRE itself, and behaves identically on macOS and Linux. The alternatives all
  diverge between BSD and GNU. Reach for the GNU tool only when data volume makes
  Perl's throughput or startup the bottleneck.

  | Instead of | Write |
  |---|---|
  | `grep -o` / `sed -n 's/…/\1/p'` | `perl -ne 'print $+{x} if /(?<x>…)/'` |
  | `sed -i'' -e 's/a/b/'` | `perl -i -pe 's/a/b/'` |
  | `awk -F'\t' '{print $4}'` | `perl -F'\t' -lane 'print $F[3]'` |
  | `grep -c` | `perl -ne '$n++ if /…/; END { print $n // 0 }'` |

  The `sed` row is not hypothetical: BSD `sed` reads `-i'' -e` as "backup extension
  `-e`" and silently leaves a stale `file-e` beside the real one. Perl implements
  `-i` itself, so the divergence is gone at the root rather than worked around. See
  the comment on the `brew-bump` recipe in the `justfile`.

- **Regex: named capture groups** wherever the syntax supports them — `(?<name>…)`
  with `$+{name}` in Perl, `(?P<name>…)` with `m["name"]` in Python. The name is free
  documentation, and the pattern keeps working when someone inserts a group ahead of
  it. Fall back to positional `$1`/`\1` only where there is no named form (POSIX
  BRE/ERE, `sed`, bash's `BASH_REMATCH`).
- **Regex: complex patterns go multi-line and commented** — `/x` in Perl,
  `re.VERBOSE` in Python — once a pattern carries more than one capture, a
  lookaround, or an alternation that no longer fits on one readable line.
- **Regex: always show a concrete example** of a line the pattern must match, in a
  comment directly above it. It lets the next reader check the pattern without
  running it, and it is the first thing to update when the input format drifts.

  ```perl
  # matches:     url = "github:Homebrew/brew/6.0.17";   ->  $+{tag} eq "6.0.17"
  m{^ \s* url \s* = \s* "github:Homebrew/brew/(?<tag>[^"]+)"; \s* $}x
  ```

- **Carve-out — `pkgs.writeShellApplication` stays bash.** It is a bash-only
  nixpkgs builder with no zsh counterpart, and what it buys is worth the exception:
  `shellcheck` runs over the source, `set -euo pipefail` is injected, and every tool
  in `runtimeInputs` resolves to a pinned store path, so the BSD/GNU question is
  settled at build time. ~20 call sites (`modules/mcp-servers.nix`,
  `modules/vault.nix`, `modules/nix-tarball-cache-repack.nix`, …) rely on this.
- **Other Nix-built scripts use zsh.** `writeShellScriptBin` hardcodes bash and gives
  none of the above, so prefer `writeTextFile` with an explicit
  `#!${pkgs.zsh}/bin/zsh` — pinned, not `/bin/zsh`, so the interpreter is fixed like
  every other tool. See `mkZshScript` in `modules/nix-cache.nix`.
- **`justfile` shebang recipes use `#!/bin/zsh`** + `set -euo pipefail` (zsh accepts
  it verbatim), and follow the perl and regex rules above for text processing.
  Non-shebang recipes still run under just's default `sh -cu`.

  **When converting bash → zsh, the trap is word splitting.** zsh does *not* split
  unquoted parameters — the property this whole section praises it for — so any code
  that relied on `$VAR` expanding to several arguments silently collapses to one.
  Use `${=VAR}` there. It bit the R2 post-build hook, whose `$OUT_PATHS` is a
  space-separated path list; measured, `V="x y z"; set -- $V` gives `argc=1` under
  zsh against `3` under bash. Everything else in this repo converted unchanged —
  `read -r a b c <<<`, arrays with spaces, `"${arr[@]}"`, empty arrays under
  `set -u`, globs in `[[ ]]`, and `[[ =~ ^[0-9a-f]{64}$ ]]`.

### Any script that processes a list must be resumable

Long-running batch work here gets interrupted — a quota fills, a link drops, a
deploy times out, someone hits Ctrl-C. A script that cannot be re-run without
thought turns every interruption into an investigation. Four rules, each of
which was paid for.

- **Classify every item as SUCCESS, SKIP, ERROR or CLEANUP, and never collapse
  two of them.** A skip is not a failure. Reported together they make the summary
  worthless and the resume decision impossible.

  Paid for on 2026-08-20 while decoding 204 `.otrkey` files: the wrapper treated
  any non-zero exit from the decoder as an error, so `output file "…" exists,
  skipping` — the tool correctly declining to redo finished work — was counted as
  a failure. Two consecutive runs reported "142 failed" and then "148 failed"
  while the number of finished files rose. Neither number meant anything, and the
  list of "failures" driving the next run was garbage. When wrapping a foreign
  tool, map its exit codes and messages deliberately; `|| fail` is where the
  distinction dies.

- **Derive state from the work products, not from a file the script wrote.** A
  progress file, a failed-list, a marker — all of them are missing exactly when
  the run died badly, which is the case they exist for. Ask the filesystem, the
  bucket, the database: does the output for this item exist and is it valid?

- **"The output file exists" is a weak predicate. Prefer "the output verifies".**
  An interrupted write leaves a file that looks finished. In the same incident, a
  quota hit mid-write left truncated outputs behind; the next run saw them, said
  "exists, skipping", and would have deleted the corresponding inputs had it been
  told to. Where a checksum is available — a hash in a header, a manifest, `restic
  check` — that is the resume predicate. Where none exists, at least compare size
  against the expected value.

- **Publish results atomically: write to a temporary name in the same directory,
  `fsync` if it matters, then `mv` into place.** A rename within one filesystem is
  atomic, so an interrupted run leaves a stray temp file — obvious, harmless,
  cleanable — instead of a plausible-looking corpse under the real name. This is
  what makes the previous rule work: if only complete outputs ever carry the final
  name, "exists" becomes trustworthy again. Clean stale temp files at start-up and
  count that as CLEANUP.

Two additions that follow from the same reasoning:

- **Make the summary self-describing.** Print all four counts every run, plus what
  a re-run would do. `62 ok, 142 failed` invites the wrong conclusion; `62 done,
  142 skipped (already complete), 0 errors — nothing left to do` ends the
  conversation.
- **Use exit codes to distinguish "did work" from "nothing to do" from "failed".**
  A resumable script run twice must exit 0 the second time; anything else trains
  people to ignore its exit code.

