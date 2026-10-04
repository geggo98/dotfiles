# Upstream

This skill is a wrapper around a tool of the calibre project. It is authored
here, and it copies no calibre source code. It runs the installed
`fetch-ebook-metadata`, `calibre-customize` and `calibre-debug` programs.

| Field | Value |
|---|---|
| Source | https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/metadata/sources |
| Reviewed commit | `d0bb2b18a66930507c4f5c2baf988840b5564704` |
| Reviewed at | 2026-10-04 |
| Tested with | calibre 9.9 (Homebrew cask `calibre`) |
| Upstream license | GPL-3.0 (`LICENSE` in this directory is the upstream text at the commit above) |
| License of this skill | GPL-3.0-only — the repo root's CC0 does not extend to this directory |

## Why GPL-3.0

`scripts/book_metadata.py` runs code inside calibre's own interpreter
(`calibre-debug -c`) to download the plugin index, and `references/sources.md`
describes the behavior of the calibre plugins. Taking the strict license avoids
a question about whether that counts as a derived work.

## What was reviewed

Files in `src/calibre/ebooks/metadata/sources/` at the commit above:
`google.py`, `google_images.py`, `amazon.py`, `edelweiss.py`, `openlibrary.py`,
`base.py`, `identify.py`, `covers.py`, `search_engines.py`, `update.py`,
`cli.py`. `references/sources.md` summarizes the endpoints and fields they use.
Re-check that file against upstream when calibre ships a new major version.

The list of installable plugins comes from the official index at
`https://code.calibre-ebook.com/plugins/plugins.json.bz2` (category
"Metadata Source", 54 entries on 2026-10-04). Plugins installed from there are
third-party code. This skill never installs one without an explicit `--yes`.
