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

Extract and render PlantUML and Mermaid blocks from files, directories, or stdin.

Supported sources:
  - PlantUML blocks delimited by @startXYZ ... @endXYZ (e.g., @startuml/@enduml, @startditaa/@endditaa)
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

from typing import Optional, Sequence

import os
import subprocess
import sys

def main(argv: Optional[Sequence[str]] = None) -> None:
    env = os.environ.copy()
    env["BROWSER_USE_LOGGING_LEVEL"] = "result"

    cmd = [sys.executable, "-m", "browser_use.skill_cli"] + (list(argv) if argv is not None else [])
    p = subprocess.run(cmd, env=env, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"CLI failed with exit code {p.returncode}")

# from browser_use.cli import main as browser_use_main
#
# def main(argv: Optional[Sequence[str]] = None) -> None:
#     try:
#         browser_use_main(
#             args=argv,
#             standalone_mode=False,  # do NOT sys.exit()
#         )
#     except SystemExit as e:
#         # Click sometimes uses SystemExit for normal termination.
#         # Treat code != 0 as failure.
#         if e.code not in (0, None):
#             raise RuntimeError(f"browser_use CLI failed with exit code {e.code}") from e
#

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
