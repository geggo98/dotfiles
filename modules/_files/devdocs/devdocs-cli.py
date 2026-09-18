"""+devdocs -- offline DevDocs (freeCodeCamp) API reference lookup.

Reads the per-doc SQLite indices built by build-index.py (see that file's
module docstring for the schema and the compression choice) from
$DEVDOCS_DIR, which the `+devdocs` wrapper in modules/devdocs.nix bakes in at
build time. Stdlib-only Python, no PEP-723/uv header, same reasoning as
build-index.py: nothing to lock, and the interpreter is already pinned by the
Nix wrapper that execs this file.

Exit codes, and the rule behind them: 1 means "searched, no match" -- the
population searched is always named in the message. 3/5/6 mean "could not be
searched at all" for a structural reason (bad environment, corrupt data,
unknown/uninstalled doc, no network) and must never look like a clean empty
result.
    0  success
    1  searched, nothing matched
    2  usage error (argparse's own)
    3  cannot search: DEVDOCS_DIR unset/empty, corrupt db, unknown slug,
       missing capability, `search --online`
    4  ambiguous: several equally-good candidates, nothing rendered
    5  slug is known upstream but not installed here
    6  network error in --online mode
"""
import argparse
import glob
import html
import json
import os
import re
import sqlite3
import sys
import urllib.error
import urllib.request
import zlib
from html.parser import HTMLParser
from typing import NoReturn

DEFAULT_MAX_BYTES = 32768
DEFAULT_MAX_RENDER = 3
DEFAULT_TIMEOUT = 10
HEAD_TAGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
VOID_TAGS = {
    "br", "hr", "img", "input", "meta", "link",
    "area", "base", "col", "embed", "source", "track", "wbr",
}
DROP_TAGS = {"script", "style", "nav", "svg", "button", "header", "footer"}


def fail(code, *lines) -> NoReturn:
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(code)


# --------------------------------------------------------------------------
# Environment
# --------------------------------------------------------------------------

def devdocs_dir():
    # No os.environ.get(..., default): a launchd job or a harness `Bash(...)`
    # tool call inherits no shell environment at all (see AGENTS.md, "launchd
    # jobs get no shell environment"), so a silent default here would report
    # "no docs installed" while a real index sits in the store. The +devdocs
    # wrapper always sets this; a bare invocation of this file must say so.
    d = os.environ.get("DEVDOCS_DIR")
    if not d:
        fail(3, "DEVDOCS_DIR is not set. Run this via the `+devdocs` wrapper "
                 "(installed by modules/devdocs.nix when my.devdocs.enable is "
                 "true), which bakes this in.")
    return d


def max_bytes():
    v = os.environ.get("DEVDOCS_MAX_BYTES")
    try:
        return int(v) if v else DEFAULT_MAX_BYTES
    except ValueError:
        return DEFAULT_MAX_BYTES


def online_base():
    return os.environ.get("DEVDOCS_ONLINE_BASE", "https://documents.devdocs.io")


def fetch_online(url):
    """GET url, returning decoded text or calling fail(6, ...). A real
    browser-like User-Agent is REQUIRED, not cosmetic: measured against
    documents.devdocs.io, `curl` (no UA at all) gets 200 on every page, while
    Python's default urllib UA ("Python-urllib/3.13") gets 403 from
    Cloudflare on some paths -- the exact same class of block this repo's
    nix-cache-prune.py already documents against narinfo fetches."""
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        fail(6, f"GET {url} -> HTTP {e.code}")
    except (urllib.error.URLError, OSError) as e:
        fail(6, f"GET {url} failed: {e}")


# --------------------------------------------------------------------------
# Doc discovery and connection
# --------------------------------------------------------------------------

def installed_docs(ddir):
    """slug -> sqlite path, for every *.sqlite file readable under ddir."""
    out = {}
    for f in sorted(glob.glob(os.path.join(ddir, "*.sqlite"))):
        try:
            c = sqlite3.connect(f"file:{f}?mode=ro&immutable=1", uri=True)
            row = c.execute("SELECT value FROM meta WHERE key='slug'").fetchone()
            c.close()
        except sqlite3.Error:
            continue
        if row:
            out[row[0]] = f
    return out


def open_doc(path):
    return sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)


def doc_meta(conn):
    return dict(conn.execute("SELECT key, value FROM meta WHERE key != 'zdict'"))


def doc_zdict(conn):
    row = conn.execute("SELECT value FROM meta WHERE key='zdict'").fetchone()
    return row[0] if row else b""


def load_catalog(ddir):
    """The slim ~830-slug catalog baked in for --online: {slug: {name, release}}.
    Absence is not fatal -- it only means --online cannot pre-validate a slug
    and unknown-vs-not-installed degrades to a plain network attempt."""
    path = os.path.join(ddir, "catalog.json")
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def resolve_doc_arg(ddir, doc_arg):
    """--doc resolves by unambiguous PREFIX, the same convention +vault uses
    for -address=<environment>: any unique prefix is accepted, an exact name
    always wins over an otherwise-ambiguous prefix, and an unknown or
    ambiguous name aborts naming the candidates -- never a silent default."""
    docs = installed_docs(ddir)
    if doc_arg in docs:
        return doc_arg, docs[doc_arg]
    candidates = sorted(s for s in docs if s.startswith(doc_arg))
    if len(candidates) == 1:
        return candidates[0], docs[candidates[0]]
    if not candidates:
        catalog = load_catalog(ddir)
        if doc_arg in catalog or any(s.startswith(doc_arg) for s in catalog):
            fail(5, f"'{doc_arg}' is a known DevDocs slug but not installed here.",
                 f"Installed docs: {', '.join(sorted(docs)) or '(none)'}",
                 "Add it to my.devdocs.docs and run `just devdocs-lock`, or use --online.")
        fail(3, f"unknown doc '{doc_arg}'. Installed: {', '.join(sorted(docs)) or '(none)'}")
    fail(4, f"ambiguous --doc '{doc_arg}': {', '.join(candidates)}")


