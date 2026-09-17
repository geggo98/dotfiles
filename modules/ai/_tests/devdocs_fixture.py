"""Build a synthetic DevDocs-shaped tarball for the hermetic devdocs test.

Mirrors the real upstream tarball layout exactly (index.json/db.json/
meta.json), with deliberately chosen content covering the two anchor shapes
build-index.py's extractor has to handle:
  - id on a CONTAINER (javadoc: <section class="detail" id="...">)
  - id on a HEADING, needing an outward walk to the enclosing section
    (the Nix manual: <section class="section"><h2 id="...">)
plus the two-overload ambiguity case (`List.add()` as both `add(E)` and
`add(int,E)`) that +devdocs must render together, not guess between.

Usage: devdocs_fixture.py OUTDIR   -- writes OUTDIR/fixture~1.tar.gz
"""
import json
import os
import sys
import tarfile
import tempfile

PAGES = {
    "java.base/java/util/list": (
        '<h1 title="Interface List" class="title">Interface List&lt;E&gt;</h1>'
        '<section class="class-description" id="class-description">'
        '<p>An ordered collection.</p>'
        '</section>'
        '<section class="detail" id="add(E)">'
        '<h3 id="add(java.lang.Object)">add</h3>'
        '<pre class="lang-java" data-language="java">boolean add(E e)</pre>'
        '<div class="block">Appends the specified element to the end of this list.</div>'
        '<dl class="notes"><dt>Parameters:</dt>'
        '<dd><code>e</code> - element to be appended</dd></dl>'
        '</section>'
        '<section class="detail" id="add(int,E)">'
        '<h3 id="add(int,java.lang.Object)">add</h3>'
        '<pre class="lang-java" data-language="java">void add(int index, E element)</pre>'
        '<div class="block">Inserts the specified element at the specified position.</div>'
        '<dl class="notes"><dt>Parameters:</dt>'
        '<dd><code>index</code> - insertion index</dd>'
        '<dd><code>element</code> - element to be inserted</dd></dl>'
        '</section>'
        # A real javadoc class page lists every OTHER member too, which is
        # exactly what anchor scoping avoids paying for. Without these, a
        # synthetic two-member fixture cannot demonstrate the size win --
        # `page` and `show #anchor` would be similar sizes by coincidence,
        # not because scoping failed.
        + "".join(
            f'<section class="detail" id="{m}(Object)">'
            f'<h3 id="{m}">{m}</h3>'
            f'<pre class="lang-java" data-language="java">boolean {m}(Object o)</pre>'
            f'<div class="block">Filler member {m} so the whole-page size is '
            f'representative of a real javadoc class with many members, none '
            f'of which a caller asking for add(int,E) specifically wants to pay for.</div>'
            f'</section>'
            for m in ("contains", "remove", "indexOf", "lastIndexOf", "isEmpty",
                      "clear", "size", "iterator", "toArray", "equals")
        )
    ),
    "fixture/manual/index": (
        '<section class="section"><div class="titlepage"><div>'
        '<div><h2 class="title" id="fixture-widget-spin">'
        '<code class="function">fixture.widget.spin</code></h2></div>'
        '</div></div>'
        '<p>Located at fixture/widget.nix:1.</p>'
        '<p>Spins the named widget a number of times.</p>'
        '<div class="variablelist"><dl class="variablelist">'
        '<dt><span class="term"><code class="varname">name</code></span></dt>'
        '<dd><p>Which widget to spin.</p></dd>'
        '<dt><span class="term"><code class="varname">times</code></span></dt>'
        '<dd><p>How many times to spin it.</p></dd>'
        '</dl></div>'
        '</section>'
        '<section class="section"><div class="titlepage"><div>'
        '<div><h2 class="title" id="fixture-widget-stop">'
        '<code class="function">fixture.widget.stop</code></h2></div>'
        '</div></div>'
        '<p>Stops the named widget immediately.</p>'
        '</section>'
    ),
}

ENTRIES = [
    {"name": "List", "path": "java.base/java/util/list", "type": "Interface List<E>"},
    {"name": "List.add()", "path": "java.base/java/util/list#add(E)", "type": "Interface List<E>"},
    {"name": "List.add()", "path": "java.base/java/util/list#add(int,E)", "type": "Interface List<E>"},
    {"name": "fixture.widget.spin", "path": "fixture/manual/index#fixture-widget-spin", "type": "fixture.widget"},
    {"name": "fixture.widget.stop", "path": "fixture/manual/index#fixture-widget-stop", "type": "fixture.widget"},
    # References a page that will NOT be in db.json -- exercises
    # build-index.py's skipped_entries degrade-gracefully path.
    {"name": "Ghost.vanish()", "path": "fixture/ghost/page#vanish()", "type": "Ghost"},
]

TYPES = [
    {"name": "Interface List<E>", "slug": "interface-list", "count": 3},
    {"name": "fixture.widget", "slug": "fixture-widget", "count": 2},
]


def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        index_path = os.path.join(scratch, "index.json")
        db_path = os.path.join(scratch, "db.json")
        meta_path = os.path.join(scratch, "meta.json")

        with open(index_path, "w", encoding="utf-8") as f:
            json.dump({"entries": ENTRIES, "types": TYPES}, f)
        with open(db_path, "w", encoding="utf-8") as f:
            json.dump(PAGES, f)
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump({
                "name": "Fixture", "slug": "fixture~1", "release": "1.0",
                "mtime": 1700000000, "db_size": 0, "links": {},
            }, f)

        tar_path = os.path.join(outdir, "fixture~1.tar.gz")
        with tarfile.open(tar_path, "w:gz") as tf:
            for name, path in (("./index.json", index_path), ("./db.json", db_path), ("./meta.json", meta_path)):
                tf.add(path, arcname=name)
    return tar_path


if __name__ == "__main__":
    out = build(sys.argv[1])
    print(out)
