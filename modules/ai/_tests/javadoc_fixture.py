"""Build a synthetic javadoc-tool-shaped DIRECTORY tree for the hermetic
build-javadoc-index.py test. A directory, not a zip -- build-javadoc-index.py
reads either via the same interface, and a directory needs no zip machinery
to construct here.

Content is deliberately chosen to cover exactly the shapes that surprised
real measurement against junit-jupiter-api-5.13.0-javadoc.jar (see
javadoc_index.py's module docstring):
  - a member-search-index "u" field that is PERCENT-ENCODED and differs from
    "l" (the constructor case: "Widget()" / "u":"%3Cinit%3E()")
  - a "u" field that differs from "l" for an ordinary overload (simple type
    names in "l", fully-qualified in "u")
  - a NESTED class ("Widget.Spinner"), its own page, reachable both by its
    bare dotted name and by its fully-qualified form
  - an enum constant, to exercise the enum-constant-detail kind mapping
  - a member row whose anchor is deliberately NOT present as an id= in the
    HTML (build-javadoc-index.py must record it in missing_anchors and skip
    it, not fail the whole build)

Usage: javadoc_fixture.py OUTDIR   -- writes a javadoc tree under OUTDIR
       javadoc_fixture.py OUTDIR --no-member-index  -- a SECOND shape: a
       type-search-index.js with no member-search-index.js at all, for the
       "refuses to build" guard test (commons-math3/commons-digester3's
       real, pre-JEP-225 javadoc).
"""
import json
import os
import sys

TYPE_SEARCH_INDEX = [
    {"p": "fx", "l": "Widget"},
    {"p": "fx", "l": "Widget.Spinner"},
    {"p": "fx", "l": "Mode"},
    {"l": "All Classes and Interfaces", "u": "allclasses-index.html"},
]

PACKAGE_SEARCH_INDEX = [
    {"l": "fx"},
    {"l": "All Packages", "u": "allpackages-index.html"},
]

MEMBER_SEARCH_INDEX = [
    # Constructor: "u" is the anchor, percent-encoded, and differs entirely
    # from "l" -- javadoc's own convention for <init>.
    {"p": "fx", "c": "Widget", "l": "Widget()", "u": "%3Cinit%3E()"},
    # An overload whose "u" (the real anchor) differs from "l" (the display
    # label) only in using fully-qualified parameter types.
    {"p": "fx", "c": "Widget", "l": "spin(int, String)", "u": "spin(int,java.lang.String)"},
    # A member on the page with NO "u" -- "l" IS the anchor verbatim.
    {"p": "fx", "c": "Widget", "l": "stop()"},
    # Deliberately references an anchor that will NOT exist in Widget.html's
    # HTML -- exercises the missing_anchors degrade-gracefully path.
    {"p": "fx", "c": "Widget", "l": "ghost()"},
    # A member of the NESTED class.
    {"p": "fx", "c": "Widget.Spinner", "l": "go()"},
    # An enum constant.
    {"p": "fx", "c": "Mode", "l": "FAST"},
]


def _page(title, kind, body):
    return f"""<!DOCTYPE html>
<html><head><title>{title}</title></head>
<body class="class-declaration-page">
<script>var head = "chrome, must be stripped";</script>
<nav>navigation chrome, must be stripped</nav>
<main role="main">
<h1 title="{kind} {title}" class="title">{kind} {title}</h1>
{body}
</main>
<footer>footer chrome, must be stripped</footer>
</body></html>
"""


WIDGET_HTML = _page("Widget", "Class", """
<section class="constructor-details" id="constructor-detail">
<section class="detail" id="&lt;init&gt;()">
<h3>Widget</h3>
<div class="block">Creates a new Widget.</div>
</section>
</section>
<section class="method-details" id="method-detail">
<section class="detail" id="spin(int,java.lang.String)">
<h3>spin</h3>
<div class="block">Spins the widget a number of times, with a label.</div>
</section>
<section class="detail" id="stop()">
<h3>stop</h3>
<div class="block">Stops the widget.</div>
</section>
</section>
""")

WIDGET_SPINNER_HTML = _page("Widget.Spinner", "Class", """
<section class="method-details" id="method-detail">
<section class="detail" id="go()">
<h3>go</h3>
<div class="block">Starts the nested spinner.</div>
</section>
</section>
""")

MODE_HTML = _page("Mode", "Enum Class", """
<section class="constant-details" id="enum-constant-detail">
<section class="detail" id="FAST">
<h3>FAST</h3>
<div class="block">Fast mode.</div>
</section>
</section>
""")

PACKAGE_SUMMARY_HTML = """<!DOCTYPE html>
<html><head><title>fx</title></head>
<body class="package-declaration-page">
<main role="main">
<h1 title="Package fx" class="title">Package fx</h1>
<div class="block">The fx package.</div>
</main>
</body></html>
"""


def build(outdir, with_member_index=True):
    os.makedirs(os.path.join(outdir, "fx"), exist_ok=True)

    with open(os.path.join(outdir, "type-search-index.js"), "w", encoding="utf-8") as f:
        f.write("typeSearchIndex = " + json.dumps(TYPE_SEARCH_INDEX) + ";updateSearchResults();")

    with open(os.path.join(outdir, "package-search-index.js"), "w", encoding="utf-8") as f:
        f.write("packageSearchIndex = " + json.dumps(PACKAGE_SEARCH_INDEX) + ";updateSearchResults();")

    if with_member_index:
        with open(os.path.join(outdir, "member-search-index.js"), "w", encoding="utf-8") as f:
            f.write("memberSearchIndex = " + json.dumps(MEMBER_SEARCH_INDEX) + ";updateSearchResults();")

    with open(os.path.join(outdir, "fx", "Widget.html"), "w", encoding="utf-8") as f:
        f.write(WIDGET_HTML)
    with open(os.path.join(outdir, "fx", "Widget.Spinner.html"), "w", encoding="utf-8") as f:
        f.write(WIDGET_SPINNER_HTML)
    with open(os.path.join(outdir, "fx", "Mode.html"), "w", encoding="utf-8") as f:
        f.write(MODE_HTML)
    with open(os.path.join(outdir, "fx", "package-summary.html"), "w", encoding="utf-8") as f:
        f.write(PACKAGE_SUMMARY_HTML)

    return outdir


if __name__ == "__main__":
    out = sys.argv[1]
    with_member = "--no-member-index" not in sys.argv[2:]
    print(build(out, with_member))