# --------------------------------------------------------------------------
# Page text: zlib+zdict decompression with the raw_bytes integrity check
# --------------------------------------------------------------------------

def page_html(conn, page_id, path, zdict):
    row = conn.execute("SELECT html, raw_bytes FROM pages WHERE id=?", (page_id,)).fetchone()
    if row is None:
        fail(3, f"index/db inconsistency: page id {page_id} ({path}) referenced but missing")
    blob, raw_bytes = row
    try:
        d = zlib.decompressobj(-15, zdict)
        out = d.decompress(blob) + d.flush()
    except zlib.error as exc:
        fail(3, f"zlib error decompressing {path}: {exc}", "rebuild this doc's database")
    if len(out) != raw_bytes:
        fail(3, f"corrupt page {path}: expected {raw_bytes} bytes, got {len(out)}",
             "rebuild this doc's database")
    return out.decode("utf-8")


# --------------------------------------------------------------------------
# Resolution: a ref like "java.util.List#add(int,E)" -> page(s) + anchor
# --------------------------------------------------------------------------

def normalize_suffix(head):
    h = head.strip().lower().lstrip("/")
    return re.sub(r"/+", "/", h)


def suffix_candidates(conn, norm):
    """rpath is lower(path) reversed; an indexed GLOB on the reversed suffix
    finds every page whose path ends with `norm`, at a '/' boundary or at
    the start. Verified against a real EXPLAIN QUERY PLAN: this uses the
    pages_rpath index rather than a full scan."""
    rsuffix = norm[::-1]
    rows = conn.execute(
        "SELECT id, path FROM pages WHERE rpath GLOB ? ORDER BY path", (rsuffix + "*",)
    ).fetchall()
    out = []
    for pid, path in rows:
        if path.lower() == norm or path.lower().endswith("/" + norm):
            out.append((pid, path))
    return out


def dotted_to_path(head):
    """"org.junit.jupiter.api.MethodOrderer.Alphanumeric" ->
    "org/junit/jupiter/api/methodorderer.alphanumeric". A naive "replace
    every dot with a slash" (the original rule here) mangles any FQN whose
    tail names a NESTED class -- javadoc always keeps the nested-class dot
    in the HTML filename itself (MethodOrderer.Alphanumeric.html, never
    methodorderer/alphanumeric.html), so "java.util.Map.Entry" must become
    "java/util/map.entry", not "java/util/map/entry".

    Distinguishing "this dot separates packages" from "this dot chains into
    a nested type" needs the ORIGINAL case of `head` (package segments are
    conventionally lowercase, type names start uppercase) -- which is why
    this takes `head`, not the already-lowercased `hl` every other rule
    below uses, and lowercases only its own result. Once the first
    uppercase-starting segment is seen, every dot from there on is assumed
    to chain into a further nested type and is left alone; the separator
    immediately BEFORE that first uppercase segment is still the
    package/type boundary and becomes a slash.

    A path with no uppercase-starting segment at all (an ordinary package,
    e.g. "java.util.regex") degrades to the same "all dots become slashes"
    behavior this replaced."""
    segs = head.strip().split(".")
    if len(segs) < 2:
        return head.strip().lower()
    out = [segs[0]]
    in_type = segs[0][:1].isupper()
    for seg in segs[1:]:
        out.append(("." if in_type else "/") + seg)
        if not in_type and seg[:1].isupper():
            in_type = True
    return "".join(out).lower()


def resolve_head(conn, head):
    """Returns a list of (page_id, path) candidates for the page-ish part of
    a ref, trying progressively looser matches and stopping at the first
    rule that yields anything. Order matters: a path like
    "java.base/java/util/list" itself contains a dot in the module prefix,
    so the LITERAL suffix check must run before the dotted rewrite, or the
    rewrite mangles it into "java/base/java/util/list" and finds nothing."""
    hl = head.strip().lower()

    # 1. exact path
    row = conn.execute("SELECT id, path FROM pages WHERE path=?", (hl,)).fetchone()
    if row:
        return [row]

    # 2. path suffix, taken literally
    norm = normalize_suffix(hl)
    hits = suffix_candidates(conn, norm)
    if hits:
        return hits

    # 3. path suffix, dots rewritten to slashes at package boundaries only
    # (java.util.List -> java/util/list; java.util.Map.Entry -> java/util/map.entry)
    if "." in hl:
        dotted = normalize_suffix(dotted_to_path(head))
        hits = suffix_candidates(conn, dotted)
        if hits:
            return hits

    # 4. exact entry name, for entries that ARE a page (anchor IS NULL) --
    # covers a bare class/module name typed without its package.
    rows = conn.execute(
        "SELECT DISTINCT p.id, p.path FROM entries e JOIN pages p ON p.id = e.page_id "
        "WHERE e.nlower = ? AND e.anchor IS NULL ORDER BY p.path",
        (hl,),
    ).fetchall()
    if rows:
        return rows

    return []


def split_ref(ref):
    """"java.util.List#add(int,E)" -> ("java.util.List", "add(int,E)").
    "java.util.List.add" (no '#') is also accepted: if the whole ref does not
    resolve as a page and its tail looks like a lowercase member name hanging
    off an uppercase-looking class segment, split there instead."""
    if "#" in ref:
        head, frag = ref.split("#", 1)
        return head, frag
    return ref, None


