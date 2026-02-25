---
name: diagram-render
description: Render PlantUML (@startuml…@enduml) and Mermaid fenced blocks to a self-contained HTML preview; if rendering fails, the error text must be embedded in the output image.
argument-hint: "[paths...] [--stdin] [--select plantuml|mermaid|both] [--blocks startuml|fenced|all] [--only 1,3-5] [--out-dir DIR] [--format png|svg] [--json]"
allowed-tools:
  - "Bash(./scripts/render_diagram.sh)"
  - "Bash(bash ./scripts/render_diagram.sh)"
dependencies: python>=3.8, Pillow>=10
---

# Diagram renderer (PlantUML + Mermaid)

This skill renders embedded PlantUML and Mermaid snippets to images and produces a self-contained HTML preview. It is safe-by-default: it does **not** write image files unless the user explicitly requests an output directory.

## What counts as a “diagram block”

Extract diagrams from the provided inputs:

- **PlantUML blocks**: `@startuml ... @enduml`
- **Markdown fenced blocks**:
    - ` ```plantuml ` / ` ```puml ` / ` ```uml `
    - ` ```mermaid `

## How to run (always use the helper script)

The helper script lives at `scripts/render_diagrams.sh`.

### If the user passes file/dir paths

Run:

- `scripts/render_diagrams.sh $ARGUMENTS` 

### If the user pasted diagram text instead of giving a path

Pipe the text to stdin and add `--stdin` (do not create a persistent file unless the user asks):

- `cat <<'EOF' | scripts/render_diagrams.sh --stdin <other flags>`
- *(paste the user’s text, containing @startuml..@enduml and/or fenced blocks)*
- `EOF`

## Output rules

1. **Default**: Produce an HTML preview with embedded images (**no image files** on disk).
2. If the user wants images written, require an explicit `--out-dir <dir>` and write there.
3. Always report the generated HTML path to the user (the script prints it to stdout).
4. If any diagram fails, the preview must still include an image for it where the **error text is rendered into the image**.
5. You can get structured JSON output with `--json` (default: minimal, omitting source/bytes). Use `--detail full` for full output.

## Selecting which diagrams to render

- To list extracted blocks and their IDs:
    - `scripts/render_diagrams.sh <paths...> --list`
- To render a subset by ID:
    - `scripts/render_diagrams.sh <paths...> --only 2,5-7`

## Examples

- Render everything found in a Markdown doc:
    - `scripts/render_diagrams.sh docs/architecture.md`
- Only Mermaid blocks from multiple files:
    - `scripts/render_diagrams.sh docs/*.md --select mermaid`
- Only PlantUML `@startuml ... @enduml` blocks:
    - `scripts/render_diagrams.sh src/diagrams --blocks startuml`
- Persist images for CI artifacts:
    - `scripts/render_diagrams.sh docs/architecture.md --out-dir out/diagrams`

## Tooling expectations

The helper script will try, in order:

- PlantUML: `plantuml` executable; otherwise `java -jar <plantuml.jar>` if available (via `PLANTUML_JAR`).
- Mermaid: `mmdc`; otherwise `npx -y @mermaid-js/mermaid-cli` if `npx` exists.

If a tool is missing, still generate an error image explaining what is missing and how to fix it.