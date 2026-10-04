---
name: book-metadata
description: >-
  Look up book metadata (title, authors, publisher, date, language, description, tags, cover) by ISBN,
  title/author or identifier, using the calibre metadata sources through the `fetch-ebook-metadata`
  CLI. Also lists the installed sources and finds/installs further calibre metadata-source plugins.
  Use to fill in or correct metadata of a book, e.g. before updating it in BookFusion. Triggers on:
  book metadata, ISBN lookup, fetch cover, calibre metadata source, metadata plugin, fetch-ebook-metadata.
license: GPL-3.0-only
argument-hint: "fetch --isbn <isbn> [--format json|opf|bookfusion] [--cover PATH] | sources | plugins search|install|enable|disable|remove <name>"
allowed-tools: >-
  Bash(${CLAUDE_SKILL_DIR}/scripts/book-metadata.sh *)
  Read(references/*)
  Read
metadata:
  based-on: "https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/metadata/sources"
  upstream-commit: "d0bb2b18a66930507c4f5c2baf988840b5564704"
  upstream-license: GPL-3.0
dependencies: >-
  calibre (Homebrew cask `calibre`, provides fetch-ebook-metadata, calibre-customize, calibre-debug);
  uv for the helper script. No other packages.
---

# book-metadata

Wrapper around calibre's metadata download. It runs the installed `fetch-ebook-metadata` and turns the
OPF it prints into JSON. No calibre code is copied; source, commit and license are in
[`UPSTREAM.md`](UPSTREAM.md). Which source returns what: [`references/sources.md`](references/sources.md).

## WARNING: verify every result before you use it

Calibre returns the best *guess*, not a confirmed record. Active sources are scrapers and feeds that
match loosely. **Never write a result into a library unchecked.**

- **Wrong edition.** A hit often belongs to another edition of the same work (other publisher, other
  year, other ISBN, other description). Compare title, first author and language with what you know.
  Trust the ISBN and the description only if the publication year is within ±1 of the book you hold
  or the publisher matches.
- **Wrong book.** A title/author search can return a different book. Amazon may fall back to a search
  engine and land on unrelated pages. When it finds nothing, that is a normal outcome.
- **Look up by ISBN when you have it** (`--isbn`). It returns the description of exactly that edition.
  If some fields are missing, repeat with the ISBN instead of guessing.
- **Google answers HTTP 5xx now and then.** The helper retries (`--retries`, default 2) and does not
  report that as "no result". Exit 1 means every source answered and none matched.
- **Dates:** a month-only date arrives with an invented day (calibre uses the 15th). Treat the
  day as unknown.
- **Quote what you changed.** Show the user old and new values before an overwrite.

## Quick start
```bash
${CLAUDE_SKILL_DIR}/scripts/book-metadata.sh fetch --isbn 9780596007126 --cover /tmp/cover.jpg
${CLAUDE_SKILL_DIR}/scripts/book-metadata.sh fetch --title "Head First Design Patterns" --authors "Freeman" --source Google
${CLAUDE_SKILL_DIR}/scripts/book-metadata.sh sources
```
`fetch` takes about 5 s. Output formats: `json` (default), `opf` (calibre's raw output), `bookfusion`
(payload for `updateUserBook`: plain-text `summary`, two-letter `language`, `published_at` as a date).
Stderr of calibre goes to a temp file; its Chromium `ERROR:` lines are not errors.

Exit codes: `0` ok · `1` no result · `2` usage · `4` blocked (needs `--yes`, or cooldown) ·
`5` calibre failed · `127` calibre not installed.

## Sources
All plugins stay enabled as calibre ships them. `sources` shows each one and its state. By default
calibre enables Google, Amazon.com and Open Library (covers only, by ISBN); Google Images (covers only)
and Edelweiss are disabled. Enable one with `plugins enable "<name>"`, restrict a lookup with
`--source <name>` (repeatable).

## More plugins
```bash
${CLAUDE_SKILL_DIR}/scripts/book-metadata.sh plugins search DNB      # official index, 54 metadata sources
${CLAUDE_SKILL_DIR}/scripts/book-metadata.sh plugins install DNB_DE --yes
```
A plugin is third-party Python that runs with your user rights, so:
- **Ask the user before `install` and `remove`**, every time. `--yes` is the proof that you asked.
- `install` downloads and prints the SHA-256 first and refuses plugins younger than 14 days
  (`--allow-young` only with the user's explicit OK).
- Installed plugins live in `~/Library/Preferences/calibre/plugins`, outside Nix. They survive
  `just switch` and are not reproducible from this repo.
- The index is fetched through calibre's own HTTPS code, because plain `curl` fails on its certificate.

## With BookFusion
Use together with `Skill(bookfusion-api)`: fetch with `--format bookfusion`, **verify**, merge with
the book's current tags (arrays replace), then `updateUserBook --dangerous`. The recipe is in that skill.

## Editing this skill
Installed files are read-only links into the Nix store. Edit the source under
`~/.config/nix-darwin/modules/ai/_files/skills/book-metadata/` and apply with `just switch`.
Test: `zsh ${CLAUDE_SKILL_DIR}/tests/test.sh` (fake calibre, no network).