def guess_dotted_split(ref):
    """Fallback for "java.util.List.add" with no '#'. Only used when the
    whole ref fails to resolve as a page outright."""
    m = re.match(r"^(.*\.)([A-Za-z_][\w]*\(?\)?)$", ref)
    if not m:
        return None
    base, tail = m.group(1)[:-1], m.group(2).rstrip("()")
    # Heuristic: the base's last segment looks like a class/type name
    # (starts uppercase) -- distinguishes "java.util.List.add" (member of
    # List) from "java.util.regex" (just a package, no member intended).
    last_seg = base.rsplit(".", 1)[-1]
    if last_seg[:1].isupper():
        return base, tail
    return None


def resolve_anchor(conn, page_id, _path, frag):
    """Returns (candidates, mode) where candidates is a list of
    (anchor, name, type) and mode explains how they were found, or (None,
    None) if frag itself should be looked up literally in the raw HTML
    (index.json's entries did not carry it)."""
    fl = frag.strip()

    rows = conn.execute(
        "SELECT anchor, name, type FROM entries WHERE page_id=? AND anchor=?",
        (page_id, fl),
    ).fetchall()
    if rows:
        return rows, "exact"

    # member-name-prefix: "#add" matches "add(E)" and "add(int,E)"
    member = fl.split("(", 1)[0]
    rows = conn.execute(
        "SELECT anchor, name, type FROM entries WHERE page_id=? AND anchor IS NOT NULL",
        (page_id,),
    ).fetchall()
    prefix_hits = [r for r in rows if r[0].split("(", 1)[0] == member]
    if prefix_hits:
        return prefix_hits, "member-name"

    # arity match: compare (name, argument count) after stripping whitespace,
    # so a signature copied out of a stack trace (fully-qualified argument
    # types collapsed to arity) still lands.
    frag_arity = fl.count(",") + 1 if "(" in fl and not fl.endswith("()") else (0 if fl.endswith("()") else None)
    if frag_arity is not None:
        arity_hits = [
            r for r in rows
            if r[0].split("(", 1)[0] == member
            and ((r[0].count(",") + 1 if "(" in r[0] and not r[0].endswith("()") else 0) == frag_arity)
        ]
        if arity_hits:
            return arity_hits, "arity"

    return None, None


# --------------------------------------------------------------------------
# HTML -> anchor-scoped fragment (build-index.py's anchor semantics apply:
# ids are exact strings, never regex/CSS-selector/XPath material)
# --------------------------------------------------------------------------

class _Offsets:
    """Shared line->offset table so nested parses need not rebuild it."""
    def __init__(self, text):
        offs = [0]
        for line in text.splitlines(keepends=True):
            offs.append(offs[-1] + len(line))
        self.offs = offs

    def at(self, line, col):
        return self.offs[line - 1] + col


class _AnchorExtractor(HTMLParser):
    """Locates the element/section belonging to `anchor`. Two shapes, both
    measured against real DevDocs markup:
      - id sits on a CONTAINER (section/div/li/...) -> that element's own
        subtree.  (javadoc: <section class="detail" id="add(int,E)">)
      - id sits on a HEADING (h1-h6) -> walk outward to the nearest ancestor
        section/article that has not already seen an earlier heading of
        equal-or-shallower level; failing that, the heading plus its
        following siblings up to the next such heading.
        (Nix manual: <section class="section"><h2 id="...">)
    """
    def __init__(self, html_text, anchor):
        super().__init__(convert_charrefs=False)
        self.html = html_text
        self.offsets = _Offsets(html_text)
        self.anchor = anchor
        self.stack = []  # [tag, start_offset]
        self.mode = None  # None | 'subtree' | 'heading'
        self.match_tag = None
        self.match_depth = None
        self.start = None
        self.level = None
        self.end = None

    def _off(self):
        line, col = self.getpos()
        return self.offsets.at(line, col)

    def handle_starttag(self, tag, attrs):
        off = self._off()
        ad = dict(attrs)
        if (self.mode == "heading" and self.end is None and self.level is not None
                and tag in HEAD_TAGS and int(tag[1]) <= self.level):
            self.end = off
        if self.mode is None and (ad.get("id") == self.anchor or ad.get("name") == self.anchor):
            if tag in HEAD_TAGS:
                self.mode = "heading"
                self.start = off
                self.level = int(tag[1])
            else:
                self.mode = "subtree"
                self.match_tag = tag
                self.match_depth = len(self.stack)
                self.start = off
        if tag not in VOID_TAGS:
            self.stack.append([tag, off])

    def handle_startendtag(self, tag, attrs):
        # `tag` unused: a self-closed void-ish tag can only be the id-bearer
        # itself, never a container whose type matters afterwards.
        del tag
        # self-closed non-void tag written as <tag/>: treat like start+end
        # immediately, relevant only if it happens to carry the id itself.
        ad = dict(attrs)
        if self.mode is None and (ad.get("id") == self.anchor or ad.get("name") == self.anchor):
            off = self._off()
            close = self.html.find("/>", off)
            close = (close + 2) if close != -1 else off
            self.mode = "subtree"
            self.start = off
            self.end = close

    def handle_endtag(self, tag):
        # `tag` (what HTMLParser thinks is closing) is deliberately not
        # trusted against `self.stack` -- the stack's own push/pop bookkeeping
        # is the source of truth for depth and identity, which is robust to
        # HTMLParser's lenient handling of malformed/mismatched markup.
        del tag
        if not self.stack:
            return
        t, opened_off = self.stack.pop()
        del opened_off
        end = self.html.find(">", self._off())
        end = (end + 1) if end != -1 else self._off()
        if self.mode == "subtree" and self.end is None and t == self.match_tag and len(self.stack) == self.match_depth:
            self.end = end

    def result(self):
        if self.start is None:
            return None
        return self.html[self.start: self.end if self.end is not None else len(self.html)]


