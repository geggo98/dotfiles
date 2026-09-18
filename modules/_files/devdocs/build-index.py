"""Build a single DevDocs SQLite index from an upstream offline tarball.

Runs at NIX BUILD TIME inside modules/devdocs.nix's `mkDoc` derivation, once
per doc. Stdlib-only Python (no PEP-723/uv header): there is nothing to lock,
and the interpreter is already pinned by the Nix derivation that runs this
script -- a second resolver (uv) would only cost startup time, and an agent
calls the resulting CLI dozens of times per task. Same reasoning and the same
precedent (modules/nix-cache.nix's nix-cache-drain.py, also stdlib-only and
Nix-assembled) as infra/scripts/osv-audit.py: "an auditing tool that installs
dependencies to run has a supply chain of its own".

Tarball layout (measured against real DevDocs releases, not assumed):
    index.json  {"entries": [{"name","path","type"}, ...], "types": [...]}
    db.json     {"<page path>": "<html fragment>", ...}
    meta.json   {"name","slug","release","mtime","db_size","links"}

`path` in index.json is either a bare page path or "<page>#<anchor>", and the
anchor is an EXACT signature for javadoc-shaped docs (e.g. "add(int,E)") that
must survive byte-for-byte: no unescaping, no case-folding, no URL-decoding.
That property is what makes anchor-scoped lookup work at all in +devdocs.

The actual SQLite schema, compression scheme, and per-doc preset-dictionary
training now live in devdocs_sqlite.py's IndexWriter, shared with the
Maven-javadoc, Gradle, and Valkey builders (modules/_files/devdocs/
build-javadoc-index.py, build-redis-index.py) added alongside this one --
see that module's docstring for the schema DDL and the compression
measurement. This script's own job is purely DevDocs' tarball format: parse
index.json/db.json/meta.json and feed the result to IndexWriter.
"""
import argparse
import json
import re
import sys
import tarfile

from devdocs_sqlite import IndexWriter, fts5_available


def iter_json_object(fileobj):
    """Stream-parse a top-level JSON object as (key, raw_value) pairs without
    materializing the whole structure in memory twice over. OpenJDK's db.json
    alone is ~115 MB of HTML; a plain json.load() there costs 4-6x that in
    Python objects, and Nix runs `max-jobs` of these builds concurrently, so
    peak memory across a fresh machine's build matters. Works because every
    top-level value in db.json is a JSON string with no further nesting: find
    the next `"key":`, hand the rest to json.JSONDecoder.raw_decode, repeat."""
    text = fileobj.read()
    if isinstance(text, bytes):
        text = text.decode("utf-8")
    decoder = json.JSONDecoder()
    key_re = re.compile(r'"((?:[^"\\]|\\.)*)"\s*:\s*')
    pos = text.index("{") + 1
    n = len(text)
    while True:
        while pos < n and text[pos] in " \t\r\n,":
            pos += 1
        if pos >= n or text[pos] == "}":
            return
        m = key_re.match(text, pos)
        if not m:
            raise ValueError(f"expected a JSON object key at offset {pos}")
        key = json.loads('"' + m.group(1) + '"')
        pos = m.end()
        value, pos = decoder.raw_decode(text, pos)
        yield key, value


def extract_member_optional(tf, *names):
    """Return the extracted file object for the first of `names` present in
    `tf`, or None if none exist. `TarFile.extractfile` RAISES KeyError on a
    missing member rather than returning None, so a naive
    `tf.extractfile(a) or tf.extractfile(b)` never reaches `b` -- the first
    call already threw. This tries each name in turn."""
    for name in names:
        try:
            member = tf.getmember(name)
        except KeyError:
            continue
        f = tf.extractfile(member)
        if f is not None:
            return f
    return None


def extract_member(tf, *names):
    f = extract_member_optional(tf, *names)
    if f is None:
        sys.exit(f"none of {names} found as a regular file in {tf.name}")
    return f


def build(tarball_path, slug, family, sqlite_path):
    if not fts5_available():
        sys.exit(
            "sqlite3 in this Python build has no FTS5 support. This does not "
            "break the current schema (FTS5 is unused by design -- see "
            "devdocs_sqlite.py's module docstring), but it means a future "
            "content-search layer cannot rely on it either. Failing the "
            "build so this is noticed here, not at CLI runtime."
        )

    tf = tarfile.open(tarball_path, mode="r:gz")
    try:
        index = json.load(extract_member(tf, "./index.json", "index.json"))
        # meta.json is informational only (name/release/mtime for the `meta`
        # table); a doc missing it still builds, just with thinner metadata.
        meta_member = extract_member_optional(tf, "./meta.json", "meta.json")
        meta_src = json.load(meta_member) if meta_member else {}

        db_member = extract_member(tf, "./db.json", "db.json")

        writer = IndexWriter()
        for path, html in iter_json_object(db_member):
            # DevDocs' own paths are already lowercase by convention (they
            # ARE the doc's public URL path); add_page() asserts this rather
            # than silently normalizing, so a violation is a loud build
            # failure naming the offending path, not a page that resolve_head
            # can only ever reach via suffix-match degradation.
            writer.add_page(path, html)

        for e in index.get("entries", []):
            page, sep, anchor = e["path"].partition("#")
            writer.add_entry(e["name"], page, anchor if sep else None, e.get("type"))

        for t in index.get("types", []):
            writer.add_type(t["name"], t.get("slug"), t.get("count"))

        meta = {
            "slug": slug,
            "family": family,
            "name": meta_src.get("name", slug),
            "release": meta_src.get("release", ""),
            "mtime": str(meta_src.get("mtime", "")),
            "features": json.dumps({"names": True, "content": False}),
        }
        writer.finish(sqlite_path, meta)
    finally:
        tf.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--tarball", required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--family", required=True)
    p.add_argument("--sqlite", required=True)
    args = p.parse_args()
    build(args.tarball, args.slug, args.family, args.sqlite)


if __name__ == "__main__":
    main()
