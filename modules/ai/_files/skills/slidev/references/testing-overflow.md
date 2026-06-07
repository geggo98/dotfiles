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

Clipping and text wrapping are **layout-engine-specific** — a slide can fit in
Chromium yet overflow in Gecko (Firefox) or WebKit because font metrics and
line-breaking differ. So the bundled checker renders every slide through
**chromium + firefox + webkit** by default; narrow with `--browsers` only for
quick iteration, and run all three for final QA.

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
# render each slide at 1280×720 across chromium+firefox+webkit, cycle tabs, light + TRUE dark
zsh ${CLAUDE_SKILL_DIR}/scripts/check-slide-overflow.sh <range> [port]      # e.g. 1-40 3030
# also write screenshots (per engine, light + true dark) for agent vision QA
zsh ${CLAUDE_SKILL_DIR}/scripts/check-slide-overflow.sh 1-40 3030 --shot ./playwright-tests/qa
# narrow the engine set for fast iteration (default is all three)
zsh ${CLAUDE_SKILL_DIR}/scripts/check-slide-overflow.sh 1-40 3030 --browsers chromium,webkit
# big deck on a beefy machine: split each lane's slides across N pages
zsh ${CLAUDE_SKILL_DIR}/scripts/check-slide-overflow.sh 1-90 3030 --jobs 2
# weak/contended dev server: lower the concurrent-navigation cap
zsh ${CLAUDE_SKILL_DIR}/scripts/check-slide-overflow.sh 1-90 3030 --max-concurrency 3
```

It exits non-zero when any slide overflows (or an engine fails to launch), and
reports both vertical overflow (`↧ +Npx`) and code hidden below a Monaco editor's
fold (`⏷`), tagged with the `[tab·engine·theme]` where it occurred. It is a Deno
script (`npm:playwright` pinned + a co-located `--lock --frozen`), so it needs
`deno`.

### How it parallelizes (and why correctness survives it)

The checker runs the `engine × theme` combinations as concurrent **lanes** (one
browser process per engine, two contexts each), several times faster than a serial
sweep. The single bottleneck is the shared **Vite dev server** every page hits, so
a few things keep it both fast and honest:

- **Boot once, then navigate in-SPA.** Each page does one full `goto` to load the
  Slidev app (and Monaco's large ESM graph) a single time, then moves slide-to-slide
  with client-side navigation (`pushState` + `popstate`). The naive alternative —
  `goto('/N')` per slide — re-pulls that graph 6×N times and stampedes Vite, which
  makes firefox/webkit serve transient module-load failures and half-render slides.
- **Throttle the whole measurement, gate on real signals.** The entire per-slide
  measure (nav → settle → tab-cycle → collect) runs under a `--max-concurrency`
  semaphore, so reflow-heavy work doesn't all happen at once and starve itself.
  Before measuring it waits for the active slide to be `slidev-page-${n}` and the
  **network to go quiet** (the lazy chunk finished — else a still-loading slide
  reads as `tabs:0` and is silently unchecked), then a fixed wall-clock settle for
  render/reflow (a deterministic wait — rAF/MutationObserver "smart" settles proved
  flaky/throttled in headless), and finally measures **twice and unions** the
  findings (a borderline overflow can lag a frame). Transient module-load failures
  are **retried** with a fresh reload; a persistent failure (e.g. a real compile-500)
  survives the retries and is reported, never silently passed.

Tunables: `--max-concurrency N` bounds concurrent slide measurements (default
`min(lanes,4)`; raise it for more speed on a fast box, lower it on a weak/contended
dev server); `--jobs N` runs N pages per lane to split a big deck's slides (default 1).

**Borderline caveat.** Overflows within a few px of the tolerance (`--tol`, default
2) render right at the wrap boundary, so under parallel CPU load *which* engine/theme
lane reports them can vary run-to-run — but the **slide is still flagged** (some lane
catches it). Findings comfortably past the canvas are stable. For the most
deterministic per-lane result on a marginal case, re-run that slide with
`--browsers <engine>` (near-serial) or a low `--max-concurrency`.

### Where the browsers come from (nix-pinned, with fallback)

The `.sh` wrapper provisions all three engines **reproducibly via Nix** before
launching: it builds `playwright-driver.browsers` from a rev-pinned nixpkgs commit
and exports `PLAYWRIGHT_BROWSERS_PATH` plus `PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS`
(and `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`). If `nix` is unavailable or the build
fails, it falls back to `deno run npm:playwright install chromium firefox webkit`
(CDN). The wrapper also runs `playwright-driver.browsers` on aarch64-darwin — the
mac archives are Apple-signed and used as-is.

**Version-lock invariant.** Playwright resolves browsers by *exact* revision
(1.58.2 → `chromium-1208` / `firefox-1509` / `webkit-2248`); `PLAYWRIGHT_BROWSERS_PATH`
only changes the lookup *root*, not the expected revision. So the nix bundle's
`playwright-driver` version **must equal** the checker's pin. The pin lives in three
coupled places — the `PW_VERSION`/`NIXPKGS_REF` in `check-slide-overflow.sh`, the
`npm:playwright@…` specifier in `check-slide-overflow.ts`, and the deno `--lock`.
Bump them in lockstep; the wrapper's runtime guard prints a clear warning (and falls
back to CDN) on skew rather than throwing the cryptic `Executable doesn't exist at
…/chromium-1208/…`.

**Cost.** The three engines × two themes run in parallel (see above), so a full
sweep is ~one engine's wall-clock, not 3×; on a typical deck that is several times
faster than a serial pass. `--shot` still writes 3× the PNGs
(`slide-NN-<engine>-<theme>.png`). First run also realises the nix browser bundle
(~hundreds of MB, once) into the store.

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
clipping, contrast, or "this looks wrong". Complement it: capture every slide per
engine in light **and true dark** (`--shot` writes `slide-NN-<engine>-<theme>.png`),
then have an agent review the PNGs for clipped content, unreadable/low-contrast text,
literal HTML tags shown as text, mojibake, and cross-engine rendering differences.
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
