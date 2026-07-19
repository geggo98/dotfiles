# Book covers — how they work in the BookFusion API

Verified live 2026-07-19 while bulk-uploading ~3,600 books.

## Which uploads get a cover automatically

BookFusion extracts a cover server-side **only from Kindle/EPUB formats** that carry an embedded
cover image:

| Format | Auto-cover on upload? |
|--------|-----------------------|
| EPUB, MOBI, AZW3 (and AZW) | **Yes** — extracted automatically at upload |
| PDF, CHM, DJVU, PRC, CBZ/CBR, FB2, … | **No** — the book is created cover-less |

So a bulk upload of PDFs/comics lands ~all of them without covers.

## Setting a cover after upload (the working mechanism)

Endpoint: `PATCH /api/user/books/{id}` (`updateUserBook`), `multipart/form-data`.

The decisive detail, found the hard way:

- The cover image MUST be sent as a part named **`cover`**.
- The OpenAPI part named **`file`** (what the spec listed and the CLI sent by default) is **silently
  ignored** for covers: the request returns **HTTP 200** and the book JSON, but `cover` stays `null`.
- The `payload` part (the JSON body) may be empty `{}` — a cover-only update needs no other fields.
- Content-Type of the `cover` part should be an image type (`image/jpeg` / `image/png`). Sending it as
  `application/octet-stream` also failed to register; `image/jpeg` works. (An `image/jpeg` part sent
  under the wrong field name, or a malformed multipart, can even 500.)

Minimal working multipart:

```
--BOUNDARY
Content-Disposition: form-data; name="payload"
Content-Type: application/json

{}
--BOUNDARY
Content-Disposition: form-data; name="cover"; filename="cover.jpg"
Content-Type: image/jpeg

<JPEG bytes>
--BOUNDARY--
```

Auth headers are the usual ones (`X-Token`, `X-Device`, `Accept: application/json; api_version=10`,
`X-Client`). Verified: setting a 500×750 image made the book's `cover.width/height` become 500×750.

### CLI usage

```
bookfusion updateUserBook --dangerous --id <BOOK_ID> --cover cover.jpg --data '{}'
```

`--cover PATH` attaches the image as the `cover` part (see `multipartBody` in `bookfusion.main.kts`).
In `batch` JSONL, add a `"cover":"/path/img.jpg"` key to the op object.

## Default cover on upload — `uploadBook`

`uploadBook` runs the whole flow (init → S3 → finalize) and, **by default, renders a first-page cover
and sets it when the format would otherwise have none**:

```
bookfusion uploadBook --file book.pdf --title "My Book"     # auto-covers (PDF has no embedded cover)
bookfusion uploadBook --file book.epub                       # no render — EPUB auto-covers server-side
bookfusion uploadBook --file book.pdf --cover my.jpg         # use a specific cover image
bookfusion uploadBook --file book.pdf --no-cover             # skip cover entirely
```

Rendering is **macOS-only** and uses Quick Look → `sips`:
`qlmanage -t -s 1200 -o <tmp> <file>` produces a PNG of the first page, then `sips` converts it to
JPEG (falls back to `sips -s format jpeg -Z 1200` directly). If neither tool is present (non-macOS),
`uploadBook` finalizes without a cover and prints a note; pass `--cover PATH` to supply one yourself.

Quick Look reliably rasterizes PDF and CBZ/CBR comics. CHM/DJVU/PRC usually have no Quick Look
generator and render to nothing → those stay cover-less (reported, not fatal).

## Implementation pointers (`scripts/bookfusion.main.kts`)

- `multipartBody(payload, filePath, partName, coverPath)` — `coverPath` adds the `cover` image part.
- `dispatch` / `parseBatchLine` — thread `--cover` / `"cover"` through for any multipart command.
- `doUploadBook` — high-level orchestration + `renderFirstPageCover` (qlmanage/sips) + `s3PostForm`.
- `AUTO_COVER_FMT = {epub, mobi, azw3, azw}` — formats that get a cover without rendering.
