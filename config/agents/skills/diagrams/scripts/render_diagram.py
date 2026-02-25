#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pydantic",
# ]
# [tool.uv]
# exclude-newer = "2026-02-01T00:00:00Z"
# ///

# Hint: Lock dependencies with `uv lock --script ...`

"""
render_diagrams.py

Extract and render PlantUML and Mermaid blocks from files, directories, or stdin.

Supported sources:
  - PlantUML blocks delimited by @startuml ... @enduml
  - Markdown fenced code blocks:
      ```plantuml / ```puml / ```uml
      ```mermaid

Default output:
  - A self-contained HTML preview (images embedded as data: URIs)
  - No image files are written unless --out-dir is provided.

Error handling:
  - PlantUML generally embeds syntax errors into the rendered image. If no image
    is produced, this script generates an error image.
  - Mermaid CLI (mmdc) may fail without producing an image; this script generates
    an error image containing the CLI stderr/stdout.
"""
from __future__ import annotations

import argparse
import base64
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Tuple

from pydantic import BaseModel, ConfigDict


class DiagramBlock(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: int
    language: str          # "plantuml" | "mermaid"
    origin: str            # "startuml" | "fenced"
    file: str              # path or "<stdin>"
    start_line: int
    end_line: int
    source: str


class RenderResult(BaseModel):
    model_config = ConfigDict(frozen=False)

    block: DiagramBlock
    ok: bool
    fmt: str               # "png" | "svg"
    bytes: bytes           # serialised as base64 in JSON output
    renderer: str          # "plantuml" | "mmdc" | "npx:@mermaid-js/mermaid-cli" | "error"
    stderr: str = ""
    stdout: str = ""
    exit_code: int = 0
    output_path: Optional[str] = None  # relative path (for HTML) if written to disk
    width: Optional[int] = None
    height: Optional[int] = None


PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _get_image_dimensions(fmt: str, data: bytes) -> Tuple[Optional[int], Optional[int]]:
    """Return (width, height) in pixels for PNG or SVG data, or (None, None) if undetectable."""
    if fmt == "png" and len(data) >= 24:
        import struct
        w, h = struct.unpack(">II", data[16:24])
        return w, h
    if fmt == "svg":
        text = data[:4096].decode("utf-8", errors="replace")
        w = h = None
        m = re.search(r'<svg[^>]+\bwidth=["\']([0-9]+(?:\.[0-9]+)?)', text, re.IGNORECASE)
        if m:
            w = int(float(m.group(1)))
        m = re.search(r'<svg[^>]+\bheight=["\']([0-9]+(?:\.[0-9]+)?)', text, re.IGNORECASE)
        if m:
            h = int(float(m.group(1)))
        if w is None or h is None:
            # viewBox fallback: viewBox="minX minY width height"
            m = re.search(r'<svg[^>]+\bviewBox=["\']([0-9.]+)[ ,]+([0-9.]+)[ ,]+([0-9.]+)[ ,]+([0-9.]+)', text, re.IGNORECASE)
            if m:
                vw, vh = int(float(m.group(3))), int(float(m.group(4)))
                w = w if w is not None else vw
                h = h if h is not None else vh
        return w, h
    return None, None


# noinspection SpellCheckingInspection
FALLBACK_PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+XK6UAAAAASUVORK5CYII="
)


def _line_number(text: str, idx: int) -> int:
    # 1-based
    return text.count("\n", 0, idx) + 1


def _ensure_plantuml_wrapped(body: str) -> str:
    if re.search(r"(?mi)^[ \t]*@startuml\b", body):
        return body
    body_stripped = body.strip("\n")
    return f"@startuml\n{body_stripped}\n@enduml\n"


def extract_startuml_blocks(text: str) -> List[Tuple[str, int, int]]:
    """
    Returns a list of tuples: (source, start_line, end_line) with 1-based line numbers.
    """
    blocks: List[Tuple[str, int, int]] = []
    for m in re.finditer(r"@startuml\b.*?@enduml\b", text, flags=re.IGNORECASE | re.DOTALL):
        start = _line_number(text, m.start())
        end = _line_number(text, m.end())
        blocks.append((m.group(0), start, end))
    return blocks


