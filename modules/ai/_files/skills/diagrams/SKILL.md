---
name: diagram-render
description: "Render PlantUML (@startuml…@enduml) and Mermaid fenced blocks to a self-contained HTML preview; if rendering fails, the error text must be embedded in the output image. Use when the user asks to render, preview, or export diagrams."
argument-hint: "[paths...] [--stdin] [--select plantuml|mermaid|both] [--blocks startuml|fenced|all] [--only 1,3-5] [--out-dir DIR] [--format png|svg] [--json] [--timeout DURATION]"
allowed-tools: Bash(./scripts/render_diagram.sh *) Bash(zsh *)
dependencies: "uv, plantuml, mmdc (Mermaid CLI), gtimeout"
---

# Diagram renderer (PlantUML + Mermaid)

## Usage

Run the script:

```bash
zsh ${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh $ARGUMENTS
```

This skill renders embedded PlantUML and Mermaid snippets to images and produces a self-contained HTML preview. It is safe-by-default: it does **not** write image files unless the user explicitly requests an output directory.

## What counts as a “diagram block”

Extract diagrams from the provided inputs:

- **PlantUML blocks**: `@startuml ... @enduml`
- **Markdown fenced blocks**:
    - ` ```plantuml ` / ` ```puml ` / ` ```uml `
    - ` ```mermaid `

## How to run (always use the helper script)

The helper script lives at `${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh`.

> **Important:** Run the script directly (`${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh`). Do **not** prefix with `bash` — the script requires zsh and will fail under bash.

### If the user passes file/dir paths

Run:

- `${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh $ARGUMENTS` 

### If the user pasted diagram text instead of giving a path

Pipe the text to stdin and add `--stdin` (do not create a persistent file unless the user asks):

- `cat <<'EOF' | ${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh --stdin <other flags>`
- *(paste the user’s text, containing @startuml..@enduml and/or fenced blocks)*
- `EOF`

## Timeout

The wrapper script enforces a global timeout via `gtimeout`. Pass `--timeout DURATION` to override it (default: `5m`). The duration format follows GNU coreutils (e.g. `30s`, `5m`, `1h`).

```bash
${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh docs/architecture.md --timeout 10m
```

## Output rules

1. **Default**: Produce an HTML preview with embedded images (**no image files** on disk).
2. If the user wants images written, require an explicit `--out-dir <dir>` and write there.
3. Always report the generated HTML path to the user (the script prints it to stdout).
4. If any diagram fails, the preview must still include an image for it where the **error text is rendered into the image**.
5. You can get structured JSON output with `--json` (default: minimal, omitting source/bytes). Use `--detail full` for full output.

## Selecting which diagrams to render

- To list extracted blocks and their IDs:
    - `${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh <paths...> --list`
- To render a subset by ID:
    - `${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh <paths...> --only 2,5-7`

## Examples

- Render everything found in a Markdown doc:
    - `${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh docs/architecture.md`
- Only Mermaid blocks from multiple files:
    - `${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh docs/*.md --select mermaid`
- Only PlantUML `@startuml ... @enduml` blocks:
    - `${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh src/diagrams --blocks startuml`
- Persist images for CI artifacts:
    - `${CLAUDE_SKILL_DIR}/scripts/render_diagram.sh docs/architecture.md --out-dir out/diagrams`

## Tooling expectations

The helper script will try, in order:

- PlantUML: `plantuml` executable; otherwise `java -jar <plantuml.jar>` if available (via `PLANTUML_JAR`).
- Mermaid: `mmdc`; otherwise `npx -y @mermaid-js/mermaid-cli` if `npx` exists.

If a tool is missing, still generate an error image explaining what is missing and how to fix it.