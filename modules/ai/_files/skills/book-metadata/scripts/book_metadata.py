#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# [tool.uv]
# exclude-newer = "30 days"
# ///
# SPDX-License-Identifier: GPL-3.0-only
# Wraps the calibre CLI tools (fetch-ebook-metadata, calibre-customize, calibre-debug).
# No calibre source is copied; see ../UPSTREAM.md for the reviewed upstream sources:
# https://github.com/kovidgoyal/calibre/tree/master/src/calibre/ebooks/metadata/sources
"""Fetch book metadata with calibre's metadata sources, and manage extra source plugins.

Exit codes: 0 ok · 1 no result · 2 usage · 4 blocked (needs --yes / cooldown) ·
5 calibre failed · 127 calibre not installed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

EX_NORESULT, EX_USAGE, EX_BLOCKED, EX_CALIBRE, EX_MISSING = 1, 2, 4, 5, 127

INDEX_URL = "https://code.calibre-ebook.com/plugins/plugins.json.bz2"
PLUGIN_URL = "https://code.calibre-ebook.com/plugins/"
COOLDOWN_DAYS = 14  # same floor as scripts/supply-chain.toml uses for npm / VS Code extensions
CALIBRE_DIRS = [Path.home() / "Applications/calibre.app/Contents/MacOS", Path("/Applications/calibre.app/Contents/MacOS")]

NS = {"dc": "http://purl.org/dc/elements/1.1/", "opf": "http://www.idpf.org/2007/opf"}
OPF_SCHEME = "{http://www.idpf.org/2007/opf}scheme"
# calibre reports ISO 639-3; the BookFusion API uses two-letter codes (see bookfusion-api/tests/mock_server.py).
LANG2 = {"eng": "en", "deu": "de", "fra": "fr", "spa": "es", "ita": "it", "nld": "nl", "por": "pt",
         "rus": "ru", "jpn": "ja", "zho": "zh", "pol": "pl", "swe": "sv", "dan": "da", "nor": "no"}


def die(code: int, msg: str) -> "None":
    print(f"book-metadata: {msg}", file=sys.stderr)
    sys.exit(code)


def calibre_tool(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for d in CALIBRE_DIRS:
        if (d / name).is_file():
            return str(d / name)
    die(EX_MISSING, f"{name} not found. Install calibre (Homebrew cask 'calibre') or put it on PATH.")
    return ""


def run(cmd: list[str], timeout: int, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    """Run a calibre tool. stderr goes to a 0600 file: calibre's Chromium prints ERROR lines that are not errors."""
    fd, errpath = tempfile.mkstemp(prefix="book-metadata-", suffix=".stderr")
    os.chmod(errpath, 0o600)
    try:
        with os.fdopen(fd, "wb") as errf:
            cp = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=errf, timeout=timeout,
                                env={**os.environ, **(env or {})})
    except subprocess.TimeoutExpired:
        die(EX_CALIBRE, f"{Path(cmd[0]).name} timed out after {timeout}s (stderr: {errpath})")
    cp.errpath = errpath  # type: ignore[attr-defined]
    return cp


def stderr_tail(cp: subprocess.CompletedProcess, n: int = 10) -> str:
    lines = Path(cp.errpath).read_text(errors="replace").splitlines()  # type: ignore[attr-defined]
    lines = [x for x in lines if "Skia Graphite" not in x]
    return "\n".join(lines[-n:])


# ------------------------------------------------------------------ fetch
def parse_opf(raw: bytes) -> dict:
    root = ET.fromstring(raw)
    md = root.find("opf:metadata", NS)
    if md is None:
        md = root.find("{*}metadata")
    if md is None:
        die(EX_CALIBRE, "OPF has no <metadata> element")

    def texts(tag: str) -> list[str]:
        return [e.text.strip() for e in md.findall(f"dc:{tag}", NS) if e.text and e.text.strip()]

    def first(tag: str) -> str | None:
        t = texts(tag)
        return t[0] if t else None

    ids = {}
    for e in md.findall("dc:identifier", NS):
        scheme = (e.get(OPF_SCHEME) or "").lower()
        if scheme and scheme not in ("calibre", "uuid") and e.text:
            ids[scheme] = e.text.strip()
    meta = {m.get("name"): m.get("content") for m in md.findall("opf:meta", NS)}
    publisher = first("publisher")
    if publisher:
        publisher = publisher.strip('"')  # Google Books wraps some publishers in literal quotes
    return {
        "title": first("title"),
        "authors": texts("creator"),
        "publisher": publisher,
        "pubdate": first("date"),
        "language": first("language"),
        "description": first("description"),
        "tags": list(dict.fromkeys(texts("subject"))),
        "series": meta.get("calibre:series"),
        "series_index": meta.get("calibre:series_index"),
        "identifiers": ids,
    }


def plain_text(raw_html: str | None) -> str | None:
    if not raw_html:
        return None
    t = re.sub(r"</p>\s*<p[^>]*>|<br\s*/?>", "\n\n", raw_html)
    t = re.sub(r"<[^>]+>", "", t)
    return html.unescape(t).strip() or None