_FENCE_OPEN_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})[ \t]*([A-Za-z0-9_+\-]+)?[ \t]*$")


def extract_fenced_blocks(text: str) -> List[Tuple[str, str, int, int]]:
    """
    Returns a list of tuples: (language, source, start_line, end_line)
    start_line/end_line are 1-based line numbers of the fenced block *content*.
    """
    lines = text.splitlines()
    out: List[Tuple[str, str, int, int]] = []
    i = 0
    while i < len(lines):
        m = _FENCE_OPEN_RE.match(lines[i])
        if not m:
            i += 1
            continue

        fence = m.group(1)
        info = (m.group(2) or "").strip().lower()
        lang: Optional[str] = None
        if info in ("plantuml", "puml", "uml"):
            lang = "plantuml"
        elif info == "mermaid":
            lang = "mermaid"

        if not lang:
            i += 1
            continue

        content_start_line = i + 2  # first content line (1-based)
        i += 1
        content_lines: List[str] = []
        while i < len(lines) and not re.match(rf"^[ \t]*{re.escape(fence)}[ \t]*$", lines[i]):
            content_lines.append(lines[i])
            i += 1
        content_end_line = i  # last content line (1-based); may be < start_line for empty blocks

        content = "\n".join(content_lines)
        if lang == "plantuml":
            content = _ensure_plantuml_wrapped(content)

        out.append((lang, content, content_start_line, max(content_start_line - 1, content_end_line)))

        # Skip closing fence if present
        if i < len(lines) and re.match(rf"^[ \t]*{re.escape(fence)}[ \t]*$", lines[i]):
            i += 1
        else:
            # Unterminated fence; stop parsing
            break
    return out


def parse_only_spec(spec: str) -> List[int]:
    """
    Parse a spec like: "1,3-5,8" into a sorted list of unique positive ints.
    """
    out: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a_s, b_s = part.split("-", 1)
            a, b = int(a_s), int(b_s)
            if a <= 0 or b <= 0:
                raise ValueError("indices must be positive")
            lo, hi = (a, b) if a <= b else (b, a)
            out.update(range(lo, hi + 1))
        else:
            v = int(part)
            if v <= 0:
                raise ValueError("indices must be positive")
            out.add(v)
    return sorted(out)


def _make_error_png(title: str, message: str, width_px: int = 1200) -> bytes:
    """
    Create a PNG with the error text rendered into it.
    Requires Pillow. If Pillow isn't available, returns a tiny valid PNG.
    """
    try:
        from PIL import Image, ImageDraw, ImageFont  # type: ignore
    except ImportError:
        return FALLBACK_PNG_1X1

    font = ImageFont.load_default()

    header = title.strip()
    body = message.strip()

    raw_lines = [header, ""] + (body.splitlines() if body else ["(no details)"])

    wrapped_lines: List[str] = []
    for line in raw_lines:
        if not line.strip():
            wrapped_lines.append("")
            continue
        wrapped_lines.extend(
            textwrap.wrap(
                line,
                width=140,
                replace_whitespace=False,
                drop_whitespace=False,
            ) or [""]
        )

    line_height = 16
    margin = 20
    height_px = margin * 2 + line_height * (len(wrapped_lines) + 1)

    img = Image.new("RGB", (width_px, height_px), color=(255, 245, 245))
    draw = ImageDraw.Draw(img)

    y = margin
    for ln in wrapped_lines:
        draw.text((margin, y), ln, fill=(60, 0, 0), font=font)
        y += line_height

    with tempfile.SpooledTemporaryFile() as tmp:
        img.save(tmp, format="PNG")
        tmp.seek(0)
        return tmp.read()


