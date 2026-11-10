#!/usr/bin/env node
/**
 * GUIDE TEXT SIZE in the real page: the Settings choice, and what it does to the guide.
 *
 * scripts/guide-text-smoke.mjs holds the numbers to the Apple TV's Swift file and Roku's
 * GuideText.brs. This loads the real plex-tuner.html, headless, against a Jellyfin-shaped
 * server, and drives what a viewer does at phone, tablet, desktop and 960x540 (a TV browser:
 * a cursor, clicks only, no keys):
 *
 *   - NORMAL is on a new install and draws the sizes the guide always drew;
 *   - Settings > GENERAL > DISPLAY has NORMAL and LARGE as real buttons; LARGE grows the
 *     program titles, times, CHANNEL heading, channel numbers and names by the Apple TV's
 *     ratios, and nothing else moves: row height, header height and the channel column stay;
 *   - no time label spills out of its slot, nothing leaves the screen, and the Now Playing
 *     panel above the guide is untouched;
 *   - the choice is saved under the Apple TV's key ('large'; anything else is NORMAL), is back
 *     after a reload, and the guide is already LARGE when it first draws;
 *   - never in browser full screen.
 *
 * Set SHOTS=/dir to save screenshots. TUNER_ROOT=/path/to/dist (or dist-selfhost) runs the
 * same checks on a build. NX_TUNER_HTML=/path serves another copy of the page (origin/main's,
 * for the negative control) in place of plex-tuner.html; it must fail.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:guide-text:browser`.
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

// The Apple TV's ratios, read from its source, so this cannot drift from GuideTextSize.swift.
const swift = readFileSync(join(repo, "Nostalgex/Nostalgex/Models/GuideTextSize.swift"), "utf8");
const metrics = (name) => {
  const block = new RegExp(`static let ${name} = GuideTextMetrics\\(([^)]*)\\)`).exec(swift);
  if (!block) throw new Error(`GuideTextSize.swift has no ${name} metrics`);
  return Object.fromEntries([...block[1].matchAll(/(\w+):\s*([\d.]+)/g)].map((m) => [m[1], Number(m[2])]));
};
const normal = metrics("normal");
const large = metrics("large");
const ratio = {
  title: large.title / normal.title, time: large.timeLabel / normal.timeLabel,
  head: large.channelHeading / normal.channelHeading, num: large.number / normal.number, name: large.name / normal.name,
};

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

async function launch(name, { stored } = {}) {
  const ctx = await browser.newContext({ ...viewports[name], timezoneId: "America/New_York" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url, saved]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      if (saved !== null) localStorage.setItem("nostalgex_guide_text_size", saved);
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
    }
  }, [api, stored === undefined ? null : stored]);
  const page = await ctx.newPage();
  page.setDefaultTimeout(10000);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  return { ctx, page, errors };
}
// A desktop viewport draws a program title at 18 px x the guide factor (1.3) x the row text share (0.76: the Apple TV took its row
// text from 29 to 22 pt on 2026-11-10).
const DESKTOP_NORMAL = 18 * 1.3 * 0.76;
const settle = (page, ms = 500) => page.waitForTimeout(ms);

/** Everything the checks read about the guide, in one snapshot. */
const read = (page) => page.evaluate(() => {
  const px = (el, prop = "fontSize") => (el ? parseFloat(getComputedStyle(el)[prop]) : null);
  const box = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return { w: Math.round(r.width * 100) / 100, h: Math.round(r.height * 100) / 100, l: r.left, rt: r.right, t: r.top, b: r.bottom }; };
  const row = document.querySelector("#grid-body .grid-row[data-channel-id]");
  const slots = [...document.querySelectorAll("#grid-time-slots .grid-time-slot")];
  const spills = slots.filter((s) => s.scrollWidth > s.clientWidth + 1).map((s) => `${s.textContent} ${s.scrollWidth}>${s.clientWidth}`);
  // A label wider than its slot makes the slot grow (flex items do not shrink below their
  // content), and the header runs off the screen and out of line with the program blocks.
  const hdr = document.querySelector(".grid-header");
  const progs = row && row.querySelector(".grid-row-programs");
  const slotsRight = slots.length ? slots[slots.length - 1].getBoundingClientRect().right : 0;
  const slotsW = document.getElementById("grid-time-slots").getBoundingClientRect().width;
  const progsW = progs ? progs.getBoundingClientRect().width : 0;
  const chip = (size) => document.querySelector(`#cfg-guide-text-chips [data-size="${size}"]`);
  const info = document.getElementById("info-title");
  return {
    large: document.body.classList.contains("guide-text-large"),
    stored: localStorage.getItem("nostalgex_guide_text_size"),
    program: px(document.querySelector("#grid-body .grid-program")),
    time: px(slots[0]),
    head: px(document.querySelector(".grid-channel-col")),
    num: px(row && row.querySelector(".grid-ch-num")),
    name: px(row && row.querySelector(".grid-ch-name")),
    numMin: px(row && row.querySelector(".grid-ch-num"), "minWidth"),
    rowH: box(row) && box(row).h,
    headerH: box(document.querySelector(".grid-header")) && box(document.querySelector(".grid-header")).h,
    channelColW: box(document.querySelector(".grid-channel-col")) && box(document.querySelector(".grid-channel-col")).w,
    rowChannelW: box(row && row.querySelector(".grid-row-channel")) && box(row.querySelector(".grid-row-channel")).w,
    spills,
    headerFits: hdr ? hdr.scrollWidth <= hdr.clientWidth + 1 && slotsRight <= innerWidth + 0.5 : false,
    slotsAlign: Math.abs(slotsW - progsW) <= 1 && slots.every((s) => Math.abs(s.getBoundingClientRect().width - slotsW / slots.length) <= 1),
    guide: box(document.getElementById("guide-grid")),
    infoSize: px(info),
    chips: { normal: chip("normal") ? { pressed: chip("normal").getAttribute("aria-pressed"), rect: box(chip("normal")) } : null, large: chip("large") ? { pressed: chip("large").getAttribute("aria-pressed"), rect: box(chip("large")) } : null },
    configOpen: document.getElementById("config-overlay").classList.contains("open"),
    fullscreen: !!document.fullscreenElement,
    vw: innerWidth, vh: innerHeight,
  };
});

