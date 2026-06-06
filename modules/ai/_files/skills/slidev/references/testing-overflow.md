---
name: testing-overflow
description: Detect content that overflows / is clipped by the Slidev canvas, plus visual QA
---

# Overflow & Visual QA

Slidev renders every slide on a **fixed logical canvas** and scales it to the
viewport. Anything past the canvas boundary is **clipped silently** in present
mode — no scrollbar, no warning. So a slide can look fine while authoring and lose
its punchline on stage. This is the single most common deck defect; check for it
after writing any content-heavy slide.

## The canvas-scaling model

- Default logical canvas: `canvasWidth × canvasWidth/aspectRatio` = **980 × 552**
  for the default `16/9` (see [layout-canvas-size](layout-canvas-size.md)). All your
  CSS `px`/`height` values are **logical** px on this canvas.
- Slidev scales that canvas via a CSS `transform` to fill the viewport. At a
  `1280×720` test viewport the factor is ≈ **1.30** (720/552). So `getBoundingClientRect()`
  returns **real** (post-scale) px, while `getComputedStyle().height` is **logical**.
- After the title + paddings, a default slide leaves only **~400 logical px** of body
  height. Budget components accordingly.

## The bundled checker (recommended)

```bash
# render each slide at 1280×720, cycle tabs, check light + TRUE dark
zsh ${CLAUDE_SKILL_DIR}/scripts/check-slide-overflow.sh <range> [port]      # e.g. 1-40 3030
# also write screenshots (light + true dark) for agent vision QA
zsh ${CLAUDE_SKILL_DIR}/scripts/check-slide-overflow.sh 1-40 3030 --shot ./playwright-tests/qa
```

It exits non-zero when any slide overflows, and reports both vertical overflow
(`↧ +Npx`) and code hidden below a Monaco editor's fold (`⏷`). It is a Deno script
(`npm:playwright` pinned + a co-located `--lock --frozen`), so it needs `deno`; it
reuses the project's installed Playwright Chromium.

## Blind spots the checker is built to avoid

These are the traps that make a naive "is anything below 720?" check report a false
**pass**. If you write your own check, handle all of them:

1. **Measure text *nodes*, not just elements.** `querySelectorAll('*')` + a
   leaf-element filter misses **bare text nodes** — e.g. the tail of a callout that
   comes *after* an inline `<strong>…</strong>`. The `<div>` has element children so
   a leaf filter skips it, and the overflowing text is a text node, not an element.
   Walk text nodes and measure them with `Range.getClientRects()`.

2. **Fixed-height code editors hide their tail.** A Monaco block with more lines than
   its height shows scrolls *internally*; the lines below the fold (often the
   punchline comment) are invisible to a geometry-vs-720 check, because they're
   inside the editor, not below the canvas. Detect separately — e.g. a visible
   internal scrollbar slider shorter than its track, or statically:
   `visibleLines ≈ floor((heightPx − padding − 20·annotationViewzones) / lineHeight)`
   (for Slidev's Monaco at fontSize 12, `lineHeight ≈ 18`, `padding ≈ 12`). If your
   code has more lines than fit, trim it or raise the height.

3. **Cycle every tab and check both themes.** Overflow differs per tab and per
   theme. Click each `.tab-bar button` / `.tabs button` / `[role=tab]` before
   measuring.

4. **Dark mode needs `colorScheme`, not a class toggle.** Toggling the `.dark` class
   with `document.documentElement.classList.add('dark')` flips the *page* CSS but
   does **not** flip components that read Slidev's `useDarkMode()` — notably the
   **Monaco editor stays in its light theme**, giving false "dark" screenshots and
   bogus contrast findings. For a true dark render use a Playwright context with
   `colorScheme: 'dark'` (see [style-dark-light-mode](style-dark-light-mode.md)).

5. **Horizontal clipping is invisible to vertical checks.** Long code lines with
   `wordWrap: off` run off the right edge; a "bottom > 720" check won't see it. Catch
   it with a screenshot/vision pass (below).

## Vision QA (what geometry can't see)

Geometry catches vertical overflow and the Monaco fold; it cannot judge horizontal
clipping, contrast, or "this looks wrong". Complement it: capture every slide in
light **and true dark** (`--shot`), then have an agent review the PNGs for clipped
content, unreadable/low-contrast text, literal HTML tags shown as text, and mojibake.
For pixel-level regression, `await expect(page).toHaveScreenshot()` also works
(see [testing-playwright](testing-playwright.md)).

## A compile error breaks *many* slides at once

Each slide and each `slide-data`-style module compiles to its own ESM chunk. A
single syntax error (e.g. an unescaped backtick or `${` inside a template-literal
code string) makes Vite return **HTTP 500** for that module **and every slide that
imports it** — you'll see dozens of `Failed to fetch dynamically imported module
…/@slidev/slides/N/md` errors, not one. When a sweep reports many slides failing at
once, read the dev-server pane (`tmux-use.sh capture`) — esbuild prints the exact
`file:line`.

## Ad-hoc variant (bun, in `playwright-tests/`)

For a one-off custom check, write a script into `./playwright-tests/` and run it with
`bun run` (the skill's convention; see [testing-playwright](testing-playwright.md)).
The core measurement, scoped to the visible `.slidev-page`:

```ts
const over = await page.evaluate(() => {
  const slide = [...document.querySelectorAll('.slidev-page')].find(p => p.offsetParent)!
  let maxBelow = 0
  const w = document.createTreeWalker(slide, NodeFilter.SHOW_TEXT)
  for (let n = w.nextNode(); n; n = w.nextNode()) {
    if (!n.textContent?.trim()) continue
    if ((n.parentElement as HTMLElement)?.closest('.monaco-editor')) continue
    const r = document.createRange(); r.selectNodeContents(n)
    for (const rect of r.getClientRects())
      if (rect.height) maxBelow = Math.max(maxBelow, rect.bottom - 720)
  }
  return Math.round(maxBelow)   // > 0 → content clipped below the canvas
})
```

Use a `colorScheme: 'dark'` context for the dark pass.