def _find_plantuml_base_cmd() -> Tuple[List[str], str]:
    """
    Returns (base_cmd, renderer_name).

    base_cmd excludes output/pipe flags; caller appends.
    """
    plantuml = shutil.which("plantuml")
    if plantuml:
        return [str(plantuml)], "plantuml"

    jar = os.environ.get("PLANTUML_JAR") or os.environ.get("PLANTUML_JAR_PATH")
    if jar and Path(jar).exists():
        java = shutil.which("java")
        if not java:
            return [], "missing-java"
        return [str(java), "-jar", jar], "java-plantuml-jar"

    candidates = [
        Path.cwd() / "plantuml.jar",
        Path(__file__).resolve().parent / "plantuml.jar",
        Path.home() / "plantuml.jar",
        Path("/usr/share/plantuml/plantuml.jar"),
        Path("/usr/share/java/plantuml.jar"),
        ]
    jar_path = next((p for p in candidates if p.exists()), None)
    if jar_path:
        java = shutil.which("java")
        if not java:
            return [], "missing-java"
        return [str(java), "-jar", str(jar_path)], "java-plantuml-jar"

    return [], "missing-plantuml"


def _find_mmdc_base_cmd() -> Tuple[List[str], str]:
    """
    Returns (cmd_prefix, renderer_name). cmd_prefix should be followed by CLI args.

    Preference order:
      1) mmdc if installed
      2) npx -y @mermaid-js/mermaid-cli (downloads on demand)
    """
    mmdc = shutil.which("mmdc")
    if mmdc:
        return [str(mmdc)], "mmdc"

    npx = shutil.which("npx")
    if npx:
        return [str(npx), "-y", "@mermaid-js/mermaid-cli"], "npx:@mermaid-js/mermaid-cli"

    return [], "missing-mmdc"


