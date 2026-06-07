#!/usr/bin/env -S deno run --allow-env --allow-read --allow-write --allow-net --allow-run --allow-sys --lock=check-slide-overflow.lock --frozen
// Overflow / clipping checker for Slidev decks — CROSS-BROWSER.
//
// Slidev renders each slide on a fixed logical canvas (default 980×552) and
// scales it to the viewport; anything past the boundary is CLIPPED silently in
// present mode. This script renders each slide at 1280×720 and reports content
// that escapes the canvas. Because clipping and text wrapping are
// LAYOUT-ENGINE-SPECIFIC (a slide can fit in Chromium yet overflow in Gecko or
// WebKit), it runs every slide through chromium + firefox + webkit by default
// (narrow with --browsers). It deliberately covers three blind spots that a
// naive element scan misses:
//   1. bare TEXT NODES (measured via Range geometry, not just leaf elements) —
//      e.g. the tail of a callout after an inline <strong>;
//   2. fixed-height Monaco editors whose container exceeds the canvas, plus a
//      best-effort check for code hidden below the editor's internal fold;
//   3. light AND true dark — dark uses a colorScheme:'dark' browser context
//      (Monaco follows Slidev's useDarkMode(); a manual `.dark` class toggle
//      does NOT flip it), and every tab button is cycled.
//
// Browsers: the .sh wrapper provisions a nix-pinned playwright-driver.browsers
// bundle (PLAYWRIGHT_BROWSERS_PATH) whose Playwright version MUST equal the pin
// below, falling back to `playwright install` otherwise. That version is
// coupled across THREE places — this import specifier, the deno --lock, and the
// nixpkgs rev in check-slide-overflow.sh — bump all three in lockstep.
//
// PARALLEL: the (engine × theme) combinations run as concurrent "lanes" — one
// browser PROCESS per engine, two CONTEXTS each (light + dark); --jobs splits a
// lane's slides across N concurrent PAGES. Each page BOOTS the Slidev app once
// (full load) then navigates slide-to-slide IN-SPA (pushState + popstate); this
// loads Monaco's huge ESM graph ONCE per page instead of re-pulling it on every
// slide, which otherwise stampedes the single shared Vite dev server and makes
// firefox/webkit serve transient module-load failures. A semaphore
// (--max-concurrency) bounds concurrent navigations to protect that server.
//
// CORRECTNESS — a reported "ok" must really mean ok. Before measuring we gate on
// reliable signals: the active slide is slidev-page-${n}, and the network is quiet
// (the slide's lazy ESM chunk finished — else a half-rendered slide reads as
// tabs:0 and goes UNCHECKED). Then a FIXED wall-clock settle for render + the
// webfont-swap reflow + Monaco mount + CSS transitions: those are pure relayouts
// that fire no observable event, and rAF-based "settle" loops are throttled in
// headless browsers, which makes borderline (~+10px) overflow detection flaky — a
// fixed wait (as the original used) is deterministic. Transient module-load
// failures are RETRIED with a fresh reload; a persistent failure (e.g. a real
// compile-500) survives all retries and is reported loudly — never silently passed.
//
// Usage:  check-slide-overflow.ts <range> [port] [--shot <dir>] [--vp WxH] [--tol N] [--browsers a,b,c] [--jobs N] [--max-concurrency N]
//   <range>     e.g. "23" or "1-56"
//   port        default 3030
//   --shot      also write light+dark screenshots to <dir> (for agent vision QA)
//   --vp        viewport, default 1280x720
//   --tol       overflow tolerance px, default 2
//   --browsers  comma list of chromium,firefox,webkit (default: all three)
//   --jobs      pages per (engine,theme) lane, default 1 (splits the lane's slides)
//   --max-concurrency  cap on concurrent slide measurements, default min(lanes,4)
import { chromium, firefox, webkit, type Browser, type BrowserType, type Page } from "npm:playwright@1.58.2";

