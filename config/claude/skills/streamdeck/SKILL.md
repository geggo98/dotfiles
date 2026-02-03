# Stream Deck Manifest Toolkit

Validate, repair, format, and scaffold **Elgato Stream Deck** `manifest.json` files.

This skill is designed to shorten the feedback loop when an agent generates or edits Stream Deck plugin manifests by providing:
- **Schema validation** against the official JSON schema.
- **Fast, local asset checks** (file existence + PNG/GIF dimensions) that typically only fail during manual Stream Deck testing.
- **Scaffolding/editing helpers** to keep manifests consistent and less error-prone.

---

## What this skill does

### 1) Schema validation
- Validates the manifest against the official schema.
- Uses the manifest’s `$schema` URL if present; otherwise defaults to:
  - `https://schemas.elgato.com/streamdeck/plugins/manifest.json`

### 2) Extra validations (beyond JSON Schema)
The schema cannot reliably verify files on disk. This tool adds:
- **Strict JSON** check (no comments / trailing commas). If the file parses as JSONC, it reports it and can rewrite to strict JSON.
- **File existence checks** (relative to the manifest directory) for:
  - `CodePath`, `CodePathMac`, `CodePathWin`, `PropertyInspectorPath`
  - action `PropertyInspectorPath`
  - encoder `layout` when it ends with `.json`
- **Image asset checks** (existence + dimensions for PNG/GIF):
  - Plugin `Icon`: 256×256 + 512×512 (@2x), **PNG only**
  - `CategoryIcon`: 28×28 + 56×56 (@2x), PNG; or single SVG
  - Action `Icon`: 20×20 + 40×40 (@2x), PNG; or single SVG
  - Action `States[].Image`: 72×72 + 144×144 (@2x), PNG/GIF; or single SVG
  - Action `States[].MultiActionImage`: 72×72 + 144×144 (@2x), PNG; or single SVG
  - Encoder `Icon`: 72×72 + 144×144 (@2x), PNG; or single SVG
  - Encoder `background`: 200×100 + 400×200 (@2x), PNG; or single SVG
- **Action UUID uniqueness** and convention warning if an action UUID doesn’t start with the plugin UUID.

### 3) Editing helpers
- `fmt`: rewrites a manifest to strict JSON and applies a stable key order + formatting.
- `init`: scaffolds a minimal `.sdPlugin` folder with:
  - `manifest.json`
  - placeholder plugin icon PNGs
  - placeholder SVGs for category/action/state icons
  - a stub `bin/plugin.js` and action property inspector HTML
- `add-action`: appends an action stub into an existing manifest and creates placeholder assets.

---

## Tools

- `tools/streamdeck_manifest.sh` — CLI entrypoint.
  - Output is **JSON by default** (easy for agents to parse).

---

## How to use

### Validate a manifest

```bash
./tools/streamdeck_manifest.sh validate path/to/manifest.json
```

Behavior:
- Exit code `0` if no **errors**.
- Exit code `1` if parse/schema/asset errors exist.
- Warnings do not fail by default.

JSON output shape:

```json
{
  "ok": true,
  "errors": [],
  "warnings": [],
  "meta": {
    "schemaUrl": "…",
    "schemaFromCache": true,
    "parsedAsJsonc": false
  }
}
```

### Fix JSONC / trailing commas

```bash
./tools/streamdeck_manifest.sh validate manifest.json --fix-jsonc --write
```

### Format / normalize

```bash
./tools/streamdeck_manifest.sh fmt manifest.json --write
```

### Scaffold a new plugin folder

```bash
./tools/streamdeck_manifest.sh init ./MyPlugin.sdPlugin \
  --name "My Plugin" \
  --uuid "com.example.myplugin" \
  --author "Example" \
  --description "…"
```

### Add an action to an existing manifest

```bash
./tools/streamdeck_manifest.sh add-action ./MyPlugin.sdPlugin/manifest.json \
  --name "My Action"
```

---

## Agent workflow

1. Run `validate`.
2. If parse error or JSONC: run `validate --fix-jsonc --write`.
3. Fix schema errors (missing required fields, wrong types, invalid values).
4. Fix asset errors (wrong/missing paths, missing @2x files, wrong image dimensions).
5. Run `fmt --write`.
6. Re-run `validate` until `ok: true`.

---

## Limitations

- Does **not** validate “monochrome” / “white on transparent” requirements; it only checks file existence and raster dimensions.
- Does not validate SVG geometry/dimensions.
- Passing validation does not guarantee correct runtime behavior; it only removes the common “manifest/asset” failure modes.