def extract_anchor_html(page_html_text, anchor):
    p = _AnchorExtractor(page_html_text, anchor)
    try:
        p.feed(page_html_text)
    except Exception:
        return None
    return p.result()


# --------------------------------------------------------------------------
# HTML -> Markdown rendering
# --------------------------------------------------------------------------

class _MarkdownRenderer(HTMLParser):
    """Deliberately small subset, in priority order: pre/code as fenced
    blocks (data-language as the info string), headings relative to the
    section's own top level, dl/dt/dd as Parameters/Throws/Returns blocks
    (the densest information on a javadoc page), lists, a bare GFM table,
    links dropped by default (javadoc pages run ~40% links by token count;
    --links keeps them as doc-relative paths, never as https:// URLs, since
    those are useless offline)."""

    def __init__(self, keep_links=False, base_min_level=2):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.keep_links = keep_links
        self.min_level = None
        self.base_min_level = base_min_level
        self.drop_depth = 0
        self.pre_depth = 0
        self.pre_buf = None
        self.pre_lang = ""
        self.list_stack = []  # 'ul' | 'ol' entries, for nesting/numbering
        self.list_counters = []
        self.link_href = None
        self.in_attribution = False
        self.dt_pending = False
        # Set after emitting a line-starting marker ("- ", "**", "# ", "> ")
        # so the very next handle_data call can drop a leading whitespace-only
        # text node -- devdocs' pretty-printed HTML puts a literal newline
        # between e.g. "<dd>" and "<code>", which would otherwise collapse to
        # a stray extra space right after the marker.
        self.strip_next_ws = False

    def _emit(self, text):
        self.out.append(text)

    def _emit_marker(self, text):
        self._emit(text)
        self.strip_next_ws = True

    def _block_sep(self):
        if self.out and not self.out[-1].endswith("\n\n"):
            if self.out[-1].endswith("\n"):
                self.out.append("\n")
            else:
                self.out.append("\n\n")

    def handle_starttag(self, tag, attrs):
        ad = dict(attrs)
        cls = ad.get("class", "") or ""
        if "_attribution" in cls or "_attribution-link" in cls:
            self.in_attribution = True
        if self.in_attribution:
            return
        if tag in DROP_TAGS:
            self.drop_depth += 1
            return
        if self.drop_depth:
            return

        if tag in HEAD_TAGS:
            level = int(tag[1])
            if self.min_level is None:
                self.min_level = level
            rel = self.base_min_level + max(0, level - self.min_level)
            self._block_sep()
            self._emit_marker("#" * min(rel, 6) + " ")
        elif tag == "pre":
            self.pre_depth += 1
            self._block_sep()
            self.pre_lang = ad.get("data-language", "")
            if not self.pre_lang:
                for c in cls.split():
                    if c.startswith("lang-"):
                        self.pre_lang = c[len("lang-"):]
            self.pre_buf = []
        elif tag == "code" and self.pre_depth == 0:
            self._emit_marker("`")
        elif tag == "dl":
            self._block_sep()
        elif tag == "dt":
            self._block_sep()
            self._emit_marker("**")
            self.dt_pending = True
        elif tag == "dd":
            self._emit_marker("\n- ")
        elif tag in ("ul", "ol"):
            self.list_stack.append(tag)
            self.list_counters.append(0)
            self._block_sep()
        elif tag == "li":
            depth = max(0, len(self.list_stack) - 1)
            indent = "  " * depth
            if self.list_stack and self.list_stack[-1] == "ol":
                self.list_counters[-1] += 1
                self._emit_marker(f"\n{indent}{self.list_counters[-1]}. ")
            else:
                self._emit_marker(f"\n{indent}- ")
        elif tag == "blockquote":
            self._block_sep()
            self._emit_marker("> ")
        elif tag == "hr":
            self._block_sep()
            self._emit("---")
            self._block_sep()
        elif tag == "br":
            self._emit("\n")
        elif tag == "a" and self.pre_depth == 0:
            self.link_href = ad.get("href")
            if self.keep_links and self.link_href:
                self._emit("[")
        elif tag in ("p", "div", "section", "table", "tr", "th", "td"):
            if tag in ("p", "div"):
                self._block_sep()
            elif tag == "table":
                self._block_sep()
            elif tag == "tr":
                self._block_sep()
            elif tag in ("th", "td"):
                self._emit_marker("| ")

    def handle_endtag(self, tag):
        cls_closed_attribution = self.in_attribution and tag in ("div", "p", "span", "footer")
        if self.in_attribution:
            if cls_closed_attribution:
                self.in_attribution = False
            return
        if tag in DROP_TAGS:
            self.drop_depth = max(0, self.drop_depth - 1)
            return
        if self.drop_depth:
            return

        if tag in HEAD_TAGS:
            self._emit("\n\n")
        elif tag == "pre":
            self.pre_depth -= 1
            body = "".join(self.pre_buf) if self.pre_buf else ""
            self._emit(f"```{self.pre_lang}\n{body.strip(chr(10))}\n```\n\n")
            self.pre_buf = None
        elif tag == "code" and self.pre_depth == 0:
            self._emit("`")
        elif tag == "dt":
            # javadoc's own dt text is usually already colon-terminated
            # ("Parameters:"), but not guaranteed -- add one only if missing,
            # rather than risking "Parameters::". Checking just the last
            # emitted chunk is enough in practice: dt content is short and
            # handle_data collapses it to (typically) one chunk.
            if self.out:
                self.out[-1] = self.out[-1].rstrip()  # drop trailing space before the colon
            tail = self.out[-1] if self.out else ""
            if not tail.endswith(":"):
                self._emit(":")
            self._emit("**\n")
            self.dt_pending = False
        elif tag == "dd":
            pass
        elif tag in ("ul", "ol"):
            if self.list_stack:
                self.list_stack.pop()
                self.list_counters.pop()
            if not self.list_stack:
                self._emit("\n\n")
        elif tag == "a" and self.pre_depth == 0:
            if self.keep_links and self.link_href:
                href = self.link_href
                if href and not re.match(r"^[a-z]+://", href):
                    self._emit(f"]({href})")
                else:
                    self._emit("]")  # external/absolute URL: drop, keep text
            self.link_href = None
        elif tag in ("th", "td"):
            self._emit(" ")
        elif tag == "tr":
            self._emit("|\n")
        elif tag in ("p", "div", "table"):
            self._emit("\n\n")

    def handle_data(self, data):
        if self.in_attribution or self.drop_depth:
            return
        if self.pre_depth:
            if self.pre_buf is not None:
                self.pre_buf.append(data)
            return
        # ALL whitespace collapses outside <pre>, not just spaces/tabs.
        # DevDocs' source HTML is pretty-printed with real newlines between
        # tags (e.g. "<dd>\n<code>index</code> ..."), and a literal \n in a
        # text node was leaking straight into the rendered Markdown as an
        # unwanted line break -- measured against a real page, not assumed.
        collapsed = re.sub(r"\s+", " ", data)
        if self.strip_next_ws:
            collapsed = collapsed.lstrip(" ")
            if collapsed:
                self.strip_next_ws = False
        self._emit(collapsed)

    def handle_entityref(self, name):
        self.handle_data(html.unescape(f"&{name};"))

    def handle_charref(self, name):
        self.handle_data(html.unescape(f"&#{name};"))

    def result(self):
        text = "".join(self.out)
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip() + "\n"


