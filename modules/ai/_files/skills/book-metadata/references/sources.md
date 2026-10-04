# Metadata sources

SPDX-License-Identifier: GPL-3.0-only. Summarized from the calibre sources at commit
`d0bb2b18a66930507c4f5c2baf988840b5564704`
(<https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/metadata/sources>), checked
against calibre 9.9 on 2026-10-04. Every result needs verification; see `SKILL.md`.

| Source (`--source`) | Default | Delivers | How it works | Notes |
|---|---|---|---|---|
| `Google` | enabled | title, authors, ISBN, publisher, date, language, tags, description, cover | Atom feed `books.google.com/books/feeds/volumes`, then a details request per hit; web-search fallback | Answers HTTP 5xx now and then (the helper retries). Often a different edition than the one you hold |
| `Amazon.com` | enabled | most fields incl. series, rating, cover | Scrapes product pages, several country sites; can fall back to a search engine | Captcha pages; the fallback may land on unrelated pages. Largest and most fragile plugin |
| `Open Library` | enabled | cover only | `covers.openlibrary.org/b/isbn/<isbn>-L.jpg` | Needs an ISBN. Returns no metadata |
| `Google Images` | disabled | cover only | Scrapes Google image search | Enable with `plugins enable "Google Images"` |
| `Edelweiss` | disabled | title, authors, publisher, description, cover | Scrapes `edelweiss.plus` | Returned nothing in tests |

Lookups merge the answers of all enabled sources; with an ISBN calibre prefers hits that carry it.

## Further plugins

`plugins search <term>` lists the official index (category "Metadata Source", 54 entries on
2026-10-04), for example `DNB_DE` (German National Library), `Goodreads`, `Kobo Metadata`,
`OpenLibraryPlus`, `Hardcover`, `Wikidata`. Plugins are community code with their own licenses and
maintainers; read the plugin's thread before you install one.
