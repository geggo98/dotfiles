---
name: isometric-explainer
description: >-
  Build an isometric, self-narrating explorable that teaches a complex system by
  laying it out as a place and walking a vehicle through it — a real simulation
  underneath, station-by-station narration on top, in one dependency-free static
  site (HTML + canvas 2D + plain JS, no build step, no framework). Use when the
  user wants to teach or visualise how something works end to end and a diagram
  or a chart is not enough: "explain how X works visually", "build an
  interactive/animated explainer for X", "visualise the whole pipeline", "make a
  TokenTown / EngineWorks / PGSimCity-style thing for X", "a city/factory/town
  that shows how X works", "teach X with an animation", "explorable explanation",
  "learning simulation". Also use when editing an existing project built from
  this skill — look for iso.js, world.js and a stations table. SKIP for: a single
  chart, graph, plot or dashboard (use dataviz); a static diagram or flowchart
  (use artifact-diagramming); a slide deck; a game with win conditions and
  scoring; a 3D scene needing WebGL, Three.js or real perspective; a UI mockup.
license: MIT
---

# Isometric explainers

You are building a **place that runs a mechanism**. A vehicle carries real state
along roads; each stop is one step of the real thing; the vehicle stops long
enough for the reader to read about the step it just performed.

This works because it turns an invisible process into a journey with geography.
The reader gets sequence for free (the road), scale for free (the distance),
proportion for free (the size of a building), and repetition for free (a loop in
the road is a loop in the algorithm). Nothing here is decoration hung on a
lecture — the animation *is* the explanation.

Read this file, then read `references/build-order.md` and follow it. The other
references are lookups for when you reach the part they cover.

## The five rules

Everything else in this skill follows from these. Break one and you get a screen
saver with captions.

1. **Compute the real thing.** `model.js` must actually do the work — the real
   arithmetic, the real algorithm, at reduced scale. Never interpolate between
   pre-baked results. When the reader drags a slider the numbers must move
   because the model moved.
2. **The vehicle carries state, not cargo.** The bars on its flank are the
   actual vector. The crates in its bed are the actual byte count. The gauge is
   the actual budget spent. If you could delete the vehicle's decoration without
   losing information, it was decoration.
3. **Publish a fidelity ledger.** Say exactly what is computed, what is scaled
   down, what is assumed, and what is faked — in the About modal *and* the
   README. Half the educational value is the reader knowing which numbers to
   trust. See `references/fidelity.md`.
4. **Pace it for reading, not watching.** The first visit to a station stops for
   as long as its write-up takes to read. Later visits get a beat. The reader
   never has to pause to keep up. See `references/pacing.md`.
5. **One canvas, no dependencies.** Canvas 2D, plain ES5-style JS in IIFEs,
   `<script>` tags in order, no build step, no network calls. It opens from
   `file://`, it works offline, it deploys to any static host, and it is still
   readable in five years.

## Layout

Seven files, in dependency order. Keep these names and this split — it is the
same shape in every project built from this skill, and the whole skill assumes
it.

```
index.html          markup, controls, the About modal with the fidelity ledger
css/styles.css      light print-like UI: full-screen canvas, floating panels
js/iso.js           ENGINE. Projection, solids, routes. Copy unchanged.
js/model.js         THE LESSON. The real simulation. Write this first.
js/world.js         the static place: routes, stations, districts, buildings
js/sim.js           ENGINE. State machine: travel, stations, reading stops.
js/render.js        one sorted painter's pass over everything with a footprint
js/ui.js            DOM panels, live numbers, narration, controls
js/main.js          ENGINE. Camera, input, frame loop. Copy nearly unchanged.
```

`iso.js`, `sim.js` and `main.js` are engine: copy them from
`assets/template/js/` and change almost nothing. `model.js` and `world.js` are
100% yours. `render.js` keeps its structure — the sorted pass, the label pass —
and gets new landmark functions. `ui.js` keeps its shape and gets your panels.

## Start here

Copy the working template, then replace the domain:

```bash
cp -r <skill-dir>/assets/template my-explainer
cd my-explainer && python -m http.server 8000
```

The template is **PacketPost**, a complete small explainer of what a web request
costs: eight stations, a real latency model with TCP slow start, a branch in the
road for a CDN cache hit. It runs. Open it before you change anything, watch one
full trip, and notice what the pacing feels like — you are trying to reproduce
that feeling, not that subject.

Then work through `references/build-order.md`. Do not start with the scenery.

## Verify before you claim it works

A canvas app fails silently: one thrown error and you get an empty frame with a
clean-looking page. Always run this before reporting done:

```bash
# syntax. A loop, because `node --check` takes ONE file — `node --check js/*.js`
# checks js/iso.js and silently treats the other six as arguments.
for f in js/*.js; do node --check "$f" || echo "FAIL $f"; done

# console errors, every station, and a screenshot. Needs a served URL.
python -m http.server 8000 &
node "$SKILL_DIR/scripts/smoke.mjs" http://localhost:8000/
```

`$SKILL_DIR` is wherever this skill is installed — use `${CLAUDE_SKILL_DIR}`, or
just copy `scripts/smoke.mjs` into the project next to `index.html`.

`scripts/smoke.mjs` loads the page in headless Chromium, fails on any console
error or page error, steps the vehicle through every station, and writes a
screenshot. **Look at the screenshot.** Occlusion, label collisions and plates
landing on empty ground do not raise errors.

If Playwright is unavailable, say so plainly and tell the user to open
`index.html` — do not report a template as working on `node --check` alone.

## References

| File | Read it when |
|---|---|
| `references/build-order.md` | before writing anything — the seven phases, in order |
| `references/fidelity.md` | writing the About modal, the README, or any number |
| `references/pacing.md` | tuning stops, fast-forward, or the tour-done switch |
| `references/isometric-drawing.md` | drawing anything: projection, sort order, occlusion, faces |
| `references/narration.md` | writing district copy and panel text |
| `references/checklist.md` | before you call it finished |

## Things that will bite you

Each of these cost someone an afternoon. The references explain them properly.

- A machine at `(mx, my)` **hides** the road point at `(mx, by)` when half its
  footprint, `(w + d) / 2`, exceeds its setback `my - by`. Big halls stand well
  back from the road or they swallow the thing the reader is watching.
- Sort **every** ground-footprint object in **one** list keyed on `x + y`. A
  structure the road passes under must be registered as separate pieces (left
  post, beam, right post), or the near post draws behind the vehicle.
- Label plates are drawn in screen space, but with the **dpr** transform, not
  the identity transform — otherwise every plate lands at half position on a
  retina display.
- Scenery variation comes from a hash of its coordinates, never `Math.random()`,
  or the whole world shimmers every frame.
- The reading stop is scaled by the speed slider **only**. Travel fast-forwards
  must never cut a first read short.
- What the reader has already read survives a reset. Nobody wants to re-read the
  tour because they pressed the wrong button.