def to_bookfusion(m: dict) -> dict:
    out: dict = {}
    if m["title"]:
        out["title"] = m["title"]
    if m["authors"]:
        out["authors"] = m["authors"]
    if plain_text(m["description"]):
        out["summary"] = plain_text(m["description"])
    if m["publisher"]:
        out["publisher_name"] = m["publisher"]
    if m["pubdate"]:
        out["published_at"] = m["pubdate"][:10]
    if m["language"]:
        lang = LANG2.get(m["language"].lower(), m["language"] if len(m["language"]) == 2 else None)
        if lang:
            out["language"] = lang
        else:
            print(f"book-metadata: unknown language code {m['language']!r}, omitted", file=sys.stderr)
    if m["tags"]:
        out["tags"] = m["tags"]
    if m["series"]:
        print(f"book-metadata: series {m['series']!r} #{m['series_index']} not mapped "
              "(BookFusion needs a series id; see bookfusion-api createSeries)", file=sys.stderr)
    return out


def cmd_fetch(a: argparse.Namespace) -> int:
    if not (a.isbn or a.title or a.authors):
        die(EX_USAGE, "fetch needs at least one of --isbn, --title, --authors")
    cmd = [calibre_tool("fetch-ebook-metadata"), "-o", "-d", str(a.timeout)]
    for flag, val in (("-i", a.isbn), ("-t", a.title), ("-a", a.authors)):
        if val:
            cmd += [flag, val]
    for ident in a.identifier or []:
        cmd += ["-I", ident]
    for s in a.source or []:
        cmd += ["-p", s]
    if a.cover:
        cmd += ["-c", str(a.cover)]
    for attempt in range(a.retries + 1):
        cp = run(cmd, timeout=a.timeout * 4 + 30)
        if cp.returncode == 0 and b"<package" in cp.stdout:
            break
        log = Path(cp.errpath).read_text(errors="replace")  # type: ignore[attr-defined]
        # Google Books answers HTTP 5xx now and then; that is a failed lookup, not "no result".
        if attempt < a.retries and re.search(r"HTTP Error 5\d\d|\b5\d\d\b.*(Server|Error)", log):
            print(f"book-metadata: server error, retry {attempt + 1}/{a.retries}", file=sys.stderr)
            time.sleep(0 if os.environ.get("BM_NO_SLEEP") else 2 * (attempt + 1))
            continue
        break
    if cp.returncode != 0 or b"<package" not in cp.stdout:
        log = Path(cp.errpath).read_text(errors="replace")  # type: ignore[attr-defined]
        if "No results found" in log and not re.search(r"HTTP Error 5\d\d", log):
            print("book-metadata: no results", file=sys.stderr)
            return EX_NORESULT
        print(f"book-metadata: fetch-ebook-metadata exit {cp.returncode}\n{stderr_tail(cp)}\n"
              f"(full stderr: {cp.errpath})", file=sys.stderr)  # type: ignore[attr-defined]
        return EX_CALIBRE
    if a.format == "opf":
        sys.stdout.write(cp.stdout.decode("utf-8"))
        return 0
    m = parse_opf(cp.stdout)
    if a.cover and Path(a.cover).is_file() and Path(a.cover).stat().st_size > 0:
        m["cover_path"] = str(a.cover)
    out = to_bookfusion(m) if a.format == "bookfusion" else m
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


# ------------------------------------------------------------------ plugins
def calibre_download(url: str, dest: Path, bz2: bool = False) -> None:
    """calibre pins its own certificates; plain curl/urllib fail on this host (verified: curl error 60)."""
    code = ("import bz2, os\n"
            "from calibre.utils.https import get_https_resource_securely as g\n"
            "raw = g(os.environ['BM_URL'])\n"
            "raw = bz2.decompress(raw) if os.environ['BM_BZ2'] == '1' else raw\n"
            "open(os.environ['BM_OUT'], 'wb').write(raw)\n")
    cp = run([calibre_tool("calibre-debug"), "-c", code], timeout=120,
             env={"BM_URL": url, "BM_OUT": str(dest), "BM_BZ2": "1" if bz2 else "0"})
    if cp.returncode != 0 or not dest.is_file() or dest.stat().st_size == 0:
        die(EX_CALIBRE, f"download failed: {url}\n{stderr_tail(cp)}")


def load_index() -> dict:
    cache = Path(tempfile.gettempdir()) / "book-metadata-plugin-index.json"
    if not cache.is_file() or time.time() - cache.stat().st_mtime > 86400:
        calibre_download(INDEX_URL, cache, bz2=True)
    return json.loads(cache.read_text())


def metadata_plugins(index: dict) -> list[dict]:
    return [v for v in index.values() if v.get("category") == "Metadata Source" and not v.get("deprecated")]


def age_days(entry: dict) -> int:
    d = dt.date.fromisoformat(entry["last_modified"][:10])
    return (dt.date.today() - d).days