def render_markdown(fragment_html, keep_links=False):
    p = _MarkdownRenderer(keep_links=keep_links)
    p.feed(fragment_html)
    p.close()
    return p.result()


# --------------------------------------------------------------------------
# Output plumbing: --output / - / --format json, the jira-skill convention
# --------------------------------------------------------------------------

def emit_json(payload, args):
    """For commands whose natural result IS structured data (search, docs,
    types): dump `payload` directly. NEVER route this through emit_text's
    json branch, which wraps arbitrary text as {"text": ..., "chars": ...} --
    doing that to an already-JSON payload double-encodes it into an escaped
    string inside that wrapper, which is valid JSON but useless to a caller
    expecting the array/object itself."""
    output = getattr(args, "output", None)
    body = json.dumps(payload, ensure_ascii=False)
    if output and output != "-":
        with open(output, "w", encoding="utf-8") as f:
            f.write(body)
        print(f"{output}\t{len(body.encode('utf-8'))}")
    else:
        print(body)


def emit_text(text, args):
    fmt = getattr(args, "format", "md")
    output = getattr(args, "output", None)

    if fmt == "json":
        # Never truncated: a truncation header injected into a JSON record
        # would produce invalid JSON. Carries `chars` so a caller can size-
        # check before asking for the body, mirroring the jira skill.
        emit_json({"text": text, "chars": len(text)}, args)
        return

    data = text.encode("utf-8")
    if output and output != "-":
        with open(output, "wb") as f:
            f.write(data)
        print(f"{output}\t{len(data)}")
        return

    if output == "-":
        sys.stdout.write(text)
        return

    cap = max_bytes()
    if len(data) > cap:
        head = data[:cap].decode("utf-8", errors="ignore")
        sys.stdout.write(head)
        print(f"\n... [truncated: showed {len(head.encode('utf-8'))} of {len(data)} "
              f"bytes; use --output - or --output FILE for the full text]", file=sys.stderr)
    else:
        sys.stdout.write(text)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def cmd_docs(args):
    ddir = devdocs_dir()
    docs = installed_docs(ddir)
    if not docs and not getattr(args, "all", False):
        fail(3, f"no installed docs under DEVDOCS_DIR={ddir!r}")
    rows = []
    for slug, path in sorted(docs.items()):
        conn = open_doc(path)
        m = doc_meta(conn)
        conn.close()
        rows.append((slug, m.get("release", ""), m.get("entry_count", "?"), m.get("page_count", "?")))

    if getattr(args, "format", "md") == "json":
        payload = [{"slug": s, "release": r, "entries": e, "pages": p} for s, r, e, p in rows]
        print(json.dumps(payload, ensure_ascii=False))
        return

    if not rows:
        print("(no docs installed)")
        return
    width = max(len(r[0]) for r in rows)
    for slug, release, entries, pages in rows:
        print(f"{slug:<{width}}  release={release or '?':<12}  entries={entries:<7}  pages={pages}")


def cmd_types(args):
    ddir = devdocs_dir()
    _slug, path = resolve_doc_arg(ddir, args.doc)
    conn = open_doc(path)
    rows = conn.execute("SELECT name, slug, count FROM types ORDER BY name").fetchall()
    conn.close()
    if getattr(args, "format", "md") == "json":
        print(json.dumps([{"name": n, "slug": s, "count": c} for n, s, c in rows], ensure_ascii=False))
        return
    for n, _type_slug, c in rows:
        print(f"{n}\t{c}")