const ENGINES: Record<string, BrowserType> = { chromium, firefox, webkit };

function die(msg: string): never {
  console.error(msg);
  Deno.exit(2);
}

const args = [...Deno.args];
let shotDir: string | null = null;
let vp = { width: 1280, height: 720 };
let tol = 2;
let engineNames = ["chromium", "firefox", "webkit"];
let jobs = 1;
let maxConcurrency: number | null = null;
const pos: string[] = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--shot") shotDir = args[++i] ?? die("--shot needs a dir");
  else if (a === "--vp") {
    const m = (args[++i] ?? "").match(/^(\d+)x(\d+)$/) ?? die("--vp WxH");
    vp = { width: +m[1], height: +m[2] };
  } else if (a === "--tol") tol = parseInt(args[++i] ?? "2", 10);
  else if (a === "--jobs") jobs = Math.max(1, parseInt(args[++i] ?? "1", 10) || 1);
  else if (a === "--max-concurrency" || a === "--max-conc") maxConcurrency = Math.max(1, parseInt(args[++i] ?? "6", 10) || 6);
  else if (a === "--browsers") {
    engineNames = (args[++i] ?? die("--browsers needs a comma list"))
      .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
    if (!engineNames.length) die("--browsers needs at least one engine");
    for (const n of engineNames) if (!ENGINES[n]) die(`unknown browser: ${n} (pick from chromium,firefox,webkit)`);
  } else pos.push(a);
}
const rangeSpec = pos[0] ?? die("Usage: check-slide-overflow.ts <range> [port] [--shot dir] [--browsers a,b,c]");
const port = pos[1] ? parseInt(pos[1], 10) : 3030;
const rm = rangeSpec.match(/^(\d+)(?:-(\d+))?$/) ?? die(`bad range: ${rangeSpec}`);
const start = +rm[1];
const end = rm[2] ? +rm[2] : start;
const BASE = `http://localhost:${port}`;
const VH = vp.height;

const TAB_SELECTOR = [
  ".tab-bar button",
  ".tabs button",
  ".ct-tabs button",
  ".eco-tabs button",
  "[role='tablist'] [role='tab']",
].join(", ");

type Row = { kind: string; px: number; sel: string; text: string };
type Finding = { slide: number; browser: string; theme: string; tab: string; kind: string; px: number; sel: string; text: string };
const findings: Finding[] = [];
const errors: { slide: number; browser: string; theme: string; msg: string }[] = [];
const launchFailed: string[] = [];

if (shotDir) await Deno.mkdir(shotDir, { recursive: true }).catch(() => {});

