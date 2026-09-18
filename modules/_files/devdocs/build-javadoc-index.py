"""Build one +devdocs SQLite index from a standard javadoc-tool output tree,
delivered as a Maven Central javadoc jar, an aggregated "docs" zip (Spring
Framework's framework-api:docs, Spring Boot's spring-boot-docs:
api-catalog-content), the Gradle docs.zip, or a plain directory (kept for the
hermetic test fixture, which needs no zip machinery to build one).

Runs at NIX BUILD TIME inside modules/devdocs.nix's `mkJavadocDoc` derivation.
See javadoc_index.py's module docstring for the on-disk format parsed here,
and devdocs_sqlite.py's for the schema/compression this writes into.

Exits non-zero -- refusing to emit an empty/near-empty doc -- when
member-search-index.js or type-search-index.js is absent. MEASURED:
commons-math3:3.6.1 (2016) and commons-digester3:3.2 (2011) predate JEP 225
and ship pre-modular, frames-based javadoc with no search index at all; a doc
silently built from either would install cleanly and answer every query with
"no match", which is a worse failure mode than refusing to build.
"""
import argparse
import json
import os
import sys
import zipfile

from devdocs_sqlite import IndexWriter
from javadoc_index import (
    anchor_kinds, class_html_relpath, class_kind, member_anchor, member_name,
    package_html_relpath, parse_search_index, store_path_for_package,
    store_path_for_type, strip_to_main,
)

LICENSE_NAME_PATTERNS = ("LICENSE", "LICENSE.txt", "LICENSE.md", "NOTICE", "NOTICE.txt")


class _ZipArchive:
    def __init__(self, path):
        self._zf = zipfile.ZipFile(path)
        self._names = set(self._zf.namelist())

    def read_optional(self, relpath):
        if relpath not in self._names:
            return None
        return self._zf.read(relpath)

    def names(self):
        return self._names

    def close(self):
        self._zf.close()


class _DirArchive:
    """Reads a plain directory tree the same way -- used by the hermetic
    test fixture, which builds one on disk directly rather than a zip."""

    def __init__(self, path):
        self._root = path

    def read_optional(self, relpath):
        p = os.path.join(self._root, relpath)
        if not os.path.isfile(p):
            return None
        with open(p, "rb") as f:
            return f.read()

    def names(self):
        out = []
        for dirpath, _dirs, files in os.walk(self._root):
            rel = os.path.relpath(dirpath, self._root)
            for fn in files:
                out.append(fn if rel == "." else f"{rel}/{fn}")
        return out

    def close(self):
        pass


def open_archive(path):
    if os.path.isdir(path):
        return _DirArchive(path)
    return _ZipArchive(path)  # zipfile also opens .jar transparently (same container format)


def joined(subdir, relpath):
    return f"{subdir}/{relpath}" if subdir else relpath


