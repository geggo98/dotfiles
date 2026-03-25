#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "browser-use[cli]",
# ]
# [tool.uv]
# exclude-newer = "2026-02-15T00:00:00Z"
# ///

# Hint: Lock dependencies with `uv lock --script ...`

"""
browser-use.py

A fast, persistent command-line interface for browser automation with support for local and cloud-based browser modes.

The Browser-Use CLI is a Python-based command-line tool that enables browser automation from the terminal with multiple operating modes. It features a session server architecture
for persistent browser sessions, allowing you to control a browser through sequential commands like `open`, `click`, `type`, and `screenshot`.

The tool supports three browser modes: local headless Chromium (default), your real Chrome browser with existing credentials,
and cloud-based remote browsers (via Browser-Use Cloud API).

It's designed for fast startup (<50ms) using stdlib-only imports and delegates heavy operations to a session server.

The CLI includes setup wizards for configuration, supports both local and cloud execution paths, and offers template generation for creating automation scripts.
"""

from __future__ import annotations

from typing import Optional, Sequence

import os
import subprocess
import sys


def main(argv: Optional[Sequence[str]] = None) -> None:
    try:
        env = os.environ.copy()
        env["BROWSER_USE_LOGGING_LEVEL"] = "result"

        cmd = [sys.executable, "-m", "browser_use.skill_cli"] + (list(argv) if argv is not None else [])
        p = subprocess.run(cmd, env=env, check=False)
        if p.returncode != 0:
            raise RuntimeError(f"CLI failed with exit code {p.returncode}")
    except SystemExit as e:
        # Click sometimes uses SystemExit for normal termination.
        # Treat code != 0 as a failure.
        if e.code not in (0, None):
            raise RuntimeError(f"browser_use CLI failed with exit code {e.code}") from e


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