async function openSettingsGeneral(page) {
  const rail = page.locator(".v-btn:has(.v-btn-label:text-is('SETTINGS'))");
  if (await rail.first().isVisible().catch(() => false)) await rail.first().click();
  else { await page.locator("#m-menu-btn").click(); await page.locator(".m-drawer-item:has-text('SETTINGS')").click(); }
  await settle(page, 300);
  // Wide screens have the Settings rail (#rail-general); a phone has the tab strip (#tab-general).
  const railItem = page.locator("#rail-general");
  if (await railItem.isVisible().catch(() => false)) await railItem.click(); else await page.locator("#tab-general").click();
  await settle(page, 300);
}
// Settings and the guide scroll rows into view smoothly; measure once the guide has stopped moving.
const closeSettings = async (page) => {
  await page.locator(".config-close").click();
  await settle(page, 400);
  let last = "";
  for (let i = 0; i < 30; i++) {
    const now = await page.evaluate(() => { const r = document.getElementById("guide-grid").getBoundingClientRect(); return `${r.left},${r.top},${r.width},${r.height},${scrollX},${scrollY}`; });
    if (now === last) break;
    last = now;
    await settle(page, 150);
  }
};
const near = (a, b) => a !== null && Math.abs(a - b) < 0.05;

for (const name of Object.keys(viewports)) try {
  if (process.env.DEBUG_GT) console.log("viewport", name);
  const { page, errors } = await launch(name);
  let s = await read(page);
  const n = s;   // NORMAL: what the guide drew before the setting existed
  check(`${name}: new install is NORMAL, nothing saved`, s.large === false && s.stored === null, `${s.large} ${s.stored}`);
  check(`${name}: the guide has rows and time labels`, n.program !== null && n.time !== null && n.num !== null && n.name !== null && n.head !== null);
  check(`${name}: NORMAL spills no time label`, n.spills.length === 0, n.spills.join(", "));
  check(`${name}: NORMAL header fits the screen and lines up with the rows`, n.headerFits && n.slotsAlign, `${n.headerFits} ${n.slotsAlign}`);

  await openSettingsGeneral(page);
  s = await read(page);
  check(`${name}: Settings > GENERAL has NORMAL and LARGE buttons`, !!s.chips.normal && !!s.chips.large);
  check(`${name}: NORMAL is pressed, LARGE is not`, s.chips.normal.pressed === "true" && s.chips.large.pressed === "false", JSON.stringify(s.chips));
  const lb = s.chips.large.rect;
  check(`${name}: LARGE is on screen`, lb && lb.l >= 0 && lb.rt <= s.vw + 0.5 && lb.w > 20 && lb.h > 12, JSON.stringify(lb));

  await page.locator('#cfg-guide-text-chips [data-size="large"]').scrollIntoViewIfNeeded();
  await page.locator('#cfg-guide-text-chips [data-size="large"]').click();
  await settle(page, 400);
  s = await read(page);
  check(`${name}: click LARGE: pressed, class set, saved as 'large'`, s.large && s.chips.large.pressed === "true" && s.chips.normal.pressed === "false" && s.stored === "large", `${s.large} ${s.stored}`);
  if (shots && (name === "tv960" || name === "phone")) await page.screenshot({ path: join(shots, `guide-text-settings-${name}.png`) });
  await closeSettings(page);
  s = await read(page);
  const L = s;
  check(`${name}: LARGE program titles x${ratio.title.toFixed(2)}`, near(L.program, n.program * ratio.title), `${n.program} -> ${L.program}`);
  // On a phone the four time columns are 72px wide, so the times grow by 1.05 and no more.
  const timeRatio = s.vw <= 560 ? 1.05 : ratio.time;
  check(`${name}: LARGE times x${timeRatio.toFixed(2)}`, near(L.time, n.time * timeRatio), `${n.time} -> ${L.time}`);
  check(`${name}: LARGE CHANNEL heading x${ratio.head.toFixed(2)}`, near(L.head, n.head * ratio.head), `${n.head} -> ${L.head}`);
  check(`${name}: LARGE channel number x${ratio.num.toFixed(2)}`, near(L.num, n.num * ratio.num), `${n.num} -> ${L.num}`);
  check(`${name}: LARGE channel name x${ratio.name.toFixed(2)}`, near(L.name, n.name * ratio.name), `${n.name} -> ${L.name}`);
  check(`${name}: LARGE number box grows with the number`, near(L.numMin, n.numMin * ratio.num), `${n.numMin} -> ${L.numMin}`);
  check(`${name}: LARGE keeps the row, the header and the channel column`, L.rowH === n.rowH && L.headerH === n.headerH && L.channelColW === n.channelColW && L.rowChannelW === n.rowChannelW,
    JSON.stringify({ rowH: [n.rowH, L.rowH], headerH: [n.headerH, L.headerH], col: [n.channelColW, L.channelColW], rowCol: [n.rowChannelW, L.rowChannelW] }));
  check(`${name}: LARGE leaves the Now Playing panel alone`, L.infoSize === n.infoSize, `${n.infoSize} -> ${L.infoSize}`);
  check(`${name}: LARGE spills no time label`, L.spills.length === 0, L.spills.join(", "));
  check(`${name}: LARGE header fits the screen and lines up with the rows`, L.headerFits && L.slotsAlign, `${L.headerFits} ${L.slotsAlign}`);
  check(`${name}: the guide stays on screen`, L.guide && L.guide.l >= 0 && L.guide.rt <= L.vw + 0.5 && L.guide.b <= L.vh + 0.5, JSON.stringify(L.guide));
  if (shots && (name === "tv960" || name === "phone" || name === "desktop")) await page.screenshot({ path: join(shots, `guide-text-large-${name}.png`) });

  // A reload keeps it, and the first guide drawn is already LARGE.
  await page.reload();
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await settle(page, 1500);
  s = await read(page);
  check(`${name}: reload keeps LARGE`, s.large && near(s.program, n.program * ratio.title), `${s.large} ${s.program}`);

  // And back: NORMAL is exactly what it was.
  await openSettingsGeneral(page);
  await page.locator('#cfg-guide-text-chips [data-size="normal"]').scrollIntoViewIfNeeded();
  await page.locator('#cfg-guide-text-chips [data-size="normal"]').click();
  await settle(page, 300);
  await closeSettings(page);
  s = await read(page);
  check(`${name}: click NORMAL: back to the original sizes`, !s.large && s.stored === "normal" && s.program === n.program && s.time === n.time && s.head === n.head && s.num === n.num && s.name === n.name, JSON.stringify({ stored: s.stored, program: [n.program, s.program], time: [n.time, s.time], name: [n.name, s.name] }));
  check(`${name}: not in browser full screen`, s.fullscreen === false);
  check(`${name}: no page errors`, errors.length === 0, errors.join(" | "));
  await page.context().close();
} catch (err) {
  failures.push(`${name} flow stopped: ${String(err.message || err).split("\n")[0]}`);
}

