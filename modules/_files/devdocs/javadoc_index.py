"""Parse a standard javadoc-tool output tree (JEP 225 search index format --
the same one used by OpenJDK's own docs, hence DevDocs' `openjdk` family) and
hand back page paths, entries and member kinds ready for devdocs_sqlite's
IndexWriter. No IO of its own: callers pass in the bytes/text they already
read from a jar/zip/directory, so this module works identically whether the
source was a Maven Central javadoc jar, the Gradle docs.zip, or (in the
future) anything else that ships this exact javadoc-tool output shape.

Format facts below were MEASURED against a real javadoc jar
(junit-jupiter-api-5.13.0-javadoc.jar), not assumed from documentation:

- `type-search-index.js` / `member-search-index.js` / `package-search-index.js`
  are each a single JS statement: `<var> = [ ... ];updateSearchResults();`.
  The array itself is plain JSON.
- A type-search-index row is `{"p": package, "l": label}` for an ordinary
  class, `{"l": label, "u": path}` for a synthetic row with no package (e.g.
  "All Classes and Interfaces" -> "allclasses-index.html") -- these carry no
  `p` and must be skipped as real types.
- A nested class's `l` keeps its dotted form ("MethodOrderer.Alphanumeric"),
  and the HTML file on disk is named literally with that dot
  ("MethodOrderer.Alphanumeric.html") -- no `$` substitution.
- A member-search-index row is `{"p", "c": class, "l": label}`, plus a `u`
  field ONLY when `l` needs escaping for use as an anchor/URL fragment.
  MEASURED: `{"l":"Alphanumeric()","u":"%3Cinit%3E()"}` for a constructor
  (javadoc's own anchor for `<init>` is percent-encoded even though this is
  plain HTML, not a URL query string) and `{"l":"abort(String)",
  "u":"abort(java.lang.String)"}` for an overload whose label uses simple
  type names but whose HTML anchor spells out the fully-qualified parameter
  types. The stored anchor MUST be `urllib.parse.unquote(u)` when `u` is
  present -- verified that the corresponding HTML carries
  `id="&lt;init&gt;()"`, i.e. the un-escaped form, and Python's HTMLParser
  hands attribute values already char-reference-unescaped, so `unquote(u)`
  is the only decoding step needed to match it.
- A class page's real content lives inside `<main role="main">...</main>`;
  everything before is head/nav chrome and everything after is a closing
  footer -- MEASURED at 3.4 KB of head and 38 bytes of tail on a real page.
- A class's kind ("Class" / "Interface" / "Enum Class" / "Record Class" /
  "Annotation Interface" / ...) is in `<h1 title="{kind} {name}" ...>` --
  `<body class="...">` is USELESS for this, it is `class-declaration-page`
  for a plain class, an enum, AND an interface alike (measured all three).
- A member's kind (Method / Constructor / Field / Enum Constant / ...) is
  NOT reliably in the per-member `<section class="detail" id="...">` (that
  class is always the literal string "detail"). It IS reliable one level
  up: the enclosing container carries a STABLE `id`, regardless of its
  `class`: `<section class="method-details" id="method-detail">`,
  `<section class="constructor-details" id="constructor-detail">`,
  `<section class="field-details" id="field-detail">`,
  `<section class="constant-details" id="enum-constant-detail">`,
  `<section class="details" id="annotation-interface-element-detail">`.
  KIND_SECTION_IDS below is keyed on that id, not the class.
"""
import json
import re
import urllib.parse
from html.parser import HTMLParser

CLASS_KINDS = {
    "Class", "Interface", "Enum Class", "Record Class",
    "Annotation Interface", "Exception Class", "Error Class",
}

KIND_SECTION_IDS = {
    "method-detail": "Method",
    "constructor-detail": "Constructor",
    "field-detail": "Field",
    "enum-constant-detail": "Enum Constant",
    "property-detail": "Property",
    "annotation-interface-element-detail": "Annotation Element",
}

_SEARCH_INDEX_RE_CACHE = {}


