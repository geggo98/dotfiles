#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "google-genai>=1.68.0",
#   "requests>=2.31.0",
# ]
# [tool.uv]
# exclude-newer = "30 days"
# ///

import argparse
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, List

import requests
from google import genai
from google.genai import types

GROUNDING_REDIRECT = "vertexaisearch.cloud.google.com/grounding-api-redirect/"

_session = requests.Session()


def resolve_grounding_url(url: str) -> str:
    if GROUNDING_REDIRECT not in url:
        return url
    try:
        resp = _session.head(url, allow_redirects=True, timeout=5)
        return resp.url
    except requests.RequestException:
        return url


def resolve_urls(urls: List[str], max_workers: int = 5) -> List[str]:
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        return list(pool.map(resolve_grounding_url, urls))


def build_url_map(response, max_workers: int = 5) -> Dict[str, str]:
    """Collect all grounding URLs from the response and resolve them in one batch."""
    cands = getattr(response, "candidates", None)
    if not cands or not cands[0]:
        return {}
    gmeta = getattr(cands[0], "grounding_metadata", None)
    if not gmeta:
        return {}
    chunks = getattr(gmeta, "grounding_chunks", []) or []
    raw_urls = []
    for ch in chunks:
        web = getattr(ch, "web", None)
        if web and getattr(web, "uri", None):
            raw_urls.append(web.uri)
    if not raw_urls:
        return {}
    resolved = resolve_urls(raw_urls, max_workers=max_workers)
    return dict(zip(raw_urls, resolved))

MODEL = "gemini-3.8-flash"

# The depth knob is the THINKING LEVEL, not the model name. gemini-3.8-flash is
# GA, grounds against Google Search, and accepts low/medium/high. Two models of
# two generations (gemini-3.1-pro-preview / -flash-lite-preview) used to encode
# the same axis, which meant two names that could age apart -- and both of them
# had.
#
# `minimal` is deliberately ABSENT: this model rejects it with an error, so it
# belongs in argparse's choices-check, where it costs nothing, rather than in a
# request that travels to Google to be refused there.
#
# medium is the API's own default for Gemini 3 Flash. It is restated here so the
# stderr line below can name the level that is actually in force instead of
# reporting "unset" and leaving the reader to guess.
THINKING_LEVELS = {
    "low": types.ThinkingLevel.LOW,
    "medium": types.ThinkingLevel.MEDIUM,
    "high": types.ThinkingLevel.HIGH,
}
DEFAULT_THINKING = "medium"


def get_api_key_from_filesystem(key_name: str) -> str:
    """Read API key from ~/.config/sops-nix/secrets/ directory."""
    key_file = os.path.expanduser(f"~/.config/sops-nix/secrets/{key_name}")
    try:
        with open(key_file, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, IOError):
        return None


def add_citations(response, url_map: Dict[str, str] | None = None) -> str:
    """
    Insert inline citation markers after grounded segments.
    Format: text ...[1](url)[3](url)...
    Follows the pattern from the official docs.
    """
    text = response.text or ""
    cands = getattr(response, "candidates", None)
    if not cands or not cands[0]:
        return text

    gmeta = getattr(cands[0], "grounding_metadata", None)
    if not gmeta:
        return text

    supports = getattr(gmeta, "grounding_supports", []) or []
    chunks = getattr(gmeta, "grounding_chunks", []) or []

    # Avoid shifting indices by inserting from the end.
    supports_sorted = sorted(supports, key=lambda s: s.segment.end_index, reverse=True)
    for s in supports_sorted:
        end_index = s.segment.end_index
        idxs: List[int] = list(getattr(s, "grounding_chunk_indices", []) or [])
        if not idxs:
            continue
        links: List[str] = []
        for i in idxs:
            if 0 <= i < len(chunks):
                web = getattr(chunks[i], "web", None)
                if web and getattr(web, "uri", None):
                    uri = url_map.get(web.uri, web.uri) if url_map else web.uri
                    links.append(f"[{i+1}]({uri})")
        if links:
            citation_str = "".join(links)
            text = text[:end_index] + citation_str + text[end_index:]
    return text