// Anything that is not exactly 'large' is NORMAL, as GuideTextSize.init(stored:) has it.
for (const stored of ["", "normal", "LARGE", "huge", "1"]) try {
  const { page, errors } = await launch("desktop", { stored });
  const s = await read(page);
  check(`stored ${JSON.stringify(stored)} reads as NORMAL`, !s.large && near(s.program, DESKTOP_NORMAL), `${s.large} ${s.program}`);
  check(`stored ${JSON.stringify(stored)}: no page errors`, errors.length === 0, errors.join(" | "));
  await page.context().close();
} catch (err) {
  failures.push(`stored ${JSON.stringify(stored)} stopped: ${String(err.message || err).split("\n")[0]}`);
}
try {
  const { page, errors } = await launch("desktop", { stored: "large" });
  const s = await read(page);
  check("stored 'large' on a new page: LARGE on first draw", s.large && near(s.program, DESKTOP_NORMAL * ratio.title), `${s.large} ${s.program}`);
  check("stored 'large': no page errors", errors.length === 0, errors.join(" | "));
  await page.context().close();
} catch (err) {
  failures.push(`stored 'large' stopped: ${String(err.message || err).split("\n")[0]}`);
}

await browser.close();
for (const res of open) res.destroy();
jellyfin.closeAllConnections?.();
files.closeAllConnections?.();
jellyfin.close();
files.close();

if (failures.length) {
  console.error(`guide text browser: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`guide text browser: ${passed} checks passed`);
process.exit(0);
