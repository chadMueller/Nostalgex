#!/usr/bin/env node
/**
 * GUIDE ROW ACROSS LOCAL MIDNIGHT in the real page: scripts/program-row-layout-smoke.mjs runs renderGrid on a
 * stub DOM; this loads the real plex-tuner.html, headless, against a Jellyfin-shaped server, pins the clock to the
 * evenings before midnight and measures the rows the browser lays out, in pixels:
 *
 *   - no row's programme strip is wider than its window (scrollWidth is its content, overflow or not);
 *   - every programme's left edge is where the engine says it airs, or right after the airing that overlaps it;
 *   - on a night when some channel's airing crosses midnight (the 24-hour window then holds two blocks for the
 *     same minutes), at phone, tablet, desktop and 960x540 (a TV browser: a cursor, clicks only);
 *   - never in browser full screen.
 *
 * Set SHOTS=/dir to save screenshots. TUNER_ROOT=/path/to/dist (or dist-selfhost) runs the same checks on a build.
 * NX_TUNER_HTML=/path serves another copy of the page (origin/main's, for the negative control): it must fail.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:program-row-layout:browser`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const repo = fileURLToPath(new URL("../", import.meta.url));
const root = process.env.TUNER_ROOT ? process.env.TUNER_ROOT.replace(/\/?$/, "/") : repo;
const shots = process.env.SHOTS || "";
if (shots) mkdirSync(shots, { recursive: true });

// ── The server: Jellyfin-shaped, 30 films, so the guide has rows ──
const TICKS = (min) => min * 60 * 10000000;
const items = [];
for (let i = 0; i < 30; i++) {
  items.push({
    Id: `m${i}`, Name: `Family Day ${i}`, Type: "Movie", ProductionYear: 1986 + (i % 13), Genres: ["Family", "Comedy"], OfficialRating: "PG",
    RunTimeTicks: TICKS(95), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", CommunityRating: 7.2,
    MediaSources: [{ Id: `ms${i}`, Container: "mp4", RunTimeTicks: TICKS(95), Size: 2000000, SupportsDirectPlay: true,
      MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Channels: 2, Index: 1 }] }],
  });
}
const open = new Set();
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = req.url;
  if (url.startsWith("/Videos/")) { open.add(res); res.on("close", () => open.delete(res)); return; }
  res.writeHead(200, { "Content-Type": "application/json" });
  if (url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
  if (url.startsWith("/UserViews")) return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.includes("IncludeItemTypes=Movie")) {
    const q = new URL(url, "http://x").searchParams;
    const start = Number(q.get("StartIndex") || 0);
    const limit = Number(q.get("Limit") || 200);
    return res.end(JSON.stringify({ Items: items.slice(start, start + limit), TotalRecordCount: items.length }));
  }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    if (process.env.NX_TUNER_HTML) body = readFileSync(process.env.NX_TUNER_HTML);
    body = Buffer.from(body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>"));
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => jellyfin.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${jellyfin.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;


let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });
const viewports = {
  desktop: { viewport: { width: 1440, height: 900 } },
  tablet: { viewport: { width: 820, height: 1180 } },
  phone: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 3 },
  tv960: { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 },
};

// Evenings (New York time) to try, 21:00 to 23:45 every 15 minutes; the first with an airing across midnight is used.
const NIGHTS = [16, 17, 18, 19, 20, 21, 22];
const at = (day, h, m) => new Date(Date.UTC(2026, 10, day, h + 5, m, 0));   // November: New York is UTC-5

async function measure(page) {
  return page.evaluate(() => {
    const out = { rows: 0, wide: [], late: [], overlapRows: 0, widths: [] };
    const ws = Math.floor(Date.now() / 1800000) * 1800 + guideSlotOffset * 1800;
    for (const row of document.querySelectorAll("#grid-body .grid-row[data-channel-id]")) {
      const ch = CHANNELS.find((c) => String(c.id) === row.dataset.channelId);
      const strip = row.querySelector(".grid-row-programs");
      if (!ch || !strip) continue;
      out.rows++;
      // Rects share one coordinate system (the page can be scaled, as it is at 960 wide); scrollWidth shares clientWidth's.
      const W = strip.getBoundingClientRect().width;
      const kids = [...strip.children];
      const total = kids.reduce((a, k) => a + k.getBoundingClientRect().width, 0);
            if (strip.scrollWidth > strip.clientWidth + 1 || total > W + 1) out.wide.push(`${ch.name}: content ${Math.round(total)}px (scroll ${strip.scrollWidth}) in ${Math.round(W)}px (client ${strip.clientWidth})`);
      const blocks = (ch._manifestBlocks || []).filter((b) => b.endSec > ws && b.startSec < ws + 7200).sort((a, b) => a.startSec - b.startSec);
      if (blocks.some((b, i) => i && b.startSec < blocks[i - 1].endSec)) out.overlapRows++;
      // Where each programme should start: its time, or right after the airing before it.
      let cursor = ws, k = 0;
      const progs = kids.filter((c) => c.classList.contains("grid-program"));
      const left0 = strip.getBoundingClientRect().left;
      for (const b of blocks) {
        const from = Math.max(b.startSec, cursor), to = Math.min(b.endSec, ws + 7200);
        if (to <= from) continue;
        const p = progs[k++];
        cursor = to;
        if (!p) { out.late.push(`${ch.name}: no block for ${b.item.title}`); continue; }
        const want = ((from - ws) / 7200) * W;
        const got = p.getBoundingClientRect().left - left0;
        if (Math.abs(got - want) > 1.5) out.late.push(`${ch.name}: ${b.item.title} at ${Math.round(got)}px, airs at ${Math.round(want)}px`);
      }
    }
    return out;
  });
}

for (const name of Object.keys(viewports)) {
  const ctx = await browser.newContext({ ...viewports[name], timezoneId: "America/New_York" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
    }
  }, [api]);
  const page = await ctx.newPage();
  page.setDefaultTimeout(10000);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.clock.install({ time: at(16, 21, 0) });
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);

  let found = null, windows = 0, wideWindows = 0, lateWindows = 0, worst = "";
  for (const day of NIGHTS) {
    for (let mins = 21 * 60; mins < 24 * 60; mins += 15) {
      await page.clock.setFixedTime(at(day, Math.floor(mins / 60), mins % 60));
      const m = await page.evaluate(() => { rebuildAllSchedules(); renderGrid(); return true; }).then(() => measure(page));
      if (m.overlapRows) {
        windows++;
        if (m.wide.length) { wideWindows++; worst = worst || m.wide[0]; }
        if (m.late.length) { lateWindows++; worst = worst || m.late[0]; }
        if (!found) found = { day, mins, m };
      }
    }
    if (found && windows >= 8) break;
  }
  console.log(`${name}: ${windows} windows with an overlapping channel${found ? ` (first Nov ${found.day} ${Math.floor(found.mins / 60)}:${String(found.mins % 60).padStart(2, "0")}, ${found.m.rows} rows)` : ""};`
    + ` rows wider than the window in ${wideWindows}, programmes off their time in ${lateWindows}${worst ? `; e.g. ${worst}` : ""}`);
  check(`${name}: some night has an airing across midnight`, windows > 0);
  check(`${name}: no row is wider than its window`, wideWindows === 0, worst);
  check(`${name}: every programme starts where it airs`, lateWindows === 0, worst);
  check(`${name}: no page error`, errors.length === 0, errors.join(" | "));
  check(`${name}: not in browser full screen`, await page.evaluate(() => !document.fullscreenElement));
  if (shots && found) {
    await page.clock.setFixedTime(at(found.day, Math.floor(found.mins / 60), found.mins % 60));
    await page.evaluate(() => { rebuildAllSchedules(); renderGrid(); });
    await page.screenshot({ path: join(shots, `guide-midnight-${name}.png`) });
  }
  await ctx.close();
}

await browser.close();
jellyfin.close();
files.close();
if (failures.length) {
  console.error(`program-row-layout (browser): ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`program-row-layout (browser): ${passed} checks passed`);
process.exit(0);
