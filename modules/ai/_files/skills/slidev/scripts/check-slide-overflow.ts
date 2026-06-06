#!/usr/bin/env -S deno run --allow-env --allow-read --allow-write --allow-net --allow-run --allow-sys --lock=check-slide-overflow.lock --frozen
// Overflow / clipping checker for Slidev decks.
//
// Slidev renders each slide on a fixed logical canvas (default 980×552) and
// scales it to the viewport; anything past the boundary is CLIPPED silently in
// present mode. This script renders each slide at 1280×720 and reports content
// that escapes the canvas. It deliberately covers three blind spots that a
// naive element scan misses:
//   1. bare TEXT NODES (measured via Range geometry, not just leaf elements) —
//      e.g. the tail of a callout after an inline <strong>;
//   2. fixed-height Monaco editors whose container exceeds the canvas, plus a
//      best-effort check for code hidden below the editor's internal fold;
//   3. light AND true dark — dark uses a colorScheme:'dark' browser context
//      (Monaco follows Slidev's useDarkMode(); a manual `.dark` class toggle
//      does NOT flip it), and every tab button is cycled.
//
// Dependency + version are pinned in the import specifier below; the .sh
// wrapper pins the full tree via a co-located --lock/--frozen.
//
// Usage:  check-slide-overflow.ts <range> [port] [--shot <dir>] [--vp WxH] [--tol N]
//   <range>  e.g. "23" or "1-56"
//   port     default 3030
//   --shot   also write light+dark screenshots to <dir> (for agent vision QA)
//   --vp     viewport, default 1280x720
//   --tol    overflow tolerance px, default 2
import { chromium, type Browser, type Page } from "npm:playwright@1.58.2";

function die(msg: string): never {
  console.error(msg);
  Deno.exit(2);
}

const args = [...Deno.args];
let shotDir: string | null = null;
let vp = { width: 1280, height: 720 };
let tol = 2;
const pos: string[] = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--shot") shotDir = args[++i] ?? die("--shot needs a dir");
  else if (a === "--vp") {
    const m = (args[++i] ?? "").match(/^(\d+)x(\d+)$/) ?? die("--vp WxH");
    vp = { width: +m[1], height: +m[2] };
  } else if (a === "--tol") tol = parseInt(args[++i] ?? "2", 10);
  else pos.push(a);
}
const rangeSpec = pos[0] ?? die("Usage: check-slide-overflow.ts <range> [port] [--shot dir]");
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

type Finding = { slide: number; theme: string; tab: string; kind: string; px: number; sel: string; text: string };
const findings: Finding[] = [];
const errors: { slide: number; theme: string; msg: string }[] = [];

if (shotDir) await Deno.mkdir(shotDir, { recursive: true }).catch(() => {});

const browser: Browser = await chromium.launch();

async function visibleSlideClass(page: Page): Promise<string | null> {
  return await page.evaluate(() => {
    const v = [...document.querySelectorAll<HTMLElement>(".slidev-page")].find((p) => p.offsetParent !== null);
    return v ? ([...v.classList].find((c) => /^slidev-page-\d+$/.test(c)) ?? null) : null;
  });
}

async function collect(page: Page, slideCls: string, n: number, theme: string, tab: string) {
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
  for (const r of rows) findings.push({ slide: n, theme, tab, ...r });
}

async function scrollInnerToBottom(page: Page, slideCls: string) {
  await page.evaluate((slideCls) => {
    document.querySelector(`.${slideCls}`)?.querySelectorAll<HTMLElement>("*").forEach((el) => {
      const oy = getComputedStyle(el).overflowY;
      if ((oy === "auto" || oy === "scroll") && el.scrollHeight > el.clientHeight + 1) el.scrollTop = el.scrollHeight;
    });
  }, slideCls).catch(() => {});
  await page.waitForTimeout(80);
}

for (const theme of ["light", "dark"] as const) {
  const ctx = await browser.newContext({ viewport: vp, colorScheme: theme });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => {
    if (!/Wake Lock|remeasureFonts/i.test(e.message)) errors.push({ slide: -1, theme, msg: "pageerror: " + e.message.slice(0, 140) });
  });
  page.on("console", (m) => {
    if (m.type() === "error") {
      const t = m.text();
      if (/Failed to fetch dynamically imported module|Internal Server Error|500/i.test(t))
        errors.push({ slide: -1, theme, msg: "console: " + t.slice(0, 140) });
    }
  });

  for (let n = start; n <= end; n++) {
    try {
      const resp = await page.goto(`${BASE}/${n}`, { waitUntil: "networkidle", timeout: 20000 });
      if (!resp || !resp.ok()) { errors.push({ slide: n, theme, msg: `HTTP ${resp?.status()}` }); continue; }
    } catch (e) {
      errors.push({ slide: n, theme, msg: `goto failed: ${e}` });
      continue;
    }
    await page.waitForTimeout(700); // Monaco mount + theme settle
    const slideCls = await visibleSlideClass(page);
    if (!slideCls) { errors.push({ slide: n, theme, msg: "no visible .slidev-page" }); continue; }

    const tabs = page.locator(`.${slideCls}`).locator(TAB_SELECTOR);
    const tabCount = await tabs.count();
    if (tabCount === 0) {
      await scrollInnerToBottom(page, slideCls);
      await collect(page, slideCls, n, theme, "(no tabs)");
    } else {
      for (let i = 0; i < tabCount; i++) {
        const label = (await tabs.nth(i).textContent())?.trim() || `tab${i}`;
        await tabs.nth(i).click({ timeout: 2000 }).catch(() => {});
        await page.waitForTimeout(220);
        await scrollInnerToBottom(page, slideCls);
        await collect(page, slideCls, n, theme, label);
      }
    }
    if (shotDir) await page.screenshot({ path: `${shotDir}/slide-${String(n).padStart(2, "0")}-${theme}.png` });
    Deno.stdout.writeSync(new TextEncoder().encode(`slide ${n} [${theme}]: ${findings.some((f) => f.slide === n && f.theme === theme) ? "ISSUE" : "ok"} (tabs:${tabCount})\n`));
  }
  await ctx.close();
}
await browser.close();

console.log("\n===== SUMMARY =====");
const bad = new Set([...findings.map((f) => f.slide), ...errors.map((e) => e.slide).filter((s) => s > 0)]);
if (bad.size === 0 && errors.length === 0) {
  console.log(`✓ slides ${start}–${end} clean (light + true dark, all tabs).`);
  Deno.exit(0);
}
for (const e of errors) console.log(`⚠ slide ${e.slide > 0 ? e.slide : "?"} [${e.theme}] ${e.msg}`);
for (const n of [...bad].sort((a, b) => a - b)) {
  const fs = findings.filter((f) => f.slide === n).sort((a, b) => b.px - a.px);
  if (!fs.length) continue;
  console.log(`\nSlide ${n}:`);
  for (const f of fs.slice(0, 5)) console.log(`  ${f.kind === "fold" ? "⏷" : "↧"} +${f.px}px [${f.tab}·${f.theme}] ${f.sel} "${f.text}"`);
}
console.log(`\n✗ ${bad.size} slide(s) need attention.`);
Deno.exit(1);