def list_sources(response, url_map: Dict[str, str] | None = None) -> List[str]:
    cands = getattr(response, "candidates", None)
    if not cands or not cands[0]:
        return []
    gmeta = getattr(cands[0], "grounding_metadata", None)
    if not gmeta:
        return []
    chunks = getattr(gmeta, "grounding_chunks", []) or []
    out = []
    for i, ch in enumerate(chunks, start=1):
        web = getattr(ch, "web", None)
        if web and getattr(web, "uri", None):
            uri = url_map.get(web.uri, web.uri) if url_map else web.uri
            title = getattr(web, "title", "") or uri
            out.append(f"[{i}] {title} — {uri}")
    return out


def main():
    p = argparse.ArgumentParser(
        description="Google Search-powered AI assistant using Gemini models with grounding and citations",
    )
    p.add_argument("prompt", nargs="*", help="User query to search and answer")
    p.add_argument(
        "--model",
        default=MODEL,
        help=f"Gemini model to use (default: {MODEL})",
    )
    p.add_argument(
        "--flash",
        action="store_true",
        help="Shallow and fast: thinking level low",
    )
    p.add_argument(
        "--deep",
        action="store_true",
        help="Deeper synthesis: thinking level high",
    )
    p.add_argument(
        "--thinking-level",
        choices=sorted(THINKING_LEVELS),
        default=None,
        metavar="{low,medium,high}",
        help=f"Explicit thinking level; beats --flash/--deep "
        f"(default: {DEFAULT_THINKING})",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Print raw JSON response with grounding metadata",
    )
    p.add_argument(
        "--no-resolve",
        action="store_true",
        help="Skip resolving shortened grounding redirect URLs",
    )
    p.add_argument(
        "--resolve-workers",
        type=int,
        default=5,
        metavar="N",
        help="Max parallel workers for URL resolution (default: 5)",
    )
    args = p.parse_args()

    prompt = " ".join(args.prompt).strip()
    if not prompt:
        print("Error: provide a prompt.", file=sys.stderr)
        sys.exit(2)

    # --flash and --deep are opposite ends of one knob, so asking for both is a
    # contradiction, not a preference. The old code let --flash win silently.
    if args.thinking_level:
        level_name = args.thinking_level
    elif args.flash and args.deep:
        print(
            "Error: --flash and --deep are opposites; pass one, "
            "or --thinking-level to be explicit.",
            file=sys.stderr,
        )
        sys.exit(2)
    elif args.flash:
        level_name = "low"
    elif args.deep:
        level_name = "high"
    else:
        level_name = DEFAULT_THINKING

    model = args.model

    # API key loading follows official SDK behavior:
    # prefers GOOGLE_API_KEY if both are set.
    api_key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
    if not api_key:
        # Try to read from filesystem
        api_key = get_api_key_from_filesystem("gemini_api_key")

    if not api_key:
        print(
            "Error: set GEMINI_API_KEY or GOOGLE_API_KEY, or place key in ~/.config/sops-nix/secrets/gemini_api_key",
            file=sys.stderr,
        )
        sys.exit(2)

    client = genai.Client(api_key=api_key)

    # Enable Google Search grounding.
    grounding_tool = types.Tool(google_search=types.GoogleSearch())
    config = types.GenerateContentConfig(
        tools=[grounding_tool],
        thinking_config=types.ThinkingConfig(
            thinking_level=THINKING_LEVELS[level_name]
        ),
    )

    # stderr, never stdout: stdout is the Markdown document the skill promises,
    # and something downstream parses it. Without this line the two knobs are
    # indistinguishable from outside -- a --deep that quietly did not take looks
    # exactly like one that did.
    print(f"gemini_research: model={model} thinking_level={level_name}", file=sys.stderr)

    try:
        resp = client.models.generate_content(
            model=model, contents=prompt, config=config
        )
    except Exception as e:
        print(f"Request failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Resolve shortened grounding URLs in one batch.
    url_map = None
    if not args.no_resolve:
        url_map = build_url_map(resp, max_workers=args.resolve_workers)

    # Pretty print with inline citations.
    text_with_citations = add_citations(resp, url_map=url_map)
    print(text_with_citations.strip())

    # Also show deduplicated source list.
    sources = list_sources(resp, url_map=url_map)
    if sources:
        print("\nSources:")
        for line in sources:
            print(f"- {line}")

    if args.json:
        # Emit the raw JSON for debugging or custom UIs.
        import json

        print("\n--- RAW RESPONSE JSON ---")
        print(json.dumps(resp.model_dump(mode="json"), indent=2))


if __name__ == "__main__":
    main()
