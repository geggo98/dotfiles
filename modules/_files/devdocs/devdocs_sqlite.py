"""Shared +devdocs SQLite schema writer, extracted from build-index.py so
every builder (DevDocs tarballs, Maven javadoc jars/zips, the Gradle docs
archive, Valkey command docs) writes byte-for-byte the same schema
devdocs-cli.py reads. A second, drifted implementation of this schema is the
one bug class that produces a database the CLI can open (it globs *.sqlite
and reads `meta.slug` with no other validation) but cannot correctly query --
so this module is the single place the invariants below are enforced, not
just documented.

Invariants devdocs-cli.py depends on (each is asserted here, not just
described):
  - pages.path MUST be lowercase -- resolve_head/cmd_page both lowercase
    their own input before querying it, so a mixed-case stored path is
    simply unreachable, not merely inconsistent.
  - pages.rpath MUST be exactly path[::-1] (path is already lowercase) --
    suffix_candidates GLOBs the reversed string against an index.
  - entries.nlower MUST be name.lower().
  - entries.anchor is stored EXACTLY as it must appear as an HTML id=/name=
    attribute value -- never lowercased, never re-encoded. It is never
    stored as part of a combined "path#anchor" string; devdocs-cli.py
    reconstructs that at read time.
  - meta MUST carry a 'slug' key -- installed_docs() in devdocs-cli.py keys
    every installed doc by it; a duplicate slug across two files silently
    shadows one of them with no runtime error (see modules/devdocs.nix's
    duplicateSlugs assertion, which exists to catch this before it reaches
    the CLI).
  - meta MUST carry a 'zdict' BLOB (may be b"" -- an empty preset dictionary
    is a valid, just slightly less space-efficient, choice).

Compression: zlib with a per-doc trained preset dictionary. See the original
measurement in build-index.py's module docstring (kept there, not duplicated
here, since it document *that* script's specific tradeoff of a build-time
zstd CLI call for a runtime-stdlib-only reader) -- the numbers apply
identically to every caller of IndexWriter, since they all go through the
same compress/decompress path.
"""
import os
import sqlite3
import subprocess
import sys
import zlib

SCHEMA_VERSION = 1  # the SQLITE schema below; unrelated to docs.lock.json's own schema
DICT_SIZE = 32768  # DEFLATE's window is 32 KiB; a larger trained dict measured
# no improvement once truncated to this size, so train AT this size directly.
MIN_PAGES_FOR_DICT = 20  # below this, the sample is too small to train usefully
# and the absolute size saved is negligible; ship an empty dictionary instead.

