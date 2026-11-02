#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   # >=2.3.0: the Interactions API (client.interactions) arrived in the 2.x line.
#   #   <3: the next major is a separate migration with real calls, not a re-lock.
#   "google-genai>=2.3.0,<3",
#   "requests>=2.31.0",
# ]
# [tool.uv]
# exclude-newer = "30 days"
# ///

import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List, Optional, Tuple

import requests
from google import genai

GROUNDING_REDIRECT = "vertexaisearch.cloud.google.com/grounding-api-redirect/"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

# HTTP statuses that mean "this account cannot pay right now", not "the request
# is wrong": 402 is the exhausted prepayment ("prepayment credits are depleted"),
# 429 is quota. Only these may switch the backend; a 400 or a bad model name
# would fail identically on the other side and must not be papered over.
FALLBACK_STATUSES = {402, 429}

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


MODEL = "gemini-3.8-flash"
MODEL_DEEPER = "gemini-4-argon"

# The depth knob is the THINKING LEVEL, not the model name. gemini-3.8-flash is
# GA, grounds against Google Search, and accepts low/medium/high. --deeper is the
# one exception: it switches to the flagship, gemini-4-argon (GA 2026-10-13,
# same three levels), which costs several times as much.
#
# `minimal` is deliberately ABSENT: both models reject it with an error, so it
# belongs in argparse's choices-check, where it costs nothing, rather than in a
# request that travels to Google to be refused there.
#
# medium is the API's own default for Gemini 3 Flash. It is restated here so the
# stderr line below can name the level that is actually in force instead of
# reporting "unset" and leaving the reader to guess.
THINKING_LEVELS = ("low", "medium", "high")
DEFAULT_THINKING = "medium"


def get_api_key_from_filesystem(key_name: str) -> Optional[str]:
    """Read API key from ~/.config/sops-nix/secrets/ directory."""
    key_file = os.path.expanduser(f"~/.config/sops-nix/secrets/{key_name}")
    try:
        with open(key_file, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, IOError):
        return None


def google_key() -> Optional[str]:
    # Prefers GEMINI_API_KEY, then GOOGLE_API_KEY, then the sops file.
    return (
        os.getenv("GEMINI_API_KEY")
        or os.getenv("GOOGLE_API_KEY")
        or get_api_key_from_filesystem("gemini_api_key")
    )


def openrouter_key() -> Optional[str]:
    return os.getenv("OPENROUTER_API_KEY") or get_api_key_from_filesystem(
        "openrouter_api_key"
    )


class OpenRouterError(Exception):
    def __init__(self, status_code: int, body: str):
        super().__init__(f"OpenRouter HTTP {status_code}: {body}")
        self.status_code = status_code


class Result:
    """One answer, whichever backend produced it.

    cites: (end, url, title) per grounded segment, `end` as a byte offset into
    the UTF-8 text. Both backends report bytes; measured for OpenRouter on a
    German answer, where slicing by bytes ends on a sentence and slicing by
    characters runs past it.
    """

    def __init__(self, text: str, cites: List[Tuple[int, str, str]], raw: Any):
        self.text = text
        self.cites = cites
        self.raw = raw


def run_google(model: str, prompt: str, level: str) -> Result:
    client = genai.Client(api_key=google_key())
    interaction = client.interactions.create(
        model=model.removeprefix("google/"),
        input=prompt,
        tools=[{"type": "google_search"}],
        generation_config={"thinking_level": level},
        store=False,
    )
    if getattr(interaction, "status", None) == "failed":
        errs = getattr(interaction, "errors", None) or []
        raise RuntimeError(f"interaction failed: {errs}")

    text = ""
    cites: List[Tuple[int, str, str]] = []
    for step in getattr(interaction, "steps", None) or []:
        if getattr(step, "type", None) != "model_output":
            continue
        for block in getattr(step, "content", None) or []:
            if getattr(block, "type", None) != "text":
                continue
            # Offsets in `annotations` are relative to THIS block, so shift them
            # by what earlier blocks already contributed (in bytes).
            base = len(text.encode("utf-8"))
            for a in getattr(block, "annotations", None) or []:
                if getattr(a, "type", None) != "url_citation":
                    continue
                url = getattr(a, "url", None)
                end = getattr(a, "end_index", None)
                if url and end is not None:
                    cites.append((base + end, url, getattr(a, "title", "") or url))
            text += block.text
    return Result(text, cites, interaction.model_dump(mode="json"))


def run_openrouter(model: str, prompt: str, level: str) -> Result:
    key = openrouter_key()
    if not key:
        raise RuntimeError(
            "set OPENROUTER_API_KEY, or place key in "
            "~/.config/sops-nix/secrets/openrouter_api_key"
        )
    body = {
        "model": model if "/" in model else f"google/{model}",
        "messages": [{"role": "user", "content": prompt}],
        # "native" is Google's own Search grounding; without it OpenRouter may
        # pick its Exa engine, which is a different search with different cost.
        "plugins": [{"id": "web", "engine": "native"}],
        "reasoning": {"effort": level},
    }
    r = _session.post(
        OPENROUTER_URL,
        headers={"Authorization": f"Bearer {key}"},
        json=body,
        timeout=240,
    )
    if r.status_code != 200:
        raise OpenRouterError(r.status_code, r.text[:500])
    d = r.json()
    msg = d["choices"][0]["message"]
    text = msg.get("content") or ""
    cites: List[Tuple[int, str, str]] = []
    for a in msg.get("annotations") or []:
        if a.get("type") != "url_citation":
            continue
        c = a.get("url_citation") or a
        url, end = c.get("url"), c.get("end_index")
        if url and end is not None:
            cites.append((end, url, c.get("title") or url))
    return Result(text, cites, d)