def build(archive_path, subdir, slug, family, release, license_, license_url,
          attribution, source_url, sqlite_path, licenses_out):
    archive = open_archive(archive_path)
    try:
        member_raw = archive.read_optional(joined(subdir, "member-search-index.js"))
        type_raw = archive.read_optional(joined(subdir, "type-search-index.js"))
        if member_raw is None or type_raw is None:
            sys.exit(
                f"{family} ({source_url}): no member-search-index.js / "
                f"type-search-index.js found under subdir={subdir!r}. This javadoc "
                f"build predates JEP 225 (pre JDK 9), or --subdir is wrong -- "
                f"refusing to build an index that would silently answer every "
                f"query with 'no match'."
            )
        package_raw = archive.read_optional(joined(subdir, "package-search-index.js")) or b""

        types = parse_search_index(type_raw.decode("utf-8"), "typeSearchIndex")
        members = parse_search_index(member_raw.decode("utf-8"), "memberSearchIndex")
        packages = parse_search_index(package_raw.decode("utf-8"), "packageSearchIndex") if package_raw.strip() else []

        writer = IndexWriter()
        page_kinds = {}  # store_path -> {anchor: kind}, cached per class page
        page_by_pc = {}  # (package, class-label) -> store_path, for member linkup
        types_seen = {}  # entries.type name -> count, for the `types` table
        missing_anchors = []
        missing_pages = []

        for e in types:
            store_path = store_path_for_type(e)
            if store_path is None:
                continue  # synthetic row, e.g. "All Classes and Interfaces"
            html_bytes = archive.read_optional(joined(subdir, class_html_relpath(e)))
            if html_bytes is None:
                missing_pages.append(class_html_relpath(e))
                continue
            main_html, _complete = strip_to_main(html_bytes.decode("utf-8", errors="replace"))
            writer.add_page(store_path, main_html)
            kind = class_kind(main_html)
            writer.add_entry(e["l"], store_path, anchor=None, type_=kind)
            types_seen[kind] = types_seen.get(kind, 0) + 1
            page_kinds[store_path] = anchor_kinds(main_html)
            page_by_pc[(e["p"], e["l"])] = store_path

        for e in packages:
            store_path = store_path_for_package(e)
            if store_path is None:
                continue  # synthetic row, e.g. "All Packages"
            html_bytes = archive.read_optional(joined(subdir, package_html_relpath(e)))
            if html_bytes is None:
                missing_pages.append(package_html_relpath(e))
                continue
            main_html, _complete = strip_to_main(html_bytes.decode("utf-8", errors="replace"))
            writer.add_page(store_path, main_html)
            writer.add_entry(e["l"], store_path, anchor=None, type_="Package")
            types_seen["Package"] = types_seen.get("Package", 0) + 1

        for e in members:
            pc = (e.get("p"), e.get("c"))
            store_path = page_by_pc.get(pc)
            if store_path is None:
                missing_pages.append(f"{pc[0]}.{pc[1]}" if pc[0] else str(pc[1]))
                continue
            anchor = member_anchor(e)
            kind = page_kinds.get(store_path, {}).get(anchor)
            if kind is None:
                # index.json-equivalent (the search index) promised this
                # anchor, but the anchor scanner never saw a matching
                # <section class="detail" id="..."> on that page's <main>.
                # Degrade gracefully -- see build-javadoc-index.py's module
                # docstring for why an empty doc is worse than a doc missing
                # a handful of entries.
                missing_anchors.append(f"{store_path}#{anchor}")
                continue
            writer.add_entry(member_name(e), store_path, anchor=anchor, type_=kind)
            types_seen[kind] = types_seen.get(kind, 0) + 1

        for name, count in sorted(types_seen.items()):
            writer.add_type(name, name.lower().replace(" ", "-"), count)

        os.makedirs(licenses_out, exist_ok=True)
        copied_licenses = []
        for name in archive.names():
            base = name.rsplit("/", 1)[-1]
            if base in LICENSE_NAME_PATTERNS:
                data = archive.read_optional(name)
                if data is None:
                    continue
                dest = os.path.join(licenses_out, base.replace("/", "_"))
                with open(dest, "wb") as f:
                    f.write(data)
                copied_licenses.append(name)
        with open(os.path.join(licenses_out, f"{slug}-DECLARED-LICENSE.txt"), "w", encoding="utf-8") as f:
            f.write(
                f"slug: {slug}\nfamily: {family}\nsource: {source_url}\n"
                f"license: {license_}\nlicense_url: {license_url}\n"
                f"attribution: {attribution}\n"
            )

        meta = {
            "slug": slug,
            "family": family,
            "name": family,
            "release": release,
            "mtime": "",
            "features": json.dumps({"names": True, "content": False}),
            "source_kind": "javadoc",
            "source_url": source_url,
            "license": license_,
            "license_url": license_url,
            "attribution": attribution,
            "missing_anchors": json.dumps(missing_anchors),
            "missing_pages": json.dumps(missing_pages),
        }
        writer.finish(sqlite_path, meta)

        if missing_anchors:
            print(f"warning: {slug}: {len(missing_anchors)} member(s) had no matching "
                  f"HTML anchor, skipped: {missing_anchors[:5]}"
                  f"{'...' if len(missing_anchors) > 5 else ''}", file=sys.stderr)
        if missing_pages:
            print(f"warning: {slug}: {len(missing_pages)} referenced page(s) were not "
                  f"found in the archive, skipped: {missing_pages[:5]}"
                  f"{'...' if len(missing_pages) > 5 else ''}", file=sys.stderr)
    finally:
        archive.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--archive", required=True, help="jar/zip file, or a directory")
    p.add_argument("--subdir", default="", help='path prefix inside the archive, e.g. "javadoc-api"')
    p.add_argument("--slug", required=True)
    p.add_argument("--family", required=True)
    p.add_argument("--release", default="")
    p.add_argument("--license", dest="license_", required=True)
    p.add_argument("--license-url", default="")
    p.add_argument("--attribution", default="")
    p.add_argument("--source-url", required=True)
    p.add_argument("--sqlite", required=True)
    p.add_argument("--licenses-out", required=True)
    args = p.parse_args()
    build(args.archive, args.subdir.strip("/"), args.slug, args.family, args.release,
          args.license_, args.license_url, args.attribution, args.source_url,
          args.sqlite, args.licenses_out)


if __name__ == "__main__":
    main()