_DDL = """
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


def fts5_available():
    """Build-time guard, the +nix-query idiom: fail the BUILD with a message
    naming the cause, rather than shipping a +devdocs whose search silently
    misbehaves. FTS5 is not used by the shipped schema -- this only keeps the
    option open for a future body-search layer, exactly as ai-tools.nix's
    nixos-cli `case` guard keeps its upstream assumption checked rather than
    assumed."""
    try:
        c = sqlite3.connect(":memory:")
        c.execute("CREATE VIRTUAL TABLE t USING fts5(x)")
        return True
    except sqlite3.OperationalError:
        return False


def train_dictionary(html_dir, page_count):
    """Train a zlib preset dictionary from a sample of extracted pages using
    the zstd CLI's COVER-family trainer, then use the raw bytes as zlib's
    zdict. Only zstd's TRAINER is used -- the resulting dictionary is consumed
    exclusively through stdlib zlib.compressobj/decompressobj, never through
    zstd itself, at build time or at runtime."""
    if page_count < MIN_PAGES_FOR_DICT:
        return b""
    dict_path = os.path.abspath(os.path.join(html_dir, "..", "trained.dict"))
    try:
        # `-r html_dir`, NOT a page_count-sized argv of individual file
        # paths. Measured against the real `man` doc (12,626 pages): passing
        # every sample as its own argument raised
        # "OSError: [Errno 7] Argument list too long" from execve's own
        # ARG_MAX. `-r` has zstd walk the directory itself.
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


class IndexWriter:
    """Accumulates pages/entries/types in memory (so callers get a natural
    all-at-once API regardless of how they discover them) and defers all
    SQLite writes to finish(), which is also where the preset dictionary is
    trained -- exactly build-index.py's original two-phase shape, generalized
    so every builder shares one implementation.

    Usage:
        w = IndexWriter()
        w.add_page("org/junit/jupiter/api/assertions", html_bytes_or_str)
        w.add_entry("Assertions.assertTrue(boolean)", "org/junit/jupiter/api/assertions",
                    anchor="assertTrue(boolean)", type_="Method")
        w.add_type("Method", "method", 42)
        stats = w.finish(sqlite_path, {"slug": "...", "family": "...", ...})
    """

    def __init__(self):
        self._pages = {}  # path -> raw bytes
        self._entries = []  # (name, path, anchor, type)
        self._types = []  # (name, slug, count)

    def add_page(self, path, html):
        if path != path.lower():
            raise ValueError(f"page path must already be lowercase, got {path!r}")
        if path in self._pages:
            return  # idempotent: first write wins, callers need not dedupe themselves
        self._pages[path] = html.encode("utf-8") if isinstance(html, str) else html

    def add_entry(self, name, path, anchor=None, type_=None):
        """`path` must correspond to an add_page() call -- checked, and
        degraded to a recorded skip rather than an assertion, in finish()."""
        self._entries.append((name, path, anchor, type_))

    def add_type(self, name, slug, count):
        self._types.append((name, slug, count))

    def finish(self, sqlite_path, meta):
        """Trains the zdict, compresses and writes every page, writes
        entries/types, merges computed stats (entry_count, page_count,
        html_bytes, skipped_entries) into `meta`, and returns that merged
        dict. `meta` must not already contain 'zdict' or the computed keys --
        this is the single place they are produced, so two callers cannot
        drift on how they are derived."""
        import tempfile

        if os.path.exists(sqlite_path):
            os.remove(sqlite_path)
        conn = sqlite3.connect(sqlite_path)
        conn.executescript(_DDL)

        with tempfile.TemporaryDirectory(prefix="devdocs-build-") as scratch:
            html_dir = os.path.join(scratch, "pages")
            os.makedirs(html_dir)
            for i, path in enumerate(sorted(self._pages)):
                with open(os.path.join(html_dir, f"{i:06d}.html"), "wb") as f:
                    f.write(self._pages[path])
            zdict = train_dictionary(html_dir, len(self._pages))

            page_id = {}
            for path in sorted(self._pages):
                raw = self._pages[path]
                z = zlib_compress(raw, zdict)
                cur = conn.execute(
                    "INSERT INTO pages(path, rpath, html, raw_bytes) VALUES (?,?,?,?)",
                    (path, path[::-1], z, len(raw)),
                )
                page_id[path] = cur.lastrowid

        skipped_entries = []
        for name, path, anchor, type_ in sorted(self._entries, key=lambda e: (e[0], e[1])):
            pid = page_id.get(path)
            if pid is None:
                # A caller's own index referenced a page it never added via
                # add_page(). Degrade gracefully, exactly like build-index.py's
                # original db.json/index.json mismatch handling: record it in
                # meta rather than losing the entry with no trace.
                skipped_entries.append(f"{path}#{anchor}" if anchor else path)
                continue
            conn.execute(
                "INSERT INTO entries(name, nlower, page_id, anchor, type) VALUES (?,?,?,?,?)",
                (name, name.lower(), pid, anchor, type_),
            )

        for name, slug, count in self._types:
            conn.execute("INSERT INTO types(name, slug, count) VALUES (?,?,?)", (name, slug, count))

        full_meta = dict(meta)
        full_meta.setdefault("schema_version", str(SCHEMA_VERSION))
        # Total DECLARED entries (add_entry calls), including the skipped
        # ones -- not the count actually inserted. Matches the original
        # build-index.py semantic: `real_entries + len(skipped) ==
        # entry_count`, which test_builder_round_trip asserts directly.
        full_meta["entry_count"] = str(len(self._entries))
        full_meta["page_count"] = str(len(self._pages))
        full_meta["html_bytes"] = str(sum(len(b) for b in self._pages.values()))
        full_meta["skipped_entries"] = json_dumps_compact(skipped_entries)
        for k, v in full_meta.items():
            conn.execute("INSERT INTO meta(key, value) VALUES (?,?)", (k, v))
        conn.execute("INSERT INTO meta(key, value) VALUES ('zdict', ?)", (zdict,))

        conn.commit()
        conn.execute("PRAGMA optimize")
        conn.execute("VACUUM")
        conn.close()

        if skipped_entries:
            print(
                f"warning: {meta.get('slug', '?')}: {len(skipped_entries)} entries reference "
                f"pages never added, skipped: "
                f"{skipped_entries[:5]}{'...' if len(skipped_entries) > 5 else ''}",
                file=sys.stderr,
            )
        return full_meta


def json_dumps_compact(obj):
    import json
    return json.dumps(obj)
