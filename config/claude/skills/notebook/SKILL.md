---
name: eval-notebook
description: Execute .ipynb notebooks (Python, Kotlin, or any Jupyter kernel) without overwriting; return LLM-friendly JSON with outputs and errors
argument-hint: [notebook.ipynb]
allowed-tools:
    - "Bash(./scripts/eval_notebook.sh)"
    - "Bash(bash ./scripts/eval_notebook.sh)"
---

# Notebook Evaluator

## 1. Purpose

Use this skill to execute Jupyter notebooks (.ipynb) safely without modifying the original file. It evaluates notebooks using their configured kernel and returns structured JSON output with execution results, captured outputs, and any errors—perfect for LLM consumption and automated testing.

## 2. Usage Scenarios

Run before:
- Validating notebook changes in a pull request
- Testing notebooks in CI/CD pipelines
- Debugging notebook execution errors
- Verifying notebook reproducibility

## 3. Helper Scripts

| Script | Purpose | Arguments |
|--------|---------|-----------|
| `scripts/eval_notebook.sh` | Entry point that delegates to Python evaluator | Forwards all arguments to `eval_notebook.py` |

### Arguments

- **Required:** One or more paths to `.ipynb notebook files`
- **Optional:** See CLI options below

## 4. CLI Options

| Option | Default | Description |
|--------|---------|-------------|
| `--timeout SECONDS` | 600 | Maximum execution time per notebook |
| `--iopub-timeout SECONDS` | 30 | Timeout for IOPUB messages |
| `--fail-fast` | false | Stop on first error instead of continuing |
| `--max-output-chars N` | 4000 | Truncate outputs after N characters |
| `--max-outputs-per-cell N` | 6 | Limit outputs captured per cell |
| `--pretty` | false | Pretty-print JSON output |


**Warning:** Notebook cells can produce huge output, e.g., when producing diagrams. Make sure to alway choose sane outputs for individual cells.


## 5. Examples

### Basic Evaluation

```bash
./scripts/eval_notebook.sh analysis.ipynb --pretty
```

Executes the notebook and returns pretty-printed JSON with results.

### Multiple Notebooks

```bash
./scripts/eval_notebook.sh notebook1.ipynb notebook2.ipynb
```

Returns an array of result objects, one per notebook.

### Strict Evaluation

```bash
./scripts/eval_notebook.sh analysis.ipynb --fail-fast --timeout 120
```

Stops immediately on any error with a 2-minute timeout.

## 6. Output Format

### Single Notebook Result

```json
{
  "notebook": "/path/to/notebook.ipynb",
  "cwd": "/path/to",
  "kernelspec": "python3",
  "status": "ok",
  "duration_ms": 1234,
  "exec_exception": null,
  "error_count": 0,
  "errors": [],
  "cells": [
    {
      "index": 0,
      "execution_count": 1,
      "source_preview": "print('hello')",
      "outputs": [
        {
          "type": "stream",
          "name": "stdout",
          "text": "hello\n"
        }
      ],
      "output_count": 1
    }
  ]
}
```

### Cell Output Types

| Type | Fields | Description |
|------|--------|-------------|
| `stream` | `name`, `text` | Standard output/error streams |
| `execute_result` | `mime`, `text` | Last expression result |
| `display_data` | `mime`, `text` or `image_base64_len` | Rich display (images, HTML) |
| `error` | `ename`, `evalue`, `traceback` | Python exception |

## 7. Exit Codes

| Code | Meaning |
| ---- | ------- |
| 0 | Success (notebook executed, may contain errors in results) |
| 1 | Script error (invalid arguments, file not found) |

Note: Cell execution errors are reported in the JSON output; the script itself succeeds if it can evaluate the notebook.

## 8. Your Task

When processing evaluation results:

1. **If status=ok:** Provide a concise summary of key outputs and execution time.

2. **If status=error:**
   - List each error by `cell_index` with `ename`, `evalue`, and relevant traceback lines
   - Identify the most likely root cause
   - Propose the fastest verification step
   - If code changes are needed, describe them precisely

3. **Never overwrite** the original notebook file—this skill is read-only by design.