def status_of(exc: Exception) -> Optional[int]:
    # GenAiError (Interactions) and OpenRouterError carry status_code, the
    # legacy genai.errors.APIError carries code.
    for attr in ("status_code", "code"):
        v = getattr(exc, attr, None)
        if isinstance(v, int):
            return v
    return None


def render(res: Result, resolve: bool, workers: int) -> str:
    """Insert [n](url) after each grounded segment and append the source list."""
    # Number sources by first appearance in the text, one number per final URL.
    ordered = sorted(res.cites, key=lambda c: c[0])
    raw_urls = list(dict.fromkeys(c[1] for c in ordered))
    resolved = resolve_urls(raw_urls, max_workers=workers) if resolve else raw_urls
    url_map = dict(zip(raw_urls, resolved))
    number: Dict[str, int] = {}
    titles: Dict[str, str] = {}
    for _, url, title in ordered:
        final = url_map[url]
        if final not in number:
            number[final] = len(number) + 1
            titles[final] = title

    # Work on bytes: the offsets are byte offsets. Insert from the end so earlier
    # offsets stay valid. Several citations on one segment share one insertion.
    by_end: Dict[int, List[int]] = {}
    for end, url, _ in ordered:
        n = number[url_map[url]]
        if n not in by_end.setdefault(end, []):
            by_end[end].append(n)
    final_url = {n: u for u, n in number.items()}
    data = res.text.encode("utf-8")
    for end in sorted(by_end, reverse=True):
        end = min(end, len(data))
        marks = "".join(f"[{n}]({final_url[n]})" for n in by_end[end]).encode("utf-8")
        data = data[:end] + marks + data[end:]
    out = data.decode("utf-8", errors="replace").strip()

    if number:
        out += "\n\nSources:\n" + "\n".join(
            f"- [{n}] {titles[u]} — {u}" for u, n in number.items()
        )
    return out


def main():
    p = argparse.ArgumentParser(
        description="Google Search-powered AI assistant using Gemini models with grounding and citations",
    )
    p.add_argument("prompt", nargs="*", help="User query to search and answer")
    p.add_argument(
        "--model",
        default=None,
        help=f"Gemini model to use (default: {MODEL}; {MODEL_DEEPER} with --deeper)",
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
        "--deeper",
        action="store_true",
        help=f"Flagship model {MODEL_DEEPER} at thinking level high (several times the cost)",
    )
    p.add_argument(
        "--thinking-level",
        choices=THINKING_LEVELS,
        default=None,
        metavar="{low,medium,high}",
        help=f"Explicit thinking level; beats --flash/--deep/--deeper "
        f"(default: {DEFAULT_THINKING})",
    )
    p.add_argument(
        "--backend",
        choices=("auto", "google", "openrouter"),
        default="auto",
        help="auto: Google, and OpenRouter if Google answers 402/429 "
        "(default); google or openrouter: that one only, no fallback",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Print raw JSON response of the backend that answered",
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

    # --flash, --deep and --deeper are positions on one knob, so asking for two is
    # a contradiction, not a preference. The old code let --flash win silently.
    depth_flags = [n for n in ("flash", "deep", "deeper") if getattr(args, n)]
    if len(depth_flags) > 1 and not args.thinking_level:
        print(
            f"Error: --{' and --'.join(depth_flags)} contradict each other; "
            "pass one, or --thinking-level to be explicit.",
            file=sys.stderr,
        )
        sys.exit(2)
    if args.thinking_level:
        level = args.thinking_level
    elif args.flash:
        level = "low"
    elif args.deep or args.deeper:
        level = "high"
    else:
        level = DEFAULT_THINKING

    model = args.model or (MODEL_DEEPER if args.deeper else MODEL)

    backends = ["google", "openrouter"] if args.backend == "auto" else [args.backend]
    runners = {"google": run_google, "openrouter": run_openrouter}

    # Neither key anywhere: a configuration error (2), not a failed request (1).
    if not any(
        (google_key() if b == "google" else openrouter_key()) for b in backends
    ):
        print(
            "Error: set GEMINI_API_KEY/GOOGLE_API_KEY (~/.config/sops-nix/secrets/gemini_api_key)"
            " or OPENROUTER_API_KEY (~/.config/sops-nix/secrets/openrouter_api_key)",
            file=sys.stderr,
        )
        sys.exit(2)

    res = None
    errors: List[str] = []
    for i, backend in enumerate(backends):
        if backend == "google" and not google_key():
            errors.append("google: no API key")
            continue
        # stderr, never stdout: stdout is the Markdown document the skill
        # promises, and something downstream parses it. Without this line the
        # knobs are indistinguishable from outside -- a --deep that quietly did
        # not take looks exactly like one that did.
        print(
            f"gemini_research: backend={backend} model={model} thinking_level={level}",
            file=sys.stderr,
        )
        try:
            res = runners[backend](model, prompt, level)
            break
        except Exception as e:
            status = status_of(e)
            errors.append(f"{backend}: {e}")
            if i + 1 < len(backends) and status in FALLBACK_STATUSES:
                print(
                    f"gemini_research: {backend} failed (HTTP {status}) -> retrying via {backends[i + 1]}",
                    file=sys.stderr,
                )
                continue
            break

    if res is None:
        for line in errors:
            print(f"Request failed: {line}", file=sys.stderr)
        sys.exit(1)

    print(render(res, resolve=not args.no_resolve, workers=args.resolve_workers))

    if args.json:
        print("\n--- RAW RESPONSE JSON ---")
        print(json.dumps(res.raw, indent=2))


if __name__ == "__main__":
    main()