def _search_one_doc(conn, slug, query, type_filter, limit):
    """Three-tier ranking (exact > prefix > substring), same result order as
    a plain per-row scan, but the exact/prefix tiers now run as indexed SQL
    against entries_nlower instead of a full unindexed Python pass over every
    entry in the doc. Doc count roughly doubled with the addition of the
    Maven/Gradle/Valkey sources (~39 -> ~80 dbs, ~230k -> ~410k entries), so a
    full scan per doc on every `search` call stopped being free. The
    substring tier still needs a full scan -- no index can serve an
    unanchored LIKE '%x%' -- so it is skipped entirely once the first two
    tiers already satisfy --limit, which is the common case for anyone
    searching a real term."""
    ql = query.lower()
    type_sql = " AND e.type = ?" if type_filter else ""
    type_params = (type_filter,) if type_filter else ()

    exact = conn.execute(
        "SELECT e.name, p.path, e.anchor, e.type FROM entries e "
        "JOIN pages p ON p.id = e.page_id WHERE e.nlower = ?" + type_sql,
        (ql, *type_params),
    ).fetchall()

    prefix = []
    if not limit or len(exact) < limit:
        # nlower is already lowercase, and GLOB is case-sensitive, so this is
        # exactly a prefix match served by the entries_nlower index -- the
        # same trick suffix_candidates() already uses for rpath above.
        prefix = conn.execute(
            "SELECT e.name, p.path, e.anchor, e.type FROM entries e "
            "JOIN pages p ON p.id = e.page_id "
            "WHERE e.nlower GLOB ? AND e.nlower != ?" + type_sql,
            (ql + "*", ql, *type_params),
        ).fetchall()

    sub = []
    if not limit or len(exact) + len(prefix) < limit:
        rows = conn.execute(
            "SELECT e.name, e.nlower, p.path, e.anchor, e.type FROM entries e "
            "JOIN pages p ON p.id = e.page_id" + (" WHERE e.type = ?" if type_filter else ""),
            type_params,
        ).fetchall()
        for name, nlower, path, anchor, typ in rows:
            if nlower == ql or nlower.startswith(ql):
                continue  # already covered by the exact/prefix tiers above
            if ql in nlower:
                sub.append((name, path, anchor, typ))

    ranked = list(exact) + list(prefix) + sub
    return [(slug, *r) for r in ranked[:limit]] if limit else [(slug, *r) for r in ranked]


def cmd_search(args):
    if args.online:
        # DevDocs serves no search API -- an offline fallback here would
        # silently answer from the wrong population and read as "zero
        # results" instead of "this cannot be asked online at all".
        fail(3, "DevDocs has no search API; there is no index to search "
                 "for an --online doc. Use `+devdocs show --online` with an "
                 "explicit page path instead.")
    ddir = devdocs_dir()
    docs = installed_docs(ddir)
    if args.doc:
        wanted = [resolve_doc_arg(ddir, d)[0] for d in args.doc]
    else:
        wanted = sorted(docs)
    if not wanted:
        fail(3, f"no installed docs under DEVDOCS_DIR={ddir!r}")

    limit = args.limit
    results = []
    total_entries = 0
    for slug in wanted:
        conn = open_doc(docs[slug])
        total_entries += int(doc_meta(conn).get("entry_count", 0))
        results.extend(_search_one_doc(conn, slug, args.query, args.type, limit))
        conn.close()
    results = results[:limit] if limit else results

    if getattr(args, "format", "md") == "json":
        payload = [
            {"doc": s, "name": n, "path": p, "anchor": a, "type": t}
            for s, n, p, a, t in results
        ]
        emit_json(payload, args)
        return

    if not results:
        fail(1, f"no entry matches '{args.query}' across {len(wanted)} doc(s) "
                 f"({total_entries} entries searched)")
    lines = []
    for slug, name, path, anchor, typ in results:
        ref = f"{path}#{anchor}" if anchor else path
        lines.append(f"{slug}\t{name}\t{ref}\t{typ or ''}")
    emit_text("\n".join(lines) + "\n", args)


def cmd_members(args):
    ddir = devdocs_dir()
    slug, _path = resolve_doc_arg(ddir, args.doc) if args.doc else (None, None)
    docs = installed_docs(ddir)
    search_slugs = [slug] if slug else sorted(docs)

    found_pages = []  # (slug, conn, page_id, path)
    open_conns = []
    for s in search_slugs:
        conn = open_doc(docs[s])
        open_conns.append(conn)
        for pid, ppath in resolve_head(conn, args.ref):
            found_pages.append((s, conn, pid, ppath))

    if not found_pages:
        for c in open_conns:
            c.close()
        pop = len(search_slugs)
        fail(1, f"'{args.ref}' does not resolve to a page in {pop} doc(s) searched")

    # Always check distinct (slug, path) pairs, not just across docs: a
    # single doc can itself have two pages sharing a simple name (e.g.
    # java.util.List vs java.awt.List, both just "List") -- --doc narrows
    # WHICH docs are searched, not whether pages within one can still be
    # ambiguous, so this must not be skipped just because --doc was given.
    if len({(s, p) for s, _, _, p in found_pages}) > 1:
        for c in open_conns:
            c.close()
        fail(4, "ambiguous page: " +
                ", ".join(f"{s}:{p}" for s, _, _, p in found_pages) +
                " -- pass --doc, or a fuller path, to disambiguate")

    s, winner_conn, pid, ppath = found_pages[0]
    rows = winner_conn.execute(
        "SELECT name, anchor, type FROM entries WHERE page_id=? ORDER BY name", (pid,)
    ).fetchall()
    for c in open_conns:
        c.close()

    if getattr(args, "format", "md") == "json":
        payload = [{"name": n, "anchor": a, "type": t} for n, a, t in rows]
        emit_json({"doc": s, "path": ppath, "members": payload}, args)
        return

    lines = [f"# {ppath} ({s})"]
    for n, a, t in rows:
        lines.append(f"{n}\t{a or ''}\t{t or ''}")
    emit_text("\n".join(lines) + "\n", args)


