#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# [tool.uv]
# exclude-newer = "30 days"
# ///
"""Scan ports 3030-4000 for running Slidev dev servers and print their titles."""

import concurrent.futures
import html.parser
import socket
import sys
import urllib.error
import urllib.request


class _TitleParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self._in_title = False
        self.title: str | None = None

    def handle_starttag(self, tag, attrs):  # noqa: ARG002
        if tag == "title":
            self._in_title = True
            self._buf = []

    def handle_data(self, data):
        if self._in_title:
            self._buf.append(data)

    def handle_endtag(self, tag):
        if tag == "title" and self._in_title:
            self._in_title = False
            self.title = "".join(self._buf).strip()


def _check_port(port: int) -> tuple[int, str | None] | None:
    """Return (port, title) if Slidev is running on *port*, else None."""
    url = f"http://localhost:{port}"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=0.4) as resp:
            body = resp.read(64_000).decode("utf-8", errors="replace")
    except (OSError, urllib.error.URLError, socket.timeout):
        return None

    if "slidev" not in body.lower():
        return None

    parser = _TitleParser()
    try:
        parser.feed(body)
    except Exception:
        pass

    return (port, parser.title)


def main() -> int:
    ports = range(3030, 4001)

    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
        results = pool.map(_check_port, ports)

    found = 0
    for result in results:
        if result is None:
            continue
        port, title = result
        label = f" — {title}" if title else ""
        print(f"Slidev on port {port}{label} → http://localhost:{port}")
        found += 1

    if found == 0:
        print("No Slidev instance found on ports 3030-4000.")
        print()
        print("Alternative: check node processes listening on any port:")
        print("  lsof -i -P | grep node | grep LISTEN")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