def parse_search_index(text, var):
    """`var` is "typeSearchIndex" | "memberSearchIndex" | "packageSearchIndex".
    Strips the "<var> = " prefix, then lets json.JSONDecoder find where the
    array literal ENDS on its own (via raw_decode) rather than requiring an
    exact trailing ";updateSearchResults();" -- MEASURED against a real,
    older javadoc build (commons-numbers-core:1.3, JDK's javadoc from before
    some later refinement): its search-index files end with a bare `]` and
    NO trailing semicolon or function call at all. A strict "...];$" regex
    rejects that file outright, even though the JSON payload itself is
    perfectly well-formed. Returns [] if `text` is empty/whitespace (a doc
    with zero packages, e.g. a jar with only module-info, would otherwise
    raise confusingly)."""
    text = text.strip()
    if not text:
        return []
    pattern = _SEARCH_INDEX_RE_CACHE.get(var)
    if pattern is None:
        pattern = _SEARCH_INDEX_RE_CACHE[var] = re.compile(r"^" + re.escape(var) + r"\s*=\s*")
    m = pattern.match(text)
    if not m:
        raise ValueError(f"{var}: does not start with '{var} = '")
    try:
        data, _end = json.JSONDecoder().raw_decode(text, m.end())
    except json.JSONDecodeError as exc:
        raise ValueError(f"{var}: invalid JSON array after '{var} = ': {exc}") from exc
    return data


def _class_relpath(e):
    """{"m"?: module, "p": package, "l": simple-or-Nested.Name} ->
    "org/junit/jupiter/api/MethodOrderer.Alphanumeric.html", or None for a
    synthetic row with no package (carries "u" instead, e.g. the
    "All Classes and Interfaces" link)."""
    if "p" not in e:
        return None
    parts = []
    if e.get("m"):
        parts.append(e["m"])
    parts.extend(e["p"].split("."))
    return "/".join(parts) + "/" + e["l"] + ".html"


def package_page_relpath(e):
    """{"l": package_name} -> "org/junit/jupiter/api/package-summary.html",
    or None for a synthetic row (carries "u" -- "url" in an older javadoc
    build, MEASURED: commons-numbers-core:1.3 -- e.g. "All Packages")."""
    if "u" in e or "url" in e or "l" not in e:
        return None
    parts = []
    if e.get("m"):
        parts.append(e["m"])
    parts.extend(e["l"].split("."))
    return "/".join(parts) + "/package-summary.html"


def store_path_for_type(e):
    """The +devdocs page path for a type-search-index row: the class
    relpath, minus ".html", LOWERCASED (pages.path must be lowercase -- see
    devdocs_sqlite.py). "org/junit/jupiter/api/MethodOrderer.Alphanumeric.html"
    -> "org/junit/jupiter/api/methodorderer.alphanumeric" -- note this keeps
    the nested-class dot, which is exactly what lets resolve_head's rule 4
    (exact entries.nlower match) answer a bare "MethodOrderer.Alphanumeric"
    query even though rule 3's dots->slashes rewrite cannot (it would mangle
    the nested-class dot the same way it mangles a package-qualified name)."""
    rel = _class_relpath(e)
    if rel is None:
        return None
    return rel[: -len(".html")].lower()


def store_path_for_package(e):
    rel = package_page_relpath(e)
    if rel is None:
        return None
    return rel[: -len("/package-summary.html")].lower()


def class_html_relpath(e):
    """The path to fetch/read from the archive -- same as store_path_for_type
    but WITHOUT lowercasing, since archive members are case-sensitive."""
    return _class_relpath(e)


def package_html_relpath(e):
    return package_page_relpath(e)


def member_anchor(e):
    """The exact HTML id=/name= value this member's <section class="detail">
    carries. MEASURED: the "u" field, when present, is the anchor
    PERCENT-ENCODED -- {"l":"Alphanumeric()","u":"%3Cinit%3E()"} decodes to
    "<init>()", matching id="&lt;init&gt;()" in the HTML (HTMLParser hands
    attribute values already char-reference-unescaped, so unquote() is the
    only decoding needed). Without "u"/"url", "l" IS the anchor verbatim
    (true for zero-arg members and fields/enum constants, which never need
    escaping).

    An OLDER javadoc build (MEASURED: commons-numbers-core:1.3) names this
    same field "url" instead of "u", and its values were never observed
    percent-encoded -- but unquote() is a no-op on a string with no '%XX'
    sequences, so applying it unconditionally to whichever key is present is
    correct for both generations without needing to tell them apart."""
    enc = e.get("u", e.get("url"))
    if enc is not None:
        return urllib.parse.unquote(enc)
    return e["l"]


def member_name(e):
    """"Assertions.assertTrue(boolean, String)" -- the human label, used for
    entries.name/nlower and for +devdocs search results. Deliberately the
    "l" form (simple type names), not the "u"/anchor form: this is what a
    person actually searches for."""
    return f'{e["c"]}.{e["l"]}'