def describe(v: dict) -> str:
    return (f"{v['name']}\tv{'.'.join(map(str, v['version']))}\tupdated {v['last_modified'][:10]}"
            f" ({age_days(v)}d)\t{v.get('description', '')[:100]}")


def cmd_sources(_: argparse.Namespace) -> int:
    cp = run([calibre_tool("calibre-customize"), "-l"], timeout=60)
    rows = [x for x in cp.stdout.decode().splitlines() if x.startswith("Metadata source")]
    if not rows:
        die(EX_CALIBRE, f"no metadata sources listed\n{stderr_tail(cp)}")
    print("name\tversion\tstate")
    for r in rows:
        m = re.match(r"Metadata source\s+(?P<name>.+?)\s{2,}\((?P<ver>[\d, ]+)\)\s+(?P<dis>True|False)", r)
        if m:
            print(f"{m['name']}\t{m['ver'].replace(', ', '.')}\t{'disabled' if m['dis'] == 'True' else 'enabled'}")
    return 0


def cmd_plugins(a: argparse.Namespace) -> int:
    if a.action in ("enable", "disable", "remove"):
        if a.action == "remove" and not a.yes:
            die(EX_BLOCKED, f"refusing to remove {a.name!r} without --yes (ask the user first)")
        flag = {"enable": "--enable-plugin", "disable": "--disable-plugin", "remove": "-r"}[a.action]
        cp = run([calibre_tool("calibre-customize"), flag, a.name], timeout=60)
        sys.stdout.write(cp.stdout.decode())
        if cp.returncode != 0:
            die(EX_CALIBRE, f"calibre-customize exit {cp.returncode}\n{stderr_tail(cp)}")
        return 0

    index = metadata_plugins(load_index())
    needle = a.name.lower()
    if a.action == "search":
        hits = [v for v in index if needle in v["name"].lower() or needle in v.get("description", "").lower()]
        for v in sorted(hits, key=lambda v: v["name"].lower()):
            print(describe(v))
        return 0 if hits else EX_NORESULT

    # install
    exact = [v for v in index if needle in (v["name"].lower(), v.get("index_name", "").lower())]
    if len(exact) != 1:
        die(EX_USAGE, f"{a.name!r}: {len(exact)} exact matches; use `plugins search` to find the name")
    v = exact[0]
    print(describe(v), file=sys.stderr)
    tmp = Path(tempfile.mkdtemp(prefix="book-metadata-plugin-"))
    zpath = tmp / v["file"]
    calibre_download(PLUGIN_URL + v["file"], zpath)
    sha = hashlib.sha256(zpath.read_bytes()).hexdigest()
    print(f"downloaded {zpath} ({zpath.stat().st_size} bytes) sha256={sha}", file=sys.stderr)
    if not a.yes:
        die(EX_BLOCKED, "third-party plugin code runs with your user rights. Ask the user, then re-run with --yes")
    if age_days(v) < COOLDOWN_DAYS and not a.allow_young:
        die(EX_BLOCKED, f"plugin is {age_days(v)} days old, cooldown is {COOLDOWN_DAYS}. "
                        "Wait, or get the user's explicit OK and pass --allow-young")
    cp = run([calibre_tool("calibre-customize"), "-a", str(zpath)], timeout=120)
    sys.stdout.write(cp.stdout.decode())
    if cp.returncode != 0:
        die(EX_CALIBRE, f"calibre-customize exit {cp.returncode}\n{stderr_tail(cp)}")
    return 0


# ------------------------------------------------------------------ main
def main() -> int:
    p = argparse.ArgumentParser(prog="book-metadata", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="look a book up with calibre's metadata sources")
    f.add_argument("--isbn")
    f.add_argument("--title")
    f.add_argument("--authors")
    f.add_argument("--identifier", action="append", metavar="K:V", help="e.g. asin:B0082BAJA0 (repeatable)")
    f.add_argument("--source", action="append", metavar="NAME", help="restrict to a source, see `sources` (repeatable)")
    f.add_argument("--cover", type=Path, help="save the cover image here")
    f.add_argument("--timeout", type=int, default=30)
    f.add_argument("--retries", type=int, default=2, help="repeat after an HTTP 5xx from a source (default 2)")
    f.add_argument("--format", choices=["json", "opf", "bookfusion"], default="json")
    f.set_defaults(fn=cmd_fetch)

    s = sub.add_parser("sources", help="list installed metadata sources and whether they are enabled")
    s.set_defaults(fn=cmd_sources)

    pl = sub.add_parser("plugins", help="search, install, enable, disable, remove source plugins")
    pl.add_argument("action", choices=["search", "install", "enable", "disable", "remove"])
    pl.add_argument("name", help="search term, or exact plugin name")
    pl.add_argument("--yes", action="store_true", help="confirm install/remove (ask the user first)")
    pl.add_argument("--allow-young", action="store_true", help=f"skip the {COOLDOWN_DAYS}-day cooldown")
    pl.set_defaults(fn=cmd_plugins)

    a = p.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
