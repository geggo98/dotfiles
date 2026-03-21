#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "google-genai>=1.68.0",
# ]
# [tools.uv]
# exclude-newer = "2026-03-21T00:00:00Z"
# ///

import argparse
import os
import sys
from typing import List

from google import genai
from google.genai import types

MODEL_PRO = "gemini-3.1-pro-preview"
MODEL_FLASH = "gemini-3.1-flash-lite-preview"


def get_api_key_from_filesystem(key_name: str) -> str:
    """Read API key from ~/.config/sops-nix/secrets/ directory."""
    key_file = os.path.expanduser(f"~/.config/sops-nix/secrets/{key_name}")
    try:
        with open(key_file, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, IOError):
        return None


def add_citations(response) -> str:
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
                    links.append(f"[{i+1}]({web.uri})")
        if links:
            citation_str = "".join(links)
            text = text[:end_index] + citation_str + text[end_index:]
    return text


def list_sources(response) -> List[str]:
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
            title = getattr(web, "title", "") or web.uri
            out.append(f"[{i}] {title} — {web.uri}")
    return out


def main():
    p = argparse.ArgumentParser(
        description="Google Search-powered AI assistant using Gemini models with grounding and citations",
    )
    p.add_argument("prompt", nargs="*", help="User query to search and answer")
    p.add_argument(
        "--model",
        default=MODEL_PRO,
        help=f"Gemini model to use (default: {MODEL_PRO})",
    )
    p.add_argument(
        "--flash",
        action="store_true",
        help=f"Use {MODEL_FLASH} for faster responses",
    )
    p.add_argument(
        "--deep",
        action="store_true",
        help=f"Use {MODEL_PRO} for deeper analysis (default)",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Print raw JSON response with grounding metadata",
    )
    args = p.parse_args()

    prompt = " ".join(args.prompt).strip()
    if not prompt:
        print("Error: provide a prompt.", file=sys.stderr)
        sys.exit(2)

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
    config = types.GenerateContentConfig(tools=[grounding_tool])

    if args.flash:
        model = MODEL_FLASH
    elif args.deep:
        model = MODEL_PRO
    else:
        model = args.model

    try:
        resp = client.models.generate_content(
            model=model, contents=prompt, config=config
        )
    except Exception as e:
        print(f"Request failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Pretty print with inline citations.
    text_with_citations = add_citations(resp)
    print(text_with_citations.strip())

    # Also show deduplicated source list.
    sources = list_sources(resp)
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
