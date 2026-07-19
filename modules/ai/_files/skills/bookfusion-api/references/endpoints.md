# BookFusion API — command reference

All 64 wrapped commands (2 endpoints are intentionally excluded — see bottom). Command name = the
OpenAPI `operationId`. Full request/response schemas are in [`openapi.yaml`](openapi.yaml).

Invoke as: `bookfusion <command> [--<pathparam> V ...] [--data '<json>'] [--pretty] [--dangerous]`
For many writes in one login, pipe JSONL ops into `bookfusion batch` (see [`SKILL.md`](../SKILL.md#bulk-changes--batch-one-login-one-jvm)).

## Danger tiers
- **SAFE** — reads/searches. Default-allowed. This is what replaces web scraping.
- **WRITE** — non-destructive mutations (create/update, upload, reading position, kindle, borrow, join/leave). Default-allowed.
- **DANGEROUS** — destructive/irreversible-scoped. **Requires `--dangerous`** or the call is refused (exit 4).
- **EXCLUDED** — not wrapped at all (payment / account-integrity). No account-delete endpoint exists in the API.

## Request bodies for `/search` commands
Search/list endpoints are `POST` with a JSON body. Common fields (see each schema in `openapi.yaml`,
components `*SearchRequest`): `query` (string), `page` (int), `per_page` (int), sometimes `sort`,
`ids` (int array), `cursor`/`limit`. Example:
```
bookfusion searchUserBooks --data '{"query":"kubernetes","page":1,"per_page":20}' --pretty
```
Commands marked `body = —` take no body (the app sends none); just call them without `--data`.

## Multipart commands
`createHighlight`, `updateUserBook`, `finalizeBookUpload`, `updateUserProfile` use `multipart/form-data`:
`--data` supplies the JSON `payload` part; `--file PATH` supplies the binary part (`binary` for
`createHighlight`, `file` for the others). Book **covers** are a separate part named `cover` — use
`--cover PATH` (NOT `--file`, which the server ignores for covers). Example:
```
bookfusion updateUserProfile --data '{"full_name":"Jane Doe"}'
bookfusion updateUserBook --dangerous --id 123 --cover cover.jpg --data '{}'   # set/replace a cover
```

## Uploading a book (init → finalize), with auto-cover
`finalizeBookUpload` requires `digest` (the file's content hash), not an `upload_id`. High-level helper
`uploadBook` runs the whole flow and, by DEFAULT, renders + sets a first-page cover when the format has
none (PDF/CHM/DJVU/…). EPUB/MOBI/AZW3 get a cover server-side, so no render is done for them.
```
bookfusion uploadBook --file book.pdf --title "My Book"      # upload + auto-cover (macOS qlmanage/sips)
bookfusion uploadBook --file book.pdf --cover my.jpg          # supply the cover image yourself
bookfusion uploadBook --file book.epub                        # no render; EPUB auto-covers
bookfusion uploadBook --file book.pdf --no-cover              # skip the cover
```
Manual primitives (out-of-band byte upload) still work:
```
# 1) init returns { url, params, action } describing where to POST the file
bookfusion initBookUpload --data '{"filename":"book.epub","digest":"<sha256>","file_size":123456,"type":"book"}'
# 2) POST the bytes to that target (out of band), then finalize with the SAME digest:
bookfusion finalizeBookUpload --data '{"key":"<uploadKey>","digest":"<sha256>","title":"My Book"}'
# 3) for a cover-less format, set a cover afterwards:
bookfusion updateUserBook --dangerous --id <id> --cover ./cover.jpg --data '{}'
```
Cover details & the "cover"-vs-"file" gotcha: [`references/covers.md`](covers.md).

## Bookshelves & series: assign by id, not name
`bookshelf_ids` / `category_ids` take integer **ids**, and there is no assign-by-name. Recipe:
1. `searchBookshelves --data '{"query":"Work"}'` (or `createBookshelf --data '{"name":"Work"}'`) → the id.
   `createSeries` / `createBookshelf` need a `creation_token`; omit it and the CLI auto-generates one.
2. Read the book's current `bookshelves[].id` (via `searchUserBooks`), because `updateUserBook` **replaces**
   the whole set (see [`SKILL.md`](../SKILL.md) "Editing book metadata").
3. `updateUserBook --id <book> --dangerous --data '{"bookshelf_ids":[<existing...>,<newId>]}'`.
For many such edits, pipe JSONL into `bookfusion batch --dangerous` (one login).

## Full command table

| Command (operationId) | Method | Path | Tier | Path params | Body |
|---|---|---|---|---|---|
| `deleteBookBookmark` | POST | `/api/v2/library/books/{number}/bookmarks/{id}/delete` | DANGEROUS | `number`, `id` | — |
| `deleteBookshelf` | DELETE | `/api/user/bookshelves/{id}` | DANGEROUS | `id` | — |
| `deleteHighlight` | DELETE | `/api/user/highlights/{id}` | DANGEROUS | `id` | — |
| `deleteReaderPreset` | DELETE | `/api/user/reader_presets/{id}` | DANGEROUS | `id` | — |
| `deleteSeries` | DELETE | `/api/user/series/{id}` | DANGEROUS | `id` | — |
| `deleteUserBook` | DELETE | `/api/user/books/{id}` | DANGEROUS | `id` | — |
| `updateUserBook` | PATCH | `/api/user/books/{id}` | DANGEROUS | `id` | multipart |
| `authChallenge` | GET | `/api/v3/auth/challenge` | SAFE | — | (query `--email`) |
| `checkBorrowBook` | GET | `/api/user/libraries/books/{book_id}/borrow` | SAFE | `book_id` | — |
| `getBookReadingPosition` | GET | `/api/user/books/{number}/reading_position` | SAFE | `number` | — |
| `getLibraryMemberships` | GET | `/api/user/libraries/membership` | SAFE | — | — |
| `getReaderSubscription` | GET | `/api/user/reader_subscription` | SAFE | — | — |
| `getReaderSubscriptionPricing` | GET | `/api/user/reader_subscription/pricing` | SAFE | — | — |
| `getRelatedLibraryBooks` | GET | `/api/user/libraries/books/{book_id}/related_books` | SAFE | `book_id` | — |
| `getTtsCredentials` | POST | `/api/user/tts` | SAFE | — | — |
| `getUser` (alias `whoami`) | GET | `/api/v1/user` | SAFE | — | — |
| `listBookBookmarks` | GET | `/api/v2/library/books/{number}/bookmarks` | SAFE | `number` | — |
| `listHighlightColors` | GET | `/api/user/highlights/colors` | SAFE | — | — |
| `listHighlightExportFormats` | GET | `/api/user/highlights/export/formats` | SAFE | — | — |
| `listHighlightTags` | GET | `/api/user/highlights/tags` | SAFE | — | — |
| `searchAuthors` | POST | `/api/user/authors/search` | SAFE | — | json |
| `searchBookshelves` | POST | `/api/user/bookshelves/search` | SAFE | — | — |
| `searchCategories` | POST | `/api/user/categories/search` | SAFE | — | — |
| `searchHighlightAuthors` | POST | `/api/user/highlights/authors/search` | SAFE | — | json |
| `searchHighlightCategories` | POST | `/api/user/highlights/categories/search` | SAFE | — | — |
| `searchHighlightTags` | POST | `/api/user/highlights/tags/search` | SAFE | — | json |
| `searchHighlights` | POST | `/api/user/highlights/search` | SAFE | — | json |
| `searchLibraries` | POST | `/api/user/libraries/search` | SAFE | — | json |
| `searchLibraryAuthors` | POST | `/api/user/libraries/{slug}/authors/search` | SAFE | `slug` | json |
| `searchLibraryBookListBooks` | POST | `/api/user/libraries/book_lists/{categoryId}/books/search` | SAFE | `categoryId` | json |
| `searchLibraryBookLists` | POST | `/api/user/libraries/{slug}/book_lists/search` | SAFE | `slug` | json |
| `searchLibraryBooks` | POST | `/api/user/libraries/{slug}/books/search` | SAFE | `slug` | json |
| `searchLibraryCategories` | POST | `/api/user/libraries/{slug}/categories/search` | SAFE | `slug` | — |
| `searchLibraryTags` | POST | `/api/user/libraries/{slug}/tags/search` | SAFE | `slug` | json |
| `searchReaderPresets` | POST | `/api/user/reader_presets/search` | SAFE | — | — |
| `searchSeries` | POST | `/api/user/series/search` | SAFE | — | json |
| `searchSeriesBooks` | POST | `/api/user/series/{id}/books/search` | SAFE | `id` | json |
| `searchTags` | POST | `/api/user/tags/search` | SAFE | — | json |
| `searchUserBooks` | POST | `/api/user/books/search` | SAFE | — | json |
| `addBookBookmark` | POST | `/api/v2/library/books/{number}/bookmarks` | WRITE | `number` | json |
| `authFacebook` | POST | `/api/v3/auth/facebook` | WRITE | — | json |
| `authGoogle` | POST | `/api/user/auth/google` | WRITE | — | json |
| `authenticate` | POST | `/api/v3/auth.json` | WRITE | — | json |
| `borrowBook` | POST | `/api/user/libraries/books/{book_id}/borrow` | WRITE | `book_id` | — |
| `createBookshelf` | POST | `/api/user/bookshelves` | WRITE | — | json |
| `createHighlight` | POST | `/api/user/highlights` | WRITE | — | multipart |
| `createReaderPreset` | POST | `/api/user/reader_presets` | WRITE | — | json |
| `createSeries` | POST | `/api/user/series` | WRITE | — | json |
| `exportHighlights` | POST | `/api/user/highlights/export` | WRITE | — | json |
| `finalizeBookUpload` | POST | `/api/user/uploads/finalize` | WRITE | — | multipart |
| `initBookUpload` | POST | `/api/user/uploads/init` | WRITE | — | json |
| `joinLibrary` | POST | `/api/v3/libraries/{slug}/join` | WRITE | `slug` | — |
| `leaveLibrary` | POST | `/api/v3/libraries/{slug}/leave` | WRITE | `slug` | — |
| `sendBookToKindle` | POST | `/api/v1/library/books/{number}/kindle` | WRITE | `number` | — |
| `signup` | POST | `/api/v3/signup` | WRITE | — | json |
| `trackBookReadingTime` | POST | `/api/v1/library/books/{number}/track_time` | WRITE | `number` | json |
| `updateAuthToken` | POST | `/api/v3/auth/token` | WRITE | — | json |
| `updateBookReadingPosition` | POST | `/api/user/books/{number}/reading_position` | WRITE | `number` | json |
| `updateBookshelf` | PATCH | `/api/user/bookshelves/{id}` | WRITE | `id` | json |
| `updateHighlight` | PATCH | `/api/user/highlights/{id}` | WRITE | `id` | json |
| `updateProfileSettings` | POST | `/api/v1/profile/settings` | WRITE | — | json |
| `updateReaderPreset` | PATCH | `/api/user/reader_presets/{id}` | WRITE | `id` | json |
| `updateSeries` | PATCH | `/api/user/series/{id}` | WRITE | `id` | json |
| `updateUserProfile` | PATCH | `/api/user/profile` | WRITE | — | multipart |

**Excluded (intentionally not wrapped):** `createReaderSubscription` (`POST /api/user/reader_subscription` — payment) and `disconnectFacebook` (`POST /api/v1/profile/facebook/disconnect` — can strand account access).
