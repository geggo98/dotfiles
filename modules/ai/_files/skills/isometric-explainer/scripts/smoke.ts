#!/usr/bin/env -S deno run --allow-env --allow-read --allow-write --allow-net --allow-run --allow-sys --lock=smoke.lock --frozen
// smoke.ts — headless check for an isometric explainer.
//
//   deno run --allow-env --allow-read --allow-write --allow-net --allow-run \
//     --allow-sys --lock=smoke.lock --frozen smoke.ts <url> [--out shot.png] [--steps 60] [--dpr 1]
//
// Port of the upstream scripts/smoke.mjs (see ../UPSTREAM.md) to deno, so the
// playwright version is pinned instead of resolved from whatever the tested
// project happens to have installed — deployed skill files live read-only in
// /nix/store, and the generated explainer project has no dependencies of its
// own to resolve `playwright` from, so the original CWD-relative
// `createRequire` fallback never actually found it there.
//
// A canvas app fails silently: one thrown error and you get an empty frame on
// a page that still looks fine. This loads the page, fails on any console
// error/warning or page error, steps the vehicle through every station of the
// whole run, checks that each one actually fired, and writes a screenshot.
//
// LOOK AT THE SCREENSHOT. Occlusion, label collisions and plates landing on
// empty ground do not raise errors.
//
// Playwright version pinned in lockstep with ../../slidev/scripts/
// check-slide-overflow.{sh,ts,lock} — bump both together.
import { chromium } from "npm:playwright@1.58.2";

function die(msg: string): never {
  console.error(msg);
  Deno.exit(2);
}

const args = [...Deno.args];
const url = args.find((a) => !a.startsWith("--"));
function flag(name: string, dflt: string): string {
  const i = args.indexOf("--" + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
}

if (!url) die("usage: smoke.ts <url> [--out shot.png] [--steps 60] [--dpr 1]");

const out = flag("out", "smoke.png");
const maxSteps = Number(flag("steps", "60"));
const dpr = Number(flag("dpr", "1"));

const fail: string[] = [];
const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: dpr,
});

page.on("console", (m) => {
  if (m.type() === "error" || m.type() === "warning") fail.push(`${m.type()}: ${m.text()}`);
});
page.on("pageerror", (e) => fail.push(`pageerror: ${e.message}`));
page.on("requestfailed", (r) => fail.push(`requestfailed: ${r.url()}`));

await page.goto(url, { waitUntil: "load" });
await page.waitForTimeout(1000);

// The globals every project built from this skill exposes. If one is
// missing, a script tag is out of order or a file threw while loading.
const globals: string[] = await page.evaluate(() =>
  ["Iso", "World", "Sim", "Renderer", "UI"].filter((k) => !(window as unknown as Record<string, unknown>)[k])
);
if (globals.length) fail.push(`missing globals: ${globals.join(", ")}`);

let seen: string[] = [];
let finished = false;

if (!globals.length) {
  // Step past the reading stops rather than waiting them out: step() zeroes
  // the current dwell and advances exactly one station. The wait between
  // steps has to cover travel to the next station, not just the step itself.
  for (let i = 0; i < maxSteps; i++) {
    await page.evaluate(() => {
      // deno-lint-ignore no-explicit-any
      const Sim = (window as any).Sim;
      Sim.state.speed = 8;
      Sim.step();
    });
    await page.waitForTimeout(420);
    const st: { station: string | null; finished: boolean } = await page.evaluate(() => {
      // deno-lint-ignore no-explicit-any
      const state = (window as any).Sim.state;
      return { station: state.station, finished: state.finished };
    });
    if (st.station) seen.push(st.station);
    if (st.finished) {
      finished = true;
      break;
    }
  }

  const expected: string[] = await page.evaluate(() => {
    // deno-lint-ignore no-explicit-any
    const stations = (window as any).World.stations;
    return Object.values(stations).flat().map((s: unknown) => (s as { id: string }).id);
  });
  const missed = expected.filter((id) => !seen.includes(id));
  if (missed.length) fail.push(`stations never fired: ${missed.join(", ")}`);
  if (!finished) fail.push(`run did not finish within ${maxSteps} steps`);
}

await page.screenshot({ path: out });
await browser.close();

const unique = [...new Set(seen)];
console.log(`stations visited (${unique.length}): ${unique.join(" → ") || "—"}`);
console.log(`run finished: ${finished}`);
console.log(`screenshot: ${out}`);

if (fail.length) {
  console.error(`\nFAIL (${fail.length}):`);
  for (const f of fail) console.error("  " + f);
  Deno.exit(1);
}
console.log("\nPASS — no console or page errors. Now look at the screenshot.");