def _render_entry(slug, conn, page_id, path, name, typ, anchor, zdict, keep_links):
    html_text = page_html(conn, page_id, path, zdict)
    if anchor is None:
        frag = html_text
    else:
        frag = extract_anchor_html(html_text, anchor)
        if frag is None:
            # index.json carried this anchor, but it is not an id= in the
            # HTML: an index/db inconsistency, not "no such member".
            fail(3, f"anchor '{anchor}' listed in {slug}'s index but not found "
                     f"in the HTML of {path} -- index/db inconsistency")
    body = render_markdown(frag, keep_links=keep_links)
    ref = f"{path}#{anchor}" if anchor else path
    header = f"## {name} — {slug}" + (f" · {typ}" if typ else "")
    return f"{header}\n`{ref}`\n\n{body}"


def cmd_show(args):
    ddir = devdocs_dir()

    if args.ref == "-":
        fail(2, "show -: reading refs from stdin is not yet implemented in this build")

    if args.online:
        return _show_online(args)

    docs = installed_docs(ddir)
    wanted = [resolve_doc_arg(ddir, d)[0] for d in args.doc] if args.doc else sorted(docs)
    if not wanted:
        fail(3, f"no installed docs under DEVDOCS_DIR={ddir!r}")

    head, frag = split_ref(args.ref)
    if frag is None:
        # A ref with no '#' may itself BE a whole page/entry name --
        # "MethodOrderer.Alphanumeric" and "Map.Entry" are nested classes,
        # each its own page, and must not be pre-emptively split into
        # (class, member) by guess_dotted_split before that is even tried:
        # nested-class names have exactly the shape guess_dotted_split looks
        # for (a dotted tail whose last segment starts uppercase), so it
        # would otherwise always win. Probe the whole ref first; only fall
        # back to the dotted-guess split when nothing resolves it whole.
        whole_resolves = False
        for slug in wanted:
            probe = open_doc(docs[slug])
            try:
                if resolve_head(probe, head):
                    whole_resolves = True
                    break
                hl = head.strip().lower()
                if probe.execute("SELECT 1 FROM entries WHERE nlower=? LIMIT 1", (hl,)).fetchone():
                    whole_resolves = True  # the flat-doc shape, e.g. the Nix manual
                    break
            finally:
                probe.close()
        if not whole_resolves:
            guess = guess_dotted_split(args.ref)
            if guess:
                head, frag = guess

    all_matches = []  # (slug, conn, page_id, path, anchor_or_None, name, type)
    conns = []
    for slug in wanted:
        conn = open_doc(docs[slug])
        conns.append(conn)
        pages = resolve_head(conn, head)
        for pid, ppath in pages:
            if frag is None:
                row = conn.execute(
                    "SELECT name, type FROM entries WHERE page_id=? AND anchor IS NULL LIMIT 1",
                    (pid,),
                ).fetchone()
                name = row[0] if row else ppath.rsplit("/", 1)[-1]
                typ = row[1] if row else None
                all_matches.append((slug, conn, pid, ppath, None, name, typ))
            else:
                anchors, mode = resolve_anchor(conn, pid, ppath, frag)
                if anchors:
                    if mode != "exact":
                        print(f"note: '{frag}' matched {slug}:{ppath} by {mode}, "
                              f"not an exact anchor", file=sys.stderr)
                    for a, name, typ in anchors:
                        all_matches.append((slug, conn, pid, ppath, a, name, typ))

        if not pages and frag is None:
            # Flat-doc fallback (e.g. the "nix" manual): a doc whose
            # page-defining entries still carry an anchor -- resolve_head's
            # step 4 only covers "anchor IS NULL" entries (javadoc's own
            # class-defining row), which is the wrong shape here. Try the
            # whole ref as an exact entry NAME instead, anchor or not.
            hl = head.strip().lower()
            rows = conn.execute(
                "SELECT e.anchor, e.name, e.type, p.id, p.path FROM entries e "
                "JOIN pages p ON p.id = e.page_id WHERE e.nlower = ?",
                (hl,),
            ).fetchall()
            for anchor, name, typ, pid, ppath in rows:
                all_matches.append((slug, conn, pid, ppath, anchor, name, typ))

    if not all_matches:
        for c in conns:
            c.close()
        pop = len(wanted)
        fail(1, f"'{args.ref}' does not resolve to anything in {pop} doc(s) searched "
                 f"({', '.join(wanted)})")

    distinct_pages = {(s, p) for s, _, _, p, *_ in all_matches}
    if len(all_matches) > args.max_render or len(distinct_pages) > 1:
        for c in conns:
            c.close()
        lines = [f"{len(all_matches)} candidates match '{args.ref}', nothing rendered:"]
        for slug, _, _, ppath, anchor, name, typ in all_matches:
            ref = f"{ppath}#{anchor}" if anchor else ppath
            lines.append(f"  {slug}:{ref}\t{name}")
        fail(4, *lines)

    if len(all_matches) > 1:
        print(f"{len(all_matches)} members match '{args.ref}' on "
              f"{all_matches[0][3]}; rendering all "
              f"(use an exact #anchor to pick one)", file=sys.stderr)

    zdict_cache = {}
    parts = []
    for slug, conn, pid, ppath, anchor, name, typ in all_matches:
        if slug not in zdict_cache:
            zdict_cache[slug] = doc_zdict(conn)
        parts.append(_render_entry(slug, conn, pid, ppath, name, typ, anchor,
                                    zdict_cache[slug], args.links))
    for c in conns:
        c.close()

    emit_text("\n---\n\n".join(parts) + "\n", args)