async function collect(page: Page, slideCls: string): Promise<Row[]> {
  const rows = await page.evaluate(
    ({ VH, tol, slideCls }) => {
      const slide = document.querySelector(`.${slideCls}`);
      if (!slide) return [] as { kind: string; px: number; sel: string; text: string }[];
      const out: { kind: string; px: number; sel: string; text: string }[] = [];

      // (1) text nodes via Range — catches bare text an element scan misses.
      const walker = document.createTreeWalker(slide, NodeFilter.SHOW_TEXT);
      let tn: Node | null;
      while ((tn = walker.nextNode())) {
        const txt = (tn.textContent || "").trim();
        if (!txt) continue;
        const pe = (tn as Text).parentElement;
        let inMonaco = false, scroller = false;
        let p: Element | null = pe;
        while (p) {
          if ((p as HTMLElement).classList?.contains("monaco-editor")) inMonaco = true;
          const oy = getComputedStyle(p).overflowY;
          if ((oy === "auto" || oy === "scroll") && p.getBoundingClientRect().bottom <= VH + tol) scroller = true;
          p = p.parentElement;
        }
        if (inMonaco || scroller) continue; // Monaco handled below; real inner scrollers are intentional
        const range = document.createRange();
        range.selectNodeContents(tn);
        let bottom = 0;
        for (const r of range.getClientRects()) if (r.width && r.height) bottom = Math.max(bottom, r.bottom);
        if (bottom <= VH + tol) continue;
        const cls = pe && typeof pe.className === "string" && pe.className
          ? "." + pe.className.split(/\s+/).filter(Boolean).slice(0, 1).join(".") : "";
        out.push({ kind: "overflow", px: Math.round(bottom) - VH, sel: (pe?.tagName.toLowerCase() ?? "#text") + cls, text: txt.slice(0, 50) });
      }

      // (2a) Monaco container itself past the canvas.
      slide.querySelectorAll<HTMLElement>(".monaco-block, .monaco-editor").forEach((el) => {
        const r = el.getBoundingClientRect();
        if (r.height && r.bottom > VH + tol)
          out.push({ kind: "overflow", px: Math.round(r.bottom) - VH, sel: "." + (el.className.split(/\s+/)[0] || "monaco"), text: "(editor container)" });
      });

      // (2b) best-effort: code hidden below a fitting Monaco's internal fold.
      slide.querySelectorAll<HTMLElement>(".monaco-editor").forEach((ed) => {
        const vb = ed.querySelector<HTMLElement>(".scrollbar.vertical");
        const slider = vb?.querySelector<HTMLElement>(".slider");
        if (!vb || !slider) return;
        const vbh = vb.getBoundingClientRect().height;
        const sh = slider.getBoundingClientRect().height;
        if (vbh > 4 && sh > 0 && sh < vbh - 4)
          out.push({ kind: "fold", px: Math.round(vbh - sh), sel: ".monaco-editor", text: "code hidden below editor fold" });
      });

      return out;
    },
    { VH, tol, slideCls },
  );
  return rows;
}

// Measure twice with a short gap and UNION the findings (keeping the max px per
// finding). A borderline overflow (~+2-10px past the canvas) can lag the fixed
// settle by a frame or two under load, so a single read occasionally misses it on
// one lane; a second look a beat later catches it. Findings are stable once they
// appear (verified), so the false-positive risk of unioning is negligible — and
// for a QA gate a redundant flag beats a silent miss.
async function collectUnion(page: Page, slideCls: string): Promise<Row[]> {
  const a = await collect(page, slideCls);
  await page.waitForTimeout(250);
  const b = await collect(page, slideCls);
  const m = new Map<string, Row>();
  for (const r of [...a, ...b]) {
    const id = `${r.kind}|${r.sel}|${r.text}`;
    const prev = m.get(id);
    if (!prev || r.px > prev.px) m.set(id, r);
  }
  return [...m.values()];
}

async function scrollInnerToBottom(page: Page, slideCls: string) {
  // Scroll inner overflow:auto/scroll regions to the bottom so their tail is
  // measurable, then a small wall-clock settle (NOT rAF — throttled in headless).
  await page.evaluate((slideCls) => {
    document.querySelector(`.${slideCls}`)?.querySelectorAll<HTMLElement>("*").forEach((el) => {
      const oy = getComputedStyle(el).overflowY;
      if ((oy === "auto" || oy === "scroll") && el.scrollHeight > el.clientHeight + 1) el.scrollTop = el.scrollHeight;
    });
  }, slideCls).catch(() => {});
  await page.waitForTimeout(80);
}

