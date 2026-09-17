"""Build a single DevDocs SQLite index from an upstream offline tarball.

Runs at NIX BUILD TIME inside modules/devdocs.nix's `mkDoc` derivation, once
per doc. Stdlib-only Python (no PEP-723/uv header): there is nothing to lock,
and the interpreter is already pinned by the Nix derivation that runs this
script — a second resolver (uv) would only cost startup time, and an agent
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

Compression: zlib with a per-doc PRESET DICTIONARY (zlib.compressobj(...,
zdict=...)), not plain zlib and not zstd/brotli. Measured on real OpenJDK/CSS/
man pages (800-page sample, `zstd --train` for the dictionary): zlib alone
compresses at a factor of 0.182, zstd -19 alone at 0.173, brotli -q11 alone at
0.147 -- but zlib -9 WITH a trained 32 KiB preset dictionary reaches 0.117,
and zstd -19 with the same dictionary only reaches 0.093. The win is the
shared dictionary, not the codec: DevDocs pages repeat navigation, headers,
footers and CSS classes across thousands of pages, and that is CROSS-page
redundancy no per-blob-independent codec (zlib, zstd or brotli alike, used
without a dictionary) can see. zlib's `zdict` closes nearly all of the gap to
zstd+dictionary while adding zero runtime dependencies -- it has been a
stdlib feature since Python 3.3, so `+devdocs` itself never needs to load a
zstd library to read what this script writes. Measured full-schema totals
across three docs (openjdk~25, css, man): zlib alone 0.307/0.296/0.377,
zlib+dict 0.222/0.193/0.274 -- roughly a quarter smaller, for free.

The dictionary itself is TRAINED by the `zstd` CLI (`zstd --train`, invoked
here via subprocess) purely as a build-time tool -- nothing about it is
zstd-specific at the storage layer, and no zstd runtime library is loaded.
Training needs `zstd` on PATH; the Nix derivation supplies it as a
nativeBuildInput for exactly this reason.
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import zlib

SCHEMA_VERSION = 1
DICT_SIZE = 32768  # DEFLATE's window is 32 KiB; a larger trained dict measured
# no improvement once truncated to this size, so train AT this size directly.
MIN_PAGES_FOR_DICT = 20  # below this, the sample is too small to train usefully
# and the absolute size saved is negligible; ship an empty dictionary instead.


def fts5_available():
    """Build-time guard, the +nix-query idiom: fail the BUILD with a message
    naming the cause, rather than shipping a +devdocs whose search silently
    misbehaves. FTS5 is not used by the shipped schema (see module docstring
    above) -- this only keeps the option open for a future body-search layer,
    exactly as ai-tools.nix's nixos-cli `case` guard keeps its upstream
    assumption checked rather than assumed."""
    try:
        c = sqlite3.connect(":memory:")
        c.execute("CREATE VIRTUAL TABLE t USING fts5(x)")
        return True
    except sqlite3.OperationalError:
        return False


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


def train_dictionary(html_dir, page_count):
    """Train a zlib preset dictionary from a sample of extracted pages using
    the zstd CLI's COVER-family trainer, then use the raw bytes as zlib's
    zdict. Only zstd's TRAINER is used -- the resulting dictionary is consumed
    exclusively through stdlib zlib.compressobj/decompressobj, never through
    zstd itself, at build time or at runtime."""
    if page_count < MIN_PAGES_FOR_DICT:
        return b""
    dict_path = os.path.join(html_dir, "..", "trained.dict")
    dict_path = os.path.abspath(dict_path)
    try:
        # `-r html_dir`, NOT a page_count-sized argv of individual file
        # paths. Measured against the real `man` doc (12,626 pages): passing
        # every sample as its own argument raised
        # "OSError: [Errno 7] Argument list too long" from execve's own
        # ARG_MAX -- macOS caps combined argv+environ around a few hundred
        # KiB to a few MiB depending on the process, and man's page list
        # alone is well past that. `-r` has zstd walk the directory itself.
        subprocess.run(
            ["zstd", "--train", "-r", html_dir, f"--maxdict={DICT_SIZE}", "-o", dict_path, "-f"],
            capture_output=True, check=True, timeout=180,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        # Never fail the whole doc build over a missing dictionary -- an empty
        # zdict just means this doc compresses a bit worse, not incorrectly.
        print(f"warning: zstd --train failed, shipping without a preset dictionary: {exc}", file=sys.stderr)
        return b""
    with open(dict_path, "rb") as f:
        return f.read()


def zlib_compress(data, zdict):
    co = zlib.compressobj(9, zlib.DEFLATED, -15, 9, 0, zdict)
    return co.compress(data) + co.flush()


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
            "build-index.py's module docstring), but it means a future "
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

        # Extract every page's raw HTML to a scratch dir first: the zstd
        # trainer needs real files on disk, and streaming avoids holding the
        # whole (often >100 MB) db.json in memory at once.
        with tempfile.TemporaryDirectory(prefix="devdocs-build-") as scratch:
            html_dir = os.path.join(scratch, "pages")
            os.makedirs(html_dir)
            pages = {}  # path -> raw_bytes; the sample files under html_dir are
            # only for train_dictionary() below, which lists the directory itself
            for i, (path, html) in enumerate(iter_json_object(db_member)):
                raw = html.encode("utf-8")
                with open(os.path.join(html_dir, f"{i:06d}.html"), "wb") as f:
                    f.write(raw)
                pages[path] = raw

            zdict = train_dictionary(html_dir, len(pages))

            if os.path.exists(sqlite_path):
                os.remove(sqlite_path)
            conn = sqlite3.connect(sqlite_path)
            conn.executescript(
                """
                PRAGMA page_size = 4096;
                PRAGMA journal_mode = OFF;
                PRAGMA synchronous = OFF;

                CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID;

                CREATE TABLE pages(
                  id INTEGER PRIMARY KEY,
                  path TEXT NOT NULL UNIQUE,
                  rpath TEXT NOT NULL,
                  html BLOB NOT NULL,
                  raw_bytes INTEGER NOT NULL
                );
                CREATE INDEX pages_rpath ON pages(rpath);

                CREATE TABLE entries(
                  id INTEGER PRIMARY KEY,
                  name TEXT NOT NULL,
                  nlower TEXT NOT NULL,
                  page_id INTEGER NOT NULL REFERENCES pages(id),
                  anchor TEXT,
                  type TEXT
                );
                CREATE INDEX entries_nlower ON entries(nlower);
                CREATE INDEX entries_page ON entries(page_id);

                CREATE TABLE types(name TEXT PRIMARY KEY, slug TEXT, count INTEGER) WITHOUT ROWID;
                """
            )

            # entries.path is deliberately NOT stored -- reconstructed at read
            # time as pages.path || '#' || anchor. Saves one duplicated path
            # string per entry (up to ~50k of them for a JDK-sized doc).
            page_id = {}
            # Sorted insert for byte-stable output across rebuilds of
            # identical input -- this derivation is input-addressed, not an
            # FOD, so nothing CHECKS this, but it costs nothing and helps a
            # future `nix build --rebuild` diff cleanly.
            for path in sorted(pages):
                raw = pages[path]
                z = zlib_compress(raw, zdict)
                cur = conn.execute(
                    "INSERT INTO pages(path, rpath, html, raw_bytes) VALUES (?,?,?,?)",
                    (path, path.lower()[::-1], z, len(raw)),
                )
                page_id[path] = cur.lastrowid

            skipped_entries = []
            for e in sorted(index.get("entries", []), key=lambda e: (e["name"], e["path"])):
                page, sep, anchor = e["path"].partition("#")
                pid = page_id.get(page)
                if pid is None:
                    # index.json referenced a page db.json never shipped. Real
                    # upstream data has not shown this, but silently dropping
                    # an entry would make a future search miss it with no
                    # trace -- record it in meta instead of asserting, since
                    # it costs the doc nothing to degrade gracefully.
                    skipped_entries.append(e["path"])
                    continue
                conn.execute(
                    "INSERT INTO entries(name, nlower, page_id, anchor, type) VALUES (?,?,?,?,?)",
                    (e["name"], e["name"].lower(), pid, anchor if sep else None, e.get("type")),
                )

            for t in index.get("types", []):
                conn.execute(
                    "INSERT INTO types(name, slug, count) VALUES (?,?,?)",
                    (t["name"], t.get("slug"), t.get("count")),
                )

            meta_rows = {
                "slug": slug,
                "family": family,
                "name": meta_src.get("name", slug),
                "release": meta_src.get("release", ""),
                "mtime": str(meta_src.get("mtime", "")),
                "schema_version": str(SCHEMA_VERSION),
                "entry_count": str(len(index.get("entries", []))),
                "page_count": str(len(pages)),
                "html_bytes": str(sum(len(r) for r in pages.values())),
                "features": json.dumps({"names": True, "content": False}),
                "skipped_entries": json.dumps(skipped_entries),
            }
            for k, v in meta_rows.items():
                conn.execute("INSERT INTO meta(key, value) VALUES (?,?)", (k, v))
            conn.execute("INSERT INTO meta(key, value) VALUES ('zdict', ?)", (zdict,))

            conn.commit()
            conn.execute("PRAGMA optimize")
            conn.execute("VACUUM")
            conn.close()

            if skipped_entries:
                print(
                    f"warning: {slug}: {len(skipped_entries)} index.json entries "
                    f"reference pages missing from db.json, skipped: "
                    f"{skipped_entries[:5]}{'...' if len(skipped_entries) > 5 else ''}",
                    file=sys.stderr,
                )
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