def _run_cmd(cmd: List[str], *, input_bytes: bytes, timeout_s: int) -> Tuple[int, bytes, bytes]:
    try:
        proc = subprocess.run(
            cmd,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_s,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as e:
        stdout = e.stdout or b""
        stderr = (e.stderr or b"") + b"\n[timeout]"
        return 124, stdout, stderr
    except FileNotFoundError:
        return 127, b"", b"command not found"


def render_plantuml(source: str, fmt: str, timeout_s: int) -> Tuple[bool, str, bytes, str, str, int]:
    base_cmd, name = _find_plantuml_base_cmd()
    if not base_cmd:
        msg = (
            "PlantUML renderer not found.\n\n"
            "Install `plantuml` or set PLANTUML_JAR=/path/to/plantuml.jar.\n"
            "Also ensure `java` is available."
        )
        return False, "error", _make_error_png("PlantUML not available", msg), msg, "", 127

    fmt_flag = f"-t{fmt}"
    cmd = base_cmd + [fmt_flag, "-pipe", "-charset", "UTF-8"]
    rc, out, err = _run_cmd(cmd, input_bytes=source.encode("utf-8"), timeout_s=timeout_s)
    stderr = err.decode("utf-8", errors="replace")
    stdout_text = ""

    if fmt == "png" and out.startswith(PNG_MAGIC):
        # PlantUML usually includes syntax errors inside the PNG output; non-zero rc still means "error".
        return rc == 0, name, out, stderr, stdout_text, rc

    if fmt == "svg" and out.lstrip().startswith(b"<"):
        return rc == 0, name, out, stderr, stdout_text, rc

    # No valid image -> create an error image from stderr/stdout.
    stdout_text = out[:4000].decode("utf-8", errors="replace")
    detail = (stderr or "").strip()
    if stdout_text.strip():
        detail = (detail + "\n\n--- stdout ---\n" + stdout_text).strip()
    return False, "error", _make_error_png("PlantUML render failed", detail or "No output produced."), stderr, stdout_text, rc


def render_mermaid(source: str, fmt: str, timeout_s: int) -> Tuple[bool, str, bytes, str, str, int]:
    base_cmd, name = _find_mmdc_base_cmd()
    if not base_cmd:
        msg = (
            "Mermaid renderer not found.\n\n"
            "Install `@mermaid-js/mermaid-cli` (provides `mmdc`) or ensure `npx` is available."
        )
        return False, "error", _make_error_png("Mermaid not available", msg), msg, "", 127

    # mmdc needs --outputFormat when writing to stdout ("-") because it can't infer it from an extension.
    cmd = base_cmd + ["--input", "-", "--output", "-", "--outputFormat", fmt, "--quiet"]
    rc, out, err = _run_cmd(cmd, input_bytes=source.encode("utf-8"), timeout_s=timeout_s)
    stderr = err.decode("utf-8", errors="replace")

    if fmt == "png" and rc == 0 and out.startswith(PNG_MAGIC):
        return True, name, out, stderr, "", rc

    if fmt == "svg" and rc == 0 and out.lstrip().startswith(b"<"):
        return True, name, out, stderr, "", rc

    stdout_text = out[:4000].decode("utf-8", errors="replace")
    detail = (stderr or "").strip()
    if stdout_text.strip():
        detail = (detail + "\n\n--- stdout ---\n" + stdout_text).strip()
    return False, "error", _make_error_png("Mermaid render failed", detail or "No output produced."), stderr, stdout_text, rc


def render_block(block: DiagramBlock, fmt: str, timeout_s: int) -> RenderResult:
    if block.language == "plantuml":
        ok, renderer, out_bytes, stderr, stdout, rc = render_plantuml(block.source, fmt, timeout_s)
    elif block.language == "mermaid":
        ok, renderer, out_bytes, stderr, stdout, rc = render_mermaid(block.source, fmt, timeout_s)
    else:
        raise ValueError(f"Unknown language: {block.language}")

    actual_fmt = fmt
    if renderer == "error":
        actual_fmt = "png"  # error images are PNGs

    width, height = _get_image_dimensions(actual_fmt, out_bytes)

    return RenderResult(
        block=block,
        ok=ok,
        fmt=actual_fmt,
        bytes=out_bytes,
        renderer=renderer,
        stderr=stderr,
        stdout=stdout,
        exit_code=rc,
        width=width,
        height=height,
    )


def _slug(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    return s or "diagram"


def _mime_for(fmt: str) -> str:
    if fmt == "png":
        return "image/png"
    if fmt == "svg":
        return "image/svg+xml"
    return "application/octet-stream"


def build_html(results: Sequence[RenderResult], *, embed: bool, title: str) -> str:
    parts: List[str] = ["<!doctype html>", "<html><head><meta charset='utf-8'>", f"<title>{html.escape(title)}</title>", """
<style>
body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 16px; }
.card { border: 1px solid #ddd; border-radius: 10px; padding: 12px; margin: 12px 0; }
.meta { font-size: 13px; color: #555; margin-bottom: 8px; }
img { max-width: 100%; height: auto; border: 1px solid #eee; border-radius: 6px; }
pre { background: #f7f7f7; padding: 10px; overflow: auto; border-radius: 6px; }
details { margin-top: 8px; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; background: #eee; }
.badge.ok { background: #e6ffed; }
.badge.err { background: #ffeef0; }
</style>
""", "</head><body>", f"<h1>{html.escape(title)}</h1>"]

    ok_count = sum(1 for r in results if r.ok)
    err_count = len(results) - ok_count
    parts.append(f"<p class='meta'>Rendered: {len(results)} &nbsp;|&nbsp; OK: {ok_count} &nbsp;|&nbsp; Errors: {err_count}</p>")

    for r in results:
        b = r.block
        status = "ok" if r.ok else "err"
        parts.append("<div class='card'>")
        dims = f"{r.width}×{r.height}px" if r.width is not None and r.height is not None else "unknown"
        parts.append(
            "<div class='meta'>"
            f"<span class='badge {status}'>{'OK' if r.ok else 'ERROR'}</span> "
            f"&nbsp;# {b.id} &nbsp;|&nbsp; {html.escape(b.language)} ({html.escape(b.origin)}) "
            f"&nbsp;|&nbsp; {html.escape(b.file)}:{b.start_line}-{b.end_line} "
            f"&nbsp;|&nbsp; renderer: {html.escape(r.renderer)} "
            f"&nbsp;|&nbsp; exit: {r.exit_code} "
            f"&nbsp;|&nbsp; dimensions: {dims}"
            "</div>"
        )

        if embed:
            mime = _mime_for(r.fmt)
            data_uri = f"data:{mime};base64,{base64.b64encode(r.bytes).decode('ascii')}"
            parts.append(f"<img src='{data_uri}' alt='diagram {b.id}'>")
        else:
            parts.append(f"<img src='{html.escape(r.output_path or '')}' alt='diagram {b.id}'>")

        parts.append("<details><summary>Source</summary>")
        parts.append(f"<pre>{html.escape(b.source)}</pre>")
        parts.append("</details>")

        if (r.stderr or "").strip() or (r.stdout or "").strip():
            parts.append("<details><summary>Renderer output</summary>")
            if (r.stderr or "").strip():
                parts.append("<h4>stderr</h4>")
                parts.append(f"<pre>{html.escape(r.stderr)}</pre>")
            if (r.stdout or "").strip():
                parts.append("<h4>stdout</h4>")
                parts.append(f"<pre>{html.escape(r.stdout)}</pre>")
            parts.append("</details>")

        parts.append("</div>")

    parts.append("</body></html>")
    return "\n".join(parts)


def list_blocks(blocks: Sequence[DiagramBlock], *, as_json: bool = False) -> None:
    if not blocks:
        print("No matching diagram blocks found.", file=sys.stderr)
        return
    if as_json:
        print(json.dumps([{k: v for k, v in b.model_dump().items() if k != "source"} for b in blocks], indent=2, ensure_ascii=False))
        return
    print("ID\tLANG\tORIGIN\tFILE:LINES")
    for b in blocks:
        print(f"{b.id}\t{b.language}\t{b.origin}\t{b.file}:{b.start_line}-{b.end_line}")


def iter_input_files(paths: Sequence[str]) -> Iterable[Path]:
    for p in paths:
        pp = Path(p)
        if pp.is_dir():
            for child in pp.rglob("*"):
                if child.is_file():
                    yield child
        elif pp.is_file():
            yield pp


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="render_diagrams.py")
    ap.add_argument("paths", nargs="*", help="Files or directories to scan.")
    ap.add_argument("--stdin", action="store_true", help="Read input from stdin (useful for pasted snippets).")
    ap.add_argument("--select", choices=["plantuml", "mermaid", "both"], default="both",
                    help="Which diagram language(s) to render.")
    ap.add_argument("--blocks", choices=["startuml", "fenced", "all"], default="all",
                    help="Which block types to extract.")
    ap.add_argument("--only", default=None, help="Render only these diagram IDs (after extraction), e.g. '1,3-5'.")
    ap.add_argument("--list", action="store_true", help="List extracted blocks and exit.")
    ap.add_argument("--format", choices=["png", "svg"], default="png", dest="fmt", help="Output format.")
    ap.add_argument("--out-dir", default=None, help="Write images to this directory (optional).")
    ap.add_argument("--html", default=None, help="Write HTML preview to this path (default: temp file).")
    ap.add_argument("--no-html", action="store_true", help="Do not write an HTML preview.")
    ap.add_argument("--json", action="store_true", default=False,
                    help="Print results as JSON to stdout. Implies --no-html unless --html is set explicitly.")
    ap.add_argument("--detail", choices=["full", "minimal"], default="minimal",
                    help="Detail level for --json output: 'minimal' (default, omits source/bytes) or 'full'.")
    ap.add_argument("--timeout", type=int, default=60, help="Per-diagram render timeout (seconds).")
    args = ap.parse_args(argv)

    if not args.paths and not args.stdin:
        ap.print_help()
        return 0

    select_langs = {"plantuml", "mermaid"} if args.select == "both" else {args.select}
    block_kinds = {"startuml", "fenced"} if args.blocks == "all" else {args.blocks}

    extracted: List[DiagramBlock] = []
    next_id = 1

    def add_block(language: str, origin: str, file: str, start_line: int, end_line: int, source: str) -> None:
        nonlocal next_id
        extracted.append(DiagramBlock(
            id=next_id,
            language=language,
            origin=origin,
            file=file,
            start_line=start_line,
            end_line=end_line,
            source=source,
        ))
        next_id += 1

    if args.stdin or not args.paths:
        data = sys.stdin.read()
        if not data.strip():
            print("No input provided on stdin and no paths given.", file=sys.stderr)
            return 2
        file_label = "<stdin>"
        if "startuml" in block_kinds:
            for src, sl, el in extract_startuml_blocks(data):
                add_block("plantuml", "startuml", file_label, sl, el, src)
        if "fenced" in block_kinds:
            for lang, src, sl, el in extract_fenced_blocks(data):
                add_block(lang, "fenced", file_label, sl, el, src)
    else:
        for file_path in iter_input_files(args.paths):
            try:
                text = file_path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue

            file_label = str(file_path)
            if "startuml" in block_kinds:
                for src, sl, el in extract_startuml_blocks(text):
                    add_block("plantuml", "startuml", file_label, sl, el, src)
            if "fenced" in block_kinds:
                for lang, src, sl, el in extract_fenced_blocks(text):
                    add_block(lang, "fenced", file_label, sl, el, src)

    extracted = [b for b in extracted if b.language in select_langs]

    if args.list:
        list_blocks(extracted, as_json=args.json)
        return 0

    if not extracted:
        print("No matching diagram blocks found.", file=sys.stderr)
        return 1

    only_ids: Optional[set[int]] = None
    if args.only:
        try:
            only_ids = set(parse_only_spec(args.only))
        except ValueError as e:
            print(f"Invalid --only spec: {e}", file=sys.stderr)
            return 2

    blocks_to_render = [b for b in extracted if only_ids is None or b.id in only_ids]
    if not blocks_to_render:
        print("No blocks selected (after applying --only).", file=sys.stderr)
        return 1

    results: List[RenderResult] = [render_block(b, args.fmt, args.timeout) for b in blocks_to_render]
    had_errors = any(not r.ok for r in results)

    embed = args.out_dir is None
    out_dir = Path(args.out_dir).expanduser().resolve() if args.out_dir else None

    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        for r in results:
            base_name = Path(r.block.file).name if r.block.file != "<stdin>" else "stdin"
            base = f"{_slug(base_name)}-{r.block.id}-{r.block.language}"
            out_file = out_dir / f"{base}.{r.fmt}"
            out_file.write_bytes(r.bytes)
            r.output_path = out_file.name  # HTML uses relative path (same folder)

    # `--json` suppresses the HTML preview unless `--html` was given explicitly.
    suppress_html = args.no_html or (args.json and not args.html)

    if not suppress_html:
        if args.html:
            html_path = Path(args.html).expanduser().resolve()
        else:
            if out_dir:
                html_path = out_dir / "diagram-preview.html"
            else:
                stamp = time.strftime("%Y%m%d-%H%M%S")
                html_path = Path(tempfile.gettempdir()) / f"diagram-preview-{stamp}.html"

        html_doc = build_html(results, embed=embed, title="Diagram preview (PlantUML + Mermaid)")
        html_path.write_text(html_doc, encoding="utf-8")
        if not args.json:
            print(str(html_path))

    ok_count = sum(1 for r in results if r.ok)
    err_count = len(results) - ok_count

    if args.json:
        full_json = args.detail == "full"

        def _result_to_dict(r: RenderResult) -> dict:
            d = r.model_dump()
            if full_json:
                d["bytes"] = base64.b64encode(r.bytes).decode("ascii")
            else:
                del d["bytes"]
                d["block"] = {k: v for k, v in d["block"].items() if k != "source"}
            return d

        payload = {
            "summary": {
                "total": len(results),
                "ok": ok_count,
                "errors": err_count,
            },
            "results": [_result_to_dict(r) for r in results],
        }
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        print(f"Rendered {len(results)} diagrams: OK={ok_count}, ERRORS={err_count}", file=sys.stderr)

    return 1 if had_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())