// Minimal counting semaphore (FIFO). Bounds how many lanes run a full per-slide
// MEASURE (nav → settle → tab-cycle → collect) at once, so they don't stampede the
// shared Vite dev server or starve each other's reflow (which flickers borderline
// overflow detection per-lane).
class Semaphore {
  #avail: number;
  #waiters: (() => void)[] = [];
  constructor(n: number) { this.#avail = n; }
  async acquire(): Promise<void> {
    if (this.#avail > 0) { this.#avail--; return; }
    await new Promise<void>((r) => this.#waiters.push(r));
  }
  release(): void {
    const w = this.#waiters.shift();
    if (w) w(); // hand the slot directly to the next waiter
    else this.#avail++;
  }
}

let done = 0;
let total = 0;
const enc = new TextEncoder();
function tick(engine: string, theme: string, n: number, status: string): void {
  done++;
  // One line per (slide,lane); interleaving-safe (no shared-state scan).
  Deno.stderr.writeSync(enc.encode(`[${done}/${total}] slide ${n} [${engine}·${theme}]: ${status}\n`));
}

// Per-page mutable state shared with its event listeners. `loadErrors` collects
// transient module-load failures for the slide currently being processed; the
// retry loop in processSlide() reads & clears it. `booted` flips true once the
// page has loaded the Slidev app once (then we navigate slide-to-slide in-SPA).
// `inflight` is the live count of in-flight HTTP requests, used to wait for a
// slide's lazily-loaded ESM chunk to finish before measuring.
type PageState = { slide: number; loadErrors: string[]; booted: boolean; inflight: number };

// Wait until the page's network has been QUIET (no in-flight requests) for
// `quietMs`, or a hard cap. Each slide's compiled component is a separate Vite
// ESM chunk fetched on first navigation; under concurrent load it arrives slowly.
// Without this, the fixed render-settle below would start ticking while the chunk
// is still downloading → the tab bar/content isn't there yet → tabs:0 → content
// silently UNCHECKED (observed on webkit under load). This is the reliable analog
// of the original's networkidle. HMR uses a websocket (not counted as a request),
// so it doesn't keep this busy.
async function waitNetworkQuiet(page: Page, state: PageState, quietMs = 250, capMs = 8000): Promise<void> {
  const t0 = Date.now();
  let quietStart = state.inflight === 0 ? Date.now() : 0;
  for (;;) {
    if (state.inflight === 0) {
      if (!quietStart) quietStart = Date.now();
      if (Date.now() - quietStart >= quietMs) return;
    } else {
      quietStart = 0;
    }
    if (Date.now() - t0 >= capMs) return;
    await page.waitForTimeout(50);
  }
}

// A module/network load failure that is TRANSIENT under concurrent Vite load —
// a fresh reload (with Vite's transform now warm) typically succeeds. A real
// compile error (HTTP 500 from a broken slide) produces the same "Failed to
// fetch dynamically imported module" text but is PERSISTENT, so it survives all
// retries and is escalated to a hard error — the retry distinguishes the two.
function isTransientLoad(msg: string): boolean {
  return /Importing a module script failed|loading dynamically imported module|Failed to fetch dynamically imported module|NetworkError when attempting to fetch|Internal Server Error|\b500\b|\[object Event\]/i.test(msg);
}

function attachListeners(page: Page, engine: string, theme: string, state: PageState): void {
  page.on("request", () => { state.inflight++; });
  page.on("requestfinished", () => { state.inflight = Math.max(0, state.inflight - 1); });
  page.on("requestfailed", () => { state.inflight = Math.max(0, state.inflight - 1); });
  page.on("pageerror", (e) => {
    const msg = e.message || "";
    // Benign, engine-specific noise: Slidev's Screen Wake Lock request is denied
    // in headless contexts, phrased differently per engine — Chromium says "Wake
    // Lock", WebKit throws "NotAllowedError: Permission was denied".
    if (/Wake Lock|wakeLock|remeasureFonts|NotAllowedError|Permission was denied/i.test(msg)) return;
    if (isTransientLoad(msg)) { state.loadErrors.push("pageerror: " + msg.slice(0, 140)); return; }
    errors.push({ slide: state.slide, browser: engine, theme, msg: "pageerror: " + msg.slice(0, 140) });
  });
  page.on("console", (m) => {
    if (m.type() !== "error") return;
    const t = m.text();
    // Compile-500 / dynamic-import failures: retryable candidate (see above).
    if (isTransientLoad(t)) state.loadErrors.push("console: " + t.slice(0, 140));
  });
}

// Navigate the page to slide `n` and wait until it is the active slide.
//   boot=true  → full page.goto (loads the Slidev app + Monaco runtime ONCE).
//   boot=false → in-SPA navigation (pushState + popstate) — a lightweight Vue
//                route change that does NOT re-fetch Monaco/@slidev internals.
// Booting every slide (the old approach) re-pulls Monaco's huge ESM graph 6×N
// times from the single Vite dev server, a thundering herd that makes firefox/
// webkit serve transient module-load failures and half-render slides. Booting
// once per page and navigating in-SPA removes that storm. Returns a fatal reason
// or null. We require the active slide's class to be exactly slidev-page-${n} so
// we never measure a transitioning/wrong slide.
async function navTo(page: Page, n: number, boot: boolean, state: PageState): Promise<string | null> {
  if (boot) {
    let resp;
    try {
      // domcontentloaded (not networkidle): under load networkidle both flakes and
      // fires early; the waitForFunction below is the real readiness gate.
      resp = await page.goto(`${BASE}/${n}`, { waitUntil: "domcontentloaded", timeout: 20000 });
    } catch (e) {
      return `goto failed: ${e}`;
    }
    if (!resp || !resp.ok()) return `HTTP ${resp?.status()}`;
    state.booted = true; // app is loaded even if the slide isn't active yet
  } else {
    await page.evaluate((n) => {
      history.pushState({}, "", `/${n}`);
      globalThis.dispatchEvent(new PopStateEvent("popstate"));
    }, n).catch(() => {});
  }
  try {
    await page.waitForFunction(
      (n) => {
        const v = [...document.querySelectorAll<HTMLElement>(".slidev-page")].find((p) => p.offsetParent !== null);
        return !!v && v.classList.contains(`slidev-page-${n}`);
      },
      n,
      { timeout: boot ? 12000 : 8000 },
    );
  } catch {
    return "slide not active";
  }
  return null;
}

// One measurement attempt: navigate to the slide, settle, cycle tabs, collect.
// The ENTIRE attempt runs under the semaphore — not just nav — so --max-concurrency
// genuinely bounds how many pages do CPU-heavy render/measure AT ONCE. The reflow
// after a nav or tab-switch is CPU-bound; if every lane measures simultaneously
// they starve each other's reflow past the fixed settle waits and a borderline
// (~+10px) overflow is seen only intermittently. Returns rows WITHOUT committing
// them, so a transient-failure attempt can be discarded and retried.
type Attempt = { fatal?: string; rows: Finding[]; tabCount: number; slideCls: string | null };
async function attemptSlide(page: Page, n: number, engine: string, theme: "light" | "dark", sem: Semaphore, boot: boolean, state: PageState): Promise<Attempt> {
  await sem.acquire();
  try {
    const fatal = await navTo(page, n, boot, state);
    if (fatal) return { fatal, rows: [], tabCount: 0, slideCls: null };
    await waitNetworkQuiet(page, state); // chunk + fonts + sub-imports loaded (request-event based)
    const slideCls = `slidev-page-${n}`; // guaranteed active by navTo's waitForFunction
    // Fixed render-settle: Monaco mount, the webfont-swap REFLOW, and CSS
    // transitions. A WALL-CLOCK wait on purpose — those are pure relayouts that
    // fire no MutationObserver, and rAF-based "settle" loops are throttled/erratic
    // in headless browsers, which made borderline (~+10px) overflow detection
    // flaky. This is the original's proven 700ms settle, gated behind the real
    // network-quiet check above (which absorbs slow chunk loads under concurrency).
    await page.waitForTimeout(700);

    const rows: Finding[] = [];
    const tabs = page.locator(`.${slideCls}`).locator(TAB_SELECTOR);
    const tabCount = await tabs.count();
    if (tabCount === 0) {
      await scrollInnerToBottom(page, slideCls);
      for (const r of await collectUnion(page, slideCls)) rows.push({ slide: n, browser: engine, theme, tab: "(no tabs)", ...r });
    } else {
      for (let i = 0; i < tabCount; i++) {
        const label = (await tabs.nth(i).textContent())?.trim() || `tab${i}`;
        await tabs.nth(i).click({ timeout: 2000 }).catch(() => {});
        await page.waitForTimeout(300); // tab content swap + reflow settle (fixed wall-clock; see above)
        await scrollInnerToBottom(page, slideCls);
        for (const r of await collectUnion(page, slideCls)) rows.push({ slide: n, browser: engine, theme, tab: label, ...r });
      }
    }
    return { rows, tabCount, slideCls };
  } finally {
    sem.release();
  }
}

// Process one slide, retrying transient module-load failures (the dominant
// concurrency hazard — see attemptSlide / isTransientLoad). Findings are
// committed ONLY from a clean attempt; a persistent failure exhausts the retries
// and is reported loudly (never silently passed). Returns a short status string.
const MAX_ATTEMPTS = 3;
async function processSlide(page: Page, n: number, engine: string, theme: "light" | "dark", sem: Semaphore, shotDir: string | null, state: PageState): Promise<string> {
  let last = "ERR";
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    state.slide = n;
    state.loadErrors = [];
    // First visit of a fresh page → boot (full load). Every retry → a fresh full
    // reload too, so a same-route SPA nav can't just re-measure a half-rendered DOM.
    const boot = !state.booted || attempt > 1;
    const a = await attemptSlide(page, n, engine, theme, sem, boot, state);
    const transient = state.loadErrors.length > 0;

    if (a.fatal) {
      last = `ERR ${a.fatal}`;
      // Retry a rare transient boot blip once (the retry forces a full reload),
      // but a missing/broken slide ("slide not active") is ~always permanent —
      // report it immediately rather than burning several long nav timeouts on a
      // slide that will never appear (e.g. a range that overshoots the deck).
      const giveUp = a.fatal.startsWith("slide not active") || attempt >= 2;
      if (!giveUp) continue;
      errors.push({ slide: n, browser: engine, theme, msg: a.fatal });
      return last;
    }
    if (transient && attempt < MAX_ATTEMPTS) continue; // half-rendered → discard rows, retry

    // Final attempt (clean, or retries exhausted): commit this attempt's findings.
    for (const f of a.rows) findings.push(f);
    if (shotDir) await page.screenshot({ path: `${shotDir}/slide-${String(n).padStart(2, "0")}-${engine}-${theme}.png` });
    if (transient) {
      const seen = new Set<string>();
      for (const m of state.loadErrors) { if (!seen.has(m)) { seen.add(m); errors.push({ slide: n, browser: engine, theme, msg: `load (after ${MAX_ATTEMPTS} tries) ${m}` }); } }
      return `ERR load (tabs:${a.tabCount})`;
    }
    return `${a.rows.length > 0 ? "ISSUE" : "ok"} (tabs:${a.tabCount})`;
  }
  return last;
}

// One lane = one (engine, theme) context. `jobs` pages pull slides from a shared
// queue (queue.shift() is race-free in a single isolate). Isolated: a failure
// here never rejects the sibling lane or other engines.
async function processLane(engine: string, browser: Browser, theme: "light" | "dark", slides: number[], jobs: number, sem: Semaphore, shotDir: string | null): Promise<void> {
  const ctx = await browser.newContext({ viewport: vp, colorScheme: theme }).catch((e) => {
    errors.push({ slide: -1, browser: engine, theme, msg: `context failed: ${String(e).slice(0, 120)}` });
    return null;
  });
  if (!ctx) return;
  try {
    const queue = slides.slice();
    const worker = async (): Promise<void> => {
      const page = await ctx.newPage();
      const state: PageState = { slide: -1, loadErrors: [], booted: false, inflight: 0 };
      attachListeners(page, engine, theme, state);
      let n: number | undefined;
      while ((n = queue.shift()) !== undefined) {
        let status = "ok";
        try { status = await processSlide(page, n, engine, theme, sem, shotDir, state); }
        catch (e) { status = "ERR"; errors.push({ slide: n, browser: engine, theme, msg: `unexpected: ${String(e).slice(0, 140)}` }); }
        finally { tick(engine, theme, n, status); }
      }
      await page.close().catch(() => {});
    };
    await Promise.allSettled(Array.from({ length: Math.max(1, jobs) }, () => worker()));
  } finally {
    await ctx.close().catch(() => {});
  }
}

// Launch all engines concurrently; a launch failure disables only that engine.
const launched = (await Promise.all(engineNames.map(async (name) => {
  try { return { name, browser: await ENGINES[name].launch() }; }
  catch (e) {
    launchFailed.push(name);
    errors.push({
      slide: -1,
      browser: name,
      theme: "-",
      msg: `launch failed — binary missing/incompatible. The wrapper normally provisions all engines (nix-pinned playwright-driver.browsers, or 'playwright install'). ${String(e).slice(0, 120)}`,
    });
    return null;
  }
}))).filter((x): x is { name: string; browser: Browser } => x !== null);

const slides: number[] = [];
for (let n = start; n <= end; n++) slides.push(n);

const laneCount = launched.length * 2; // light + dark per engine
total = laneCount * slides.length;
// Default below laneCount so it actually THROTTLES: the whole per-slide measure
// runs under this semaphore, and letting every lane render+measure at once starves
// each other's reflow (borderline overflow then flickers per-lane). 4 keeps strong
// parallelism while bounding contention; raise --max-concurrency for speed on a
// fast box, lower it on a weak/contended dev server.
const maxConc = Math.max(1, maxConcurrency ?? Math.min(laneCount || 1, 4));
const sem = new Semaphore(maxConc);

// One browser hosts both its theme lanes; close it only after BOTH finish.
await Promise.allSettled(launched.map(async ({ name, browser }) => {
  try {
    await Promise.allSettled([
      processLane(name, browser, "light", slides, jobs, sem, shotDir),
      processLane(name, browser, "dark", slides, jobs, sem, shotDir),
    ]);
  } finally {
    await browser.close().catch(() => {});
  }
}));

console.log("\n===== SUMMARY =====");
const ran = engineNames.filter((n) => !launchFailed.includes(n));
const bad = new Set([...findings.map((f) => f.slide), ...errors.map((e) => e.slide).filter((s) => s > 0)]);
if (bad.size === 0 && errors.length === 0) {
  console.log(`✓ slides ${start}–${end} clean (${ran.join(" + ")}, light + true dark, all tabs).`);
  Deno.exit(0);
}
const seenErr = new Set<string>();
for (const e of errors) {
  const key = `${e.slide}|${e.browser}|${e.theme}|${e.msg}`;
  if (seenErr.has(key)) continue; // dedup: parallel pages can observe the same Vite 500
  seenErr.add(key);
  console.log(`⚠ slide ${e.slide > 0 ? e.slide : "?"} [${e.browser}·${e.theme}] ${e.msg}`);
}
for (const n of [...bad].sort((a, b) => a - b)) {
  const fs = findings.filter((f) => f.slide === n).sort((a, b) => b.px - a.px);
  if (!fs.length) continue;
  console.log(`\nSlide ${n}:`);
  for (const f of fs.slice(0, 6)) console.log(`  ${f.kind === "fold" ? "⏷" : "↧"} +${f.px}px [${f.tab}·${f.browser}·${f.theme}] ${f.sel} "${f.text}"`);
}
if (launchFailed.length) console.log(`\n⚠ engines not tested: ${launchFailed.join(", ")} (failed to launch).`);
console.log(`\n✗ ${bad.size} slide(s) need attention.`);
Deno.exit(1);
