#!/usr/bin/env -S uv --quiet run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "nbclient", "nbformat", "kotlin-jupyter-kernel",
# ]
# [tool.uv]
# exclude-newer = "2026-02-01T00:00:00Z"
# ///

# Hint: Lock dependencies with `uv lock --script ...`


"""
Execute .ipynb notebooks (Python or Kotlin or anything with a Jupyter kernel)
WITHOUT overwriting the original file, and emit LLM-friendly JSON.

Requires: pip install nbclient nbformat
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import nbformat
from nbclient import NotebookClient
from nbclient.exceptions import CellExecutionError


def trunc(s: Any, n: int) -> Any:
    if s is None:
        return None
    if isinstance(s, (dict, list)):
        s = json.dumps(s, ensure_ascii=False, default=str)
    s = str(s)
    if len(s) <= n:
        return s
    return s[:n] + f"\n… <truncated {len(s) - n} chars>"


def pick_mime(data: Dict[str, Any]) -> Tuple[Optional[str], Optional[Any]]:
    for mime in ("text/plain", "application/json", "text/markdown", "text/html"):
        if mime in data:
            return mime, data[mime]
    for mime in ("image/png", "image/jpeg", "image/svg+xml"):
        if mime in data:
            return mime, data[mime]
    if data:
        k = next(iter(data.keys()))
        return k, data[k]
    return None, None


def normalize_output(out: Dict[str, Any], max_chars: int) -> Dict[str, Any]:
    ot = out.get("output_type")
    if ot == "stream":
        return {
            "type": "stream",
            "name": out.get("name"),
            "text": trunc(out.get("text", ""), max_chars),
        }

    if ot in ("execute_result", "display_data"):
        data = out.get("data", {}) or {}
        mime, payload = pick_mime(data)
        if mime in ("image/png", "image/jpeg"):
            # Avoid dumping base64 blobs into JSON
            size = len(payload) if isinstance(payload, str) else None
            return {
                "type": ot,
                "mime": mime,
                "image_base64_len": size,
                "text": "<image omitted>",
            }
        return {"type": ot, "mime": mime, "text": trunc(payload, max_chars)}

    if ot == "error":
        return {
            "type": "error",
            "ename": out.get("ename"),
            "evalue": trunc(out.get("evalue"), max_chars),
            "traceback": [trunc(x, max_chars) for x in (out.get("traceback") or [])],
        }

    return {"type": ot or "unknown", "raw": trunc(out, max_chars)}


def evaluate_one(
    nb_path: Path,
    timeout_s: int,
    iopub_timeout_s: int,
    fail_fast: bool,
    max_output_chars: int,
    max_outputs_per_cell: int,
) -> Dict[str, Any]:
    t0 = time.time()
    nb_path = nb_path.resolve()

    if not nb_path.exists() or nb_path.suffix != ".ipynb":
        return {
            "notebook": str(nb_path),
            "status": "error",
            "error": "Not a readable .ipynb file",
        }

    nb = nbformat.read(str(nb_path), as_version=4)
    kernelspec = (nb.metadata.get("kernelspec") or {}).get("name")  # may be None

    # Deepcopy so we never accidentally write mutated state back to disk.
    nb_exec = copy.deepcopy(nb)

    cwd = str(nb_path.parent)
    exec_exception: Optional[Dict[str, Any]] = None

    # nbclient executes notebooks and populates outputs in the in-memory notebook object. :contentReference[oaicite:3]{index=3}
    # If kernel_name is not set, nbclient uses the kernelspec embedded in the notebook. :contentReference[oaicite:4]{index=4}
    client = NotebookClient(
        nb_exec,
        timeout=timeout_s,
        iopub_timeout=iopub_timeout_s,
        allow_errors=not fail_fast,  # record errors in output + continue if not fail_fast :contentReference[oaicite:5]{index=5}
        resources={"metadata": {"path": cwd}},
    )

    try:
        client.execute()
    except CellExecutionError as e:
        # Happens mainly when fail_fast=True
        exec_exception = {"type": "CellExecutionError", "message": str(e)}
    except Exception as e:
        exec_exception = {
            "type": e.__class__.__name__,
            "message": str(e),
            "traceback": traceback.format_exc().splitlines(),
        }

    errors: List[Dict[str, Any]] = []
    cells: List[Dict[str, Any]] = []

    for idx, cell in enumerate(nb_exec.cells):
        if cell.get("cell_type") != "code":
            continue

        outs = []
        for out in (cell.get("outputs") or [])[:max_outputs_per_cell]:
            o = normalize_output(out, max_output_chars)
            outs.append(o)
            if o.get("type") == "error":
                errors.append({"cell_index": idx, **o})

        cells.append(
            {
                "index": idx,
                "execution_count": cell.get("execution_count"),
                "source_preview": trunc(cell.get("source", ""), 800),
                "outputs": outs,
                "output_count": len(cell.get("outputs") or []),
            }
        )

    dt_ms = int((time.time() - t0) * 1000)
    status = "ok" if (not errors and exec_exception is None) else "error"

    return {
        "notebook": str(nb_path),
        "cwd": cwd,
        "kernelspec": kernelspec,
        "status": status,
        "duration_ms": dt_ms,
        "exec_exception": exec_exception,
        "error_count": len(errors),
        "errors": errors,
        "cells": cells,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("notebooks", nargs="+")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--iopub-timeout", type=int, default=30)
    ap.add_argument("--fail-fast", action="store_true")
    ap.add_argument("--max-output-chars", type=int, default=4000)
    ap.add_argument("--max-outputs-per-cell", type=int, default=6)
    ap.add_argument("--pretty", action="store_true")
    args = ap.parse_args()

    results = [
        evaluate_one(
            Path(p),
            timeout_s=args.timeout,
            iopub_timeout_s=args.iopub_timeout,
            fail_fast=args.fail_fast,
            max_output_chars=args.max_output_chars,
            max_outputs_per_cell=args.max_outputs_per_cell,
        )
        for p in args.notebooks
    ]

    out: Any = results[0] if len(results) == 1 else results
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