def _show_online(args):
    ddir = devdocs_dir()
    catalog = load_catalog(ddir)
    if not args.doc:
        fail(2, "--online show requires --doc <slug> and an explicit page path "
                 "(there is no offline index to resolve a bare ref against)")
    slug = args.doc[0]
    if catalog and slug not in catalog:
        close = [s for s in catalog if s.startswith(slug)][:3]
        fail(3, f"unknown DevDocs slug '{slug}'" +
                (f"; closest: {', '.join(close)}" if close else ""))
    head, frag = split_ref(args.ref)
    url = f"{online_base()}/{slug}/{head}.html"
    body = fetch_online(url)
    fragment = extract_anchor_html(body, frag) if frag else body
    if fragment is None:
        fail(1, f"anchor '{frag}' not found on {url} (online, not cached)")
    text = render_markdown(fragment, keep_links=args.links)
    header = f"## {head}#{frag if frag else ''} — {slug} (online, not cached)\n`{url}`\n\n"
    emit_text(header + text, args)


def cmd_page(args):
    ddir = devdocs_dir()
    if args.online:
        url = f"{online_base()}/{args.slug}/{args.path}.html"
        body = fetch_online(url)
        emit_text(render_markdown(body, keep_links=args.links), args)
        return

    slug, path = resolve_doc_arg(ddir, args.slug)
    conn = open_doc(path)
    row = conn.execute("SELECT id, path, raw_bytes FROM pages WHERE path=?", (args.path.lower(),)).fetchone()
    if not row:
        pcount = conn.execute("SELECT count(*) FROM pages").fetchone()[0]
        conn.close()
        fail(1, f"page '{args.path}' not found in {slug} ({pcount} pages searched)")
    pid, ppath, _ = row
    zdict = doc_zdict(conn)
    html_text = page_html(conn, pid, ppath, zdict)
    conn.close()
    emit_text(render_markdown(html_text, keep_links=args.links), args)


def cmd_doctor(_args):
    try:
        ddir = os.environ["DEVDOCS_DIR"]
    except KeyError:
        fail(3, "DEVDOCS_DIR is not set")
    if not os.path.isdir(ddir):
        fail(3, f"DEVDOCS_DIR={ddir!r} does not exist or is not a directory")
    docs = installed_docs(ddir)
    if not docs:
        fail(3, f"DEVDOCS_DIR={ddir!r} contains no readable *.sqlite files")
    bad = []
    for slug, path in sorted(docs.items()):
        try:
            conn = open_doc(path)
            zdict = doc_zdict(conn)
            rows = conn.execute("SELECT path, html, raw_bytes FROM pages ORDER BY RANDOM() LIMIT 20").fetchall()
            for ppath, blob, raw_bytes in rows:
                d = zlib.decompressobj(-15, zdict)
                out = d.decompress(blob) + d.flush()
                if len(out) != raw_bytes:
                    bad.append(f"{slug}:{ppath} checksum mismatch")
            conn.close()
            print(f"OK    {slug}")
        except (sqlite3.Error, zlib.error) as exc:
            bad.append(f"{slug}: {exc}")
            print(f"FAIL  {slug}: {exc}")
    if bad:
        fail(3, f"{len(bad)} problem(s) found", *bad)
    print(f"{len(docs)} doc(s) OK")


# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(prog="+devdocs", description=(__doc__ or "").splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)

    def add_common_output(sp):
        sp.add_argument("--output", metavar="FILE", help="write to FILE (or - for stdout, byte-exact)")
        sp.add_argument("--format", choices=["md", "json"], default="md")

    sp = sub.add_parser("docs", help="list installed docs")
    sp.add_argument("--all", action="store_true")
    add_common_output(sp)
    sp.set_defaults(func=cmd_docs)

    sp = sub.add_parser("search", help="fuzzy search entry names/paths")
    sp.add_argument("query")
    sp.add_argument("--doc", action="append", metavar="SLUG")
    sp.add_argument("--type")
    sp.add_argument("--limit", type=int, default=50)
    sp.add_argument("--online", action="store_true", help="always fails: DevDocs has no search API")
    add_common_output(sp)
    sp.set_defaults(func=cmd_search)

    sp = sub.add_parser("show", help="render one entry, anchor-scoped when possible")
    sp.add_argument("ref")
    sp.add_argument("--doc", action="append", metavar="SLUG")
    sp.add_argument("--max-render", type=int, default=DEFAULT_MAX_RENDER)
    sp.add_argument("--links", action="store_true")
    sp.add_argument("--online", action="store_true")
    add_common_output(sp)
    sp.set_defaults(func=cmd_show)

    sp = sub.add_parser("members", help="list every member of a page, names only")
    sp.add_argument("ref")
    sp.add_argument("--doc", metavar="SLUG")
    add_common_output(sp)
    sp.set_defaults(func=cmd_members)

    sp = sub.add_parser("page", help="render a whole page")
    sp.add_argument("slug")
    sp.add_argument("path")
    sp.add_argument("--links", action="store_true")
    sp.add_argument("--online", action="store_true")
    add_common_output(sp)
    sp.set_defaults(func=cmd_page)

    sp = sub.add_parser("types", help="list a doc's type/category index")
    sp.add_argument("doc")
    add_common_output(sp)
    sp.set_defaults(func=cmd_types)

    sp = sub.add_parser("doctor", help="verify DEVDOCS_DIR and every installed doc")
    sp.set_defaults(func=cmd_doctor)

    return p


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