def strip_to_main(html_text):
    """Slice to <main role="main">...</main>, the class/package page's real
    content -- MEASURED at 3.4 KB of head chrome and 38 bytes of tail on a
    real page. Falls back to the whole document (with a `False` truncated
    flag) for a javadoc build old enough to predate this wrapper (pre
    JDK 11), so a builder can warn rather than silently ship head/nav noise
    forever."""
    start = html_text.find("<main")
    if start == -1:
        return html_text, False
    start = html_text.find(">", start)
    if start == -1:
        return html_text, False
    start += 1
    end = html_text.find("</main>", start)
    if end == -1:
        return html_text[start:], False
    return html_text[start:end], True


def class_kind(main_html):
    """From <h1 title="Enum Class OS" ...>: kind, _, _simple = title.rpartition(" ")
    -- the LAST space-separated word is the class's own (possibly dotted)
    name, everything before it is the kind, which may itself contain a
    space ("Enum Class", "Annotation Interface", "Record Class"). Falls back
    to "Class" if the h1/title attribute is missing or doesn't match a known
    kind -- this is display metadata only, never load-bearing for ref
    resolution."""
    m = re.search(r'<h1[^>]*\btitle="([^"]*)"', main_html)
    if not m:
        return "Class"
    title = html_unescape_attr(m.group(1))
    kind, _, _rest = title.rpartition(" ")
    return kind if kind in CLASS_KINDS else "Class"


def html_unescape_attr(s):
    import html as _html
    return _html.unescape(s)


LEGACY_DETAIL_MARKERS = {
    "field.detail": "Field",
    "method.detail": "Method",
    "constructor.detail": "Constructor",
    "enum.constant.detail": "Enum Constant",
    "annotation.type.element.detail": "Annotation Element",
    "property.detail": "Property",
}


class _AnchorKindScanner(HTMLParser):
    """One pass over a class page's <main> content, recording {anchor: kind}.
    Handles TWO javadoc HTML generations, both measured against real jars:

    - The semantic one (JDK 11-ish onward): <section class="detail"
      id="anchor"> for each member, kind from the nearest ENCLOSING
      <section id="{x}-detail"> (keyed on `id`, not `class`, which is
      unreliably just the literal string "detail" on the per-member
      section itself).
    - The older, pre-semantic one (MEASURED: commons-numbers-core:1.3 --
      note this javadoc build already HAS a JEP-225 search index, despite
      predating the semantic HTML by a further javadoc-tool generation): no
      `<section>` carries an id or class at all; instead a bare
      `<a id="field.detail">`/`"method.detail">`/`"constructor.detail">`
      marker (immediately followed by an `<h3>…Detail</h3>` heading humans
      read, which this scanner ignores) precedes a run of bare
      `<a id="EPSILON">`-style anchors, one per member, until the enclosing
      (unlabeled) `<section>` closes. LEGACY_DETAIL_MARKERS is keyed on
      those ids.

    Both generations still wrap each detail group in a `<section>` (labeled
    or not), so ONE `<section>`-nesting stack resets `current_kind` at the
    right point either way. Tracks ONLY `<section>` nesting depth (not every
    tag) so an unrelated void element inside a detail block (<br>, <img>,
    ...) cannot desync a general tag stack the way it would if every tag
    were pushed and popped."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.current_kind = None
        self._section_stack = []
        self.result = {}

    def handle_starttag(self, tag, attrs):
        ad = dict(attrs)
        if tag == "a":
            aid = ad.get("id")
            if not aid:
                return
            if aid in LEGACY_DETAIL_MARKERS:
                self.current_kind = LEGACY_DETAIL_MARKERS[aid]
            elif self.current_kind and aid not in self.result:
                self.result[aid] = self.current_kind
            return
        if tag != "section":
            return
        prev_kind = self.current_kind
        sec_id = ad.get("id")
        if sec_id in KIND_SECTION_IDS:
            self.current_kind = KIND_SECTION_IDS[sec_id]
        elif ad.get("class") == "detail" and sec_id and self.current_kind:
            self.result[sec_id] = self.current_kind
        self._section_stack.append(prev_kind)

    def handle_endtag(self, tag):
        if tag != "section" or not self._section_stack:
            return
        self.current_kind = self._section_stack.pop()


def anchor_kinds(main_html):
    """{anchor: kind} for every per-member detail section on this page."""
    p = _AnchorKindScanner()
    p.feed(main_html)
    return p.result
