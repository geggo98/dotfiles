/* smoke.mjs — headless check for an isometric explainer.
 *
 *   node smoke.mjs <url> [--out shot.png] [--steps 60] [--dpr 1]
 *
 * A canvas app fails silently: one thrown error and you get an empty frame on a
 * page that still looks fine. This loads the page, fails on any console error or
 * page error, steps the vehicle through every station of the whole run, checks
 * that each one actually fired, and writes a screenshot.
 *
 * LOOK AT THE SCREENSHOT. Occlusion, label collisions and plates landing on
 * empty ground do not raise errors.
 *
 * Requires playwright:  npm i -D playwright && npx playwright install chromium
 * Exits 1 on any failure, so it can gate a commit.
 */
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

/* This script lives in the skill directory, not in the project being tested, and
   ESM resolves a bare import relative to the importing file — so a plain
   `import 'playwright'` looks in the skill's (nonexistent) node_modules and
   fails even when the project has playwright installed. Resolve it from the
   working directory instead. */
let chromium;
try {
  /* require(), not import(): playwright is CommonJS, and a dynamic import of a
     CJS file by URL does not reliably surface its named exports. */
  const req = createRequire(pathToFileURL(process.cwd() + '/'));
  chromium = req('playwright').chromium;
} catch {
  try {
    ({ chromium } = await import('playwright'));
  } catch {
    console.error('playwright not found. From your project directory, run:');
    console.error('  npm i -D playwright && npx playwright install chromium');
    console.error('Or skip this check and open index.html in a browser instead.');
    process.exit(2);
  }
}

const args = process.argv.slice(2);
const url = args.find((a) => !a.startsWith('--'));
const flag = (name, dflt) => {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};

if (!url) {
  console.error('usage: node smoke.mjs <url> [--out shot.png] [--steps 60] [--dpr 1]');
  process.exit(2);
}

const out = flag('out', 'smoke.png');
const maxSteps = Number(flag('steps', 60));
const dpr = Number(flag('dpr', 1));

const fail = [];
const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: dpr
});

page.on('console', (m) => {
  if (m.type() === 'error' || m.type() === 'warning') fail.push(`${m.type()}: ${m.text()}`);
});
page.on('pageerror', (e) => fail.push(`pageerror: ${e.message}`));
page.on('requestfailed', (r) => fail.push(`requestfailed: ${r.url()}`));

await page.goto(url, { waitUntil: 'load' });
await page.waitForTimeout(1000);

/* The globals every project built from this skill exposes. If one is missing, a
   script tag is out of order or a file threw while loading. */
const globals = await page.evaluate(() =>
  ['Iso', 'World', 'Sim', 'Renderer', 'UI'].filter((k) => !window[k])
);
if (globals.length) fail.push(`missing globals: ${globals.join(', ')}`);

let seen = [];
let finished = false;

if (!globals.length) {
  /* Step past the reading stops rather than waiting them out: step() zeroes the
     current dwell and advances exactly one station. The wait between steps has
     to cover travel to the next station, not just the step itself. */
  for (let i = 0; i < maxSteps; i++) {
    await page.evaluate(() => {
      window.Sim.state.speed = 8;
      window.Sim.step();
    });
    await page.waitForTimeout(420);
    const st = await page.evaluate(() => ({
      station: window.Sim.state.station,
      finished: window.Sim.state.finished
    }));
    if (st.station) seen.push(st.station);
    if (st.finished) { finished = true; break; }
  }

  const expected = await page.evaluate(() =>
    Object.values(window.World.stations).flat().map((s) => s.id)
  );
  const missed = expected.filter((id) => !seen.includes(id));
  if (missed.length) fail.push(`stations never fired: ${missed.join(', ')}`);
  if (!finished) fail.push(`run did not finish within ${maxSteps} steps`);
}

await page.screenshot({ path: out });
await browser.close();

const unique = [...new Set(seen)];
console.log(`stations visited (${unique.length}): ${unique.join(' → ') || '—'}`);
console.log(`run finished: ${finished}`);
console.log(`screenshot: ${out}`);

if (fail.length) {
  console.error(`\nFAIL (${fail.length}):`);
  for (const f of fail) console.error('  ' + f);
  process.exit(1);
}
console.log('\nPASS — no console or page errors. Now look at the screenshot.');
