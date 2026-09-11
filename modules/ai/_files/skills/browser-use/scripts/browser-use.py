#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   # >=0.12.7: the CVE-driven floor (litellm supply chain gone in 0.12.5;
#   #   pillow/pypdf/aiohttp transitive fixes in 0.12.7).
#   # <0.13: 0.13.3 (2026-07-01) removed `browser_use.skill_cli`, the module this
#   #   script runs and whose subcommands SKILL.md is written against, in favour
#   #   of a Browser-Harness CLI ("The old preset subcommands are gone"). Moving
#   #   past 0.13 is a rewrite of the skill, not a re-lock. The ceiling belongs
#   #   here, in the spec, where a re-lock can see it.
#   "browser-use[cli]>=0.12.7,<0.13",
# ]
# [tool.uv]
# exclude-newer = "30 days"
# # No exclude-newer-package overrides. The ones that undercut the cooldown for
# # the 0.12.7 bump (dated 2026-05-21) were CEILINGS, not floors: they kept
# # browser-use/pillow/pypdf/aiohttp at May 2026 on every later re-lock, and with
# # them the 0.12.8 fix that restricts the skill daemon's unix socket to its
# # owner (browser-use/browser-use#4870). If a CVE ever forces an undercut
# # again, add the override with that day's date and REMOVE it at the next
# # re-lock, once the global 30-day bar covers the version on its own.
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
