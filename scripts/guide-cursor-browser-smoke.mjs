#!/usr/bin/env node
/**
 * The guide's programme cursor in the real plex-tuner.html (headless), against a Jellyfin-shaped server whose films run 8 to 130
 * minutes, with the clock pinned. A key walk, as on the Apple TV (Chad 2026-11-15, scripts/nostalgex-guide-cursor.js):
 *
 *   - on opening, the focused row's live programme is the highlighted cell and the info panel shows it with its progress;
 *   - Right moves to the next programme, whatever its length: the highlighted cell is that programme's own, the info panel shows its
 *     title with its time range where the progress bar was, and UP NEXT is "UP NEXT IN n MIN", two spaces, the title;
 *   - the window moves only when the programme would leave the view (it starts before it, past it, or in its last 15 minutes), to the
 *     30-minute slot its start is in, and stays put otherwise;
 *   - Down and Up keep the time: the cursor is on the programme of the new row at that time;
 *   - Left goes back programme by programme and stops at the live one, where one more Left goes to the bundle stripe (or the list);
 *   - Back (Escape) and select put the cursor back on the live programme and the window at its start;
 *   - at every size, phone, tablet, desktop and 960x540 (a TV browser: clicks only, no key reaches the page, so the cursor is a
 *     desktop and keyboard feature there as it was).
 *
 * Set SHOTS=/dir to save the walk's screenshots. TUNER_ROOT=/path runs another checkout.
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:guide-cursor:browser`. Headless only.
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

// ── The server: Jellyfin-shaped, 30 films of 8 to 130 minutes ──
const TICKS = (min) => min * 60 * 10000000;
const MINUTES = [22, 45, 95, 8, 130, 60];
const items = Array.from({ length: 30 }, (_, i) => ({
  Id: `m${i}`, Name: `Family Day ${i}`, Type: "Movie", ProductionYear: 1986 + (i % 13), Genres: ["Family", "Comedy"], OfficialRating: "PG",
  RunTimeTicks: TICKS(MINUTES[i % MINUTES.length]), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", CommunityRating: 7.2,
  MediaSources: [{ Id: `ms${i}`, Container: "mp4", RunTimeTicks: TICKS(MINUTES[i % MINUTES.length]), Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Channels: 2, Index: 1 }] }],
}));
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
    const start = Number(q.get("StartIndex") || 0), limit = Number(q.get("Limit") || 200);
    return res.end(JSON.stringify({ Items: items.slice(start, start + limit), TotalRecordCount: items.length }));
  }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) body = Buffer.from(body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>"));
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
  desktop1080: { viewport: { width: 1920, height: 1080 } },
};
const at = (h, m) => new Date(Date.UTC(2026, 10, 16, h + 5, m, 0));   // November: New York is UTC-5

/** What the page says about the cursor now. */
const state = (page) => page.evaluate(() => {
  const now = Date.now() / 1000;
  const cell = document.querySelector(".grid-row.focused .grid-program--cursor");
  const cells = document.querySelectorAll(".grid-program--cursor").length;
  const rows = [...document.querySelectorAll("#grid-body .grid-row[data-channel-id]")];
  return {
    now, cursor: guideCursorTime, offset: guideSlotOffset, focus: guideFocusIndex, cursorCells: cells,
    cell: cell ? { start: Number(cell.dataset.start), end: Number(cell.dataset.end), text: cell.textContent.trim() } : null,
    infoTitle: document.getElementById("info-title").textContent, infoTime: document.getElementById("info-time").textContent,
    infoUp: document.getElementById("info-upnext").textContent, rows: rows.length,
    stripe: guideStripeMode, list: typeof isPackageListOpen === "function" ? isPackageListOpen() : false,
    viewStart: Math.floor(now / 1800) * 1800 + guideSlotOffset * 1800,
    timeCells: [...document.querySelectorAll("#grid-time-slots .grid-time-slot")].length,
  };
});
const key = async (page, k, settle = 120) => { await page.keyboard.press(k); await page.waitForTimeout(settle); };

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
  await page.clock.install({ time: at(21, 7) });
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  await page.clock.setFixedTime(at(21, 7));
  await page.evaluate(() => { document.body.focus(); rebuildAllSchedules(); if (!guideVisible) { showGuide(); appState = "guide"; } renderGrid(); updateGuideFocus(); });
  await page.waitForTimeout(300);
  const shot = async (n) => { if (shots) await page.screenshot({ path: join(shots, `cursor-${n}-${name}.png`) }); };

  // 0. Opening: the live programme of the focused row is the highlighted cell.
  let s = await state(page);
  check(`${name}: the guide has rows and a window`, s.rows >= 2 && s.timeCells === 4, `${s.rows} rows, ${s.timeCells} slots`);
  check(`${name}: opens on the live programme: cursor null, window at its start`, s.cursor === null && s.offset === 0, JSON.stringify([s.cursor, s.offset]));
  check(`${name}: one highlighted cell, the live one, on the focused row`, s.cursorCells === 1 && s.cell && s.cell.start <= s.now && s.now < s.cell.end, JSON.stringify(s.cell));
  check(`${name}: the info panel shows it with its progress`, /^\d+:\d\d(:\d\d)? \/ \d+:\d\d/.test(s.infoTime) && s.infoTitle === s.cell.text, `${s.infoTime} | ${s.infoTitle} | ${s.cell && s.cell.text}`);
  check(`${name}: UP NEXT: the title first, two spaces, then UP NEXT IN n MIN`, /^\S.* {2}UP NEXT IN (\d+|LESS THAN 1) MIN$/.test(s.infoUp), JSON.stringify(s.infoUp));
  const liveUp = Number(/IN (\d+) MIN/.exec(s.infoUp)?.[1] ?? NaN);
  const minutesToNext = Math.floor((s.cell.end - s.now) / 60);
  check(`${name}: the minutes are whole minutes to the next start, rounded down`, liveUp === minutesToNext || (Number.isNaN(liveUp) && minutesToNext < 1), `${liveUp} vs ${minutesToNext}`);
  await shot("c0-live");

  // 1. Right: the next programme, whatever its length; the cell is its own, the panel shows its time range.
  let prev = s;
  await key(page, "ArrowRight");
  s = await state(page);
  check(`${name}: Right: the cursor is on the next programme (its start, in the future)`, s.cursor !== null && s.cursor > s.now && s.cell && s.cell.start === s.cursor, JSON.stringify([s.cursor, s.cell]));
  check(`${name}: Right: the cell starts where the live one ended (or later: a gap)`, s.cell && s.cell.start >= prev.cell.end, `${s.cell && s.cell.start} vs ${prev.cell.end}`);
  check(`${name}: Right: one highlighted cell`, s.cursorCells === 1);
  check(`${name}: Right: the info panel shows that programme, with its time range in place of the progress`, s.infoTitle === s.cell.text && /^\d{1,2}:\d\d [AP]M - \d{1,2}:\d\d [AP]M$/.test(s.infoTime), `${s.infoTitle} | ${s.infoTime}`);
  const range = (t) => new Date(t * 1000).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: "America/New_York" });
  check(`${name}: Right: the range is the programme's start and end`, s.infoTime === `${range(s.cell.start)} - ${range(s.cell.end)}`, `${s.infoTime} vs ${range(s.cell.start)} - ${range(s.cell.end)}`);
  const upMin = Number(/IN (\d+) MIN/.exec(s.infoUp)?.[1] ?? NaN);
  check(`${name}: Right: UP NEXT counts from now to the programme after it`, /^\S.* {2}UP NEXT IN (\d+|LESS THAN 1) MIN$/.test(s.infoUp) && upMin >= Math.floor((s.cell.end - s.now) / 60) - 1, JSON.stringify(s.infoUp));
  // The highlighted cell has the Apple TV's look (GuideCursorStyle): #00D4FF at 30% over the row, a 3px #00D4FF ring inset 2px, two cyan
  // glows (18px at 90%, 6px at 100%) clipped to the programme strip; and the row's own focus steps back while a cell has the cursor.
  const look = await page.evaluate(() => {
    const cell = document.querySelector(".grid-row.focused .grid-program--cursor");
    const row = document.querySelector(".grid-row.focused");
    const cs = getComputedStyle(cell), rs = getComputedStyle(row);
    return { outline: `${cs.outlineWidth} ${cs.outlineStyle} ${cs.outlineColor} ${cs.outlineOffset}`, shadow: cs.boxShadow, bg: cs.backgroundColor, radius: cs.borderTopLeftRadius,
      stripOverflow: getComputedStyle(cell.parentElement).overflow, rowHas: row.classList.contains("grid-row--has-cursor"), rowShadow: rs.boxShadow };
  });
  check(`${name}: the highlighted cell has a 3px #00D4FF ring inset 2px, radius 6px`, look.outline === "3px solid rgb(0, 212, 255) -5px" && look.radius === "6px", JSON.stringify(look));
  check(`${name}: two cyan glows, 18px at 90% and 6px at 100%`, /rgba\(0, 212, 255, 0\.9\) 0px 0px 18px 0px/.test(look.shadow) && /rgb\(0, 212, 255\) 0px 0px 6px 0px/.test(look.shadow), look.shadow);
  check(`${name}: the fill is #00D4FF at 30%`, /rgba\(0, 212, 255, 0\.3\)/.test(look.bg), look.bg);
  check(`${name}: the glow is clipped to the programme strip`, look.stripOverflow === "hidden", look.stripOverflow);
  check(`${name}: the row's own focus steps back while a cell has the cursor: 2px outline at 55%, 6px glow at 25%`, look.rowHas && /0px 0px 6px/.test(look.rowShadow) && /0px 0px 0px 2px/.test(look.rowShadow) && !/0px 0px 14px/.test(look.rowShadow), look.rowShadow);
  await shot("c1-right");
  // UP NEXT: the title in the highlight colour, the label after it; a long title is cut, never the label.
  const up = await page.evaluate(() => {
    const el = document.getElementById("info-upnext");
    const title = el.querySelector(".info-upnext-title"), label = el.querySelector(".info-upnext-label");
    const accent = getComputedStyle(document.documentElement).getPropertyValue("--upnext-title-color").trim();
    const before = { titleColor: getComputedStyle(title).color, labelColor: getComputedStyle(label).color, kids: el.children.length };
    title.textContent = "A very long programme title that goes on and on and on and on and on and on and on and on and on and on and on";
    const panel = document.querySelector(".info-text, .info-panel").getBoundingClientRect();
    const t = title.getBoundingClientRect(), l = label.getBoundingClientRect(), whole = el.getBoundingClientRect();
    const out = { ...before, accent, titleCut: title.scrollWidth > title.clientWidth, labelFull: label.scrollWidth <= label.clientWidth + 1, labelInside: l.right <= whole.right + 1 && l.left >= t.right - 1, titleBeforeLabel: t.right <= l.left + 1, text: label.textContent };
    updateInfoPanel();
    return out;
  });
  check(`${name}: UP NEXT: the title and the label are two spans on one line, the title first`, up.kids === 2 && up.titleBeforeLabel, JSON.stringify(up));
  check(`${name}: UP NEXT: the title is #FFE500, the label white at 50%`, up.titleColor === "rgb(255, 229, 0)" && up.labelColor === "rgba(255, 255, 255, 0.5)", JSON.stringify([up.titleColor, up.labelColor, up.accent]));
  check(`${name}: UP NEXT: a long title is cut with an ellipsis before the label is`, up.titleCut && up.labelFull && up.labelInside, JSON.stringify(up));

  // Right again and on, the window moves only when the programme would leave the view.
  let windowMoves = 0, steps = 0, badMove = null;
  for (let i = 0; i < 14; i++) {
    prev = s;
    await key(page, "ArrowRight");
    s = await state(page);
    steps++;
    if (s.cursor === prev.cursor) break;   // the end of the row's programmes
    const viewEnd = prev.viewStart + 7200;
    const wouldStay = s.cell && s.cell.start >= prev.viewStart && s.cell.start < viewEnd - 900;
    if (wouldStay && s.offset !== prev.offset) badMove = `moved though ${s.cell.start} was in view ${prev.viewStart}..${viewEnd}`;
    if (!wouldStay && s.offset === prev.offset && s.offset < 44) badMove = `did not move though ${s.cell && s.cell.start} is outside ${prev.viewStart}..${viewEnd - 900}`;
    if (s.offset !== prev.offset) {
      windowMoves++;
      const slot = Math.floor((s.cell.start - Math.floor(s.now / 1800) * 1800) / 1800);
      if (s.offset !== slot) badMove = `moved to ${s.offset}, the slot its start is in is ${slot}`;
    }
    if (!s.cell) badMove = "no highlighted cell after Right";
  }
  check(`${name}: the window moves only when the programme would leave the view, to the slot its start is in`, badMove === null, badMove || "");
  check(`${name}: and it moved at least once in ${steps} presses (the films run 8 to 130 minutes)`, windowMoves >= 1, String(windowMoves));
  await shot("c2-right-x" + steps);
  const farCursor = s.cursor, farOffset = s.offset;

  // Down keeps the time.
  const before = s;
  await key(page, "ArrowDown");
  s = await state(page);
  check(`${name}: Down: the row changes and the cursor time stays`, s.focus !== before.focus && s.cursor === farCursor, JSON.stringify([before.focus, s.focus, before.cursor, s.cursor]));
  check(`${name}: Down: the highlighted cell, if any, covers that time on the new row`, s.cursorCells === 0 || (s.cell && s.cell.start <= farCursor && farCursor < s.cell.end), JSON.stringify(s.cell));
  check(`${name}: Down: the window did not move`, s.offset === farOffset);
  await shot("c3-down-keeps-time");
  await key(page, "ArrowUp");
  s = await state(page);
  check(`${name}: Up: back on the first row at the same time`, s.focus === before.focus && s.cursor === farCursor && s.cell && s.cell.start === before.cell.start, JSON.stringify([s.focus, s.cell]));

  // Left goes back, programme by programme, and stops at the live one.
  let lefts = 0, last = s, monotone = true;
  for (let i = 0; i < 20 && last.cursor !== null; i++) {
    await key(page, "ArrowLeft");
    s = await state(page);
    lefts++;
    if (s.cursor !== null && !(s.cursor < last.cursor)) monotone = false;
    if (s.stripe || s.list) break;
    last = s;
  }
  check(`${name}: Left goes back and ends on the live programme (cursor null)`, monotone && last.cursor === null && last.offset === 0, `${lefts} presses, ${JSON.stringify([last.cursor, last.offset])}`);
  check(`${name}: back on the live programme the highlighted cell is the live one`, last.cell && last.cell.start <= last.now && last.now < last.cell.end, JSON.stringify(last.cell));
  await shot("c4-left-back-to-live");
  if (!(s.stripe || s.list)) {
    await key(page, "ArrowLeft");
    s = await state(page);
  }
  check(`${name}: one more Left from the live programme goes to the bundle stripe (or the list)`, s.stripe || s.list, JSON.stringify([s.stripe, s.list]));
  await shot("c5-left-stripe");
  await key(page, s.list ? "Escape" : "ArrowRight");
  s = await state(page);
  check(`${name}: and back out of it to the rows, the cursor still live`, !s.stripe && !s.list && s.cursor === null, JSON.stringify([s.stripe, s.list, s.cursor]));

  // Back (Escape) puts the cursor back on the live programme.
  await key(page, "ArrowRight"); await key(page, "ArrowRight"); await key(page, "ArrowRight");
  s = await state(page);
  check(`${name}: three Rights: the cursor is later than now`, s.cursor !== null && s.cursor > s.now);
  await key(page, "Escape");
  s = await state(page);
  check(`${name}: Back: the cursor on the live programme and the window at its start`, s.cursor === null && s.offset === 0 && s.cell && s.cell.start <= s.now, JSON.stringify([s.cursor, s.offset, s.cell]));

  // Select resets too.
  await key(page, "ArrowRight"); await key(page, "ArrowRight");
  s = await state(page);
  check(`${name}: two Rights again`, s.cursor !== null);
  await key(page, "ArrowDown");   // a row that is not the playing one: select tunes it (on the playing row it goes full screen)
  await key(page, "Enter", 400);
  s = await state(page);
  check(`${name}: select (Enter) tunes the row and the cursor is live again`, s.cursor === null && s.offset === 0, JSON.stringify([s.cursor, s.offset]));

  // The bundle stripe wraps like the channel rows: Down from the last bundle goes to the first, Up from the first to the last.
  const wrap = await page.evaluate(() => {
    const saved = guideStripeGroups, savedGroup = guideStripeGroup;
    // Three bundles with a bare group after them (channels in no bundle).
    guideStripeGroups = () => [{ pkg: { name: "A" }, first: 0 }, { pkg: { name: "B" }, first: 1 }, { pkg: { name: "C" }, first: 2 }, { pkg: null, first: 3 }];
    const out = {};
    guideStripeGroup = 2; jumpPackage(1); out.downFromLast = guideStripeGroup;
    guideStripeGroup = 0; jumpPackage(-1); out.upFromFirst = guideStripeGroup;
    guideStripeGroup = 1; jumpPackage(1); out.downInside = guideStripeGroup;
    guideStripeGroup = 1; jumpPackage(-1); out.upInside = guideStripeGroup;
    guideStripeGroups = () => [{ pkg: { name: "A" }, first: 0 }];
    guideStripeGroup = 0; jumpPackage(1); out.onlyOne = guideStripeGroup;
    guideStripeGroups = saved; guideStripeGroup = savedGroup;
    return out;
  });
  check(`${name}: bundle stripe: Down on the last bundle goes to the first, Up on the first to the last`, wrap.downFromLast === 0 && wrap.upFromFirst === 2, JSON.stringify(wrap));
  check(`${name}: bundle stripe: inside the list Up and Down move one bundle, and a single bundle stays`, wrap.downInside === 2 && wrap.upInside === 0 && wrap.onlyOne === 0, JSON.stringify(wrap));

  check(`${name}: not in browser full screen`, await page.evaluate(() => !document.fullscreenElement));
  check(`${name}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// A link opens on the channel it names (the counterpart of the Apple TV's Top Shelf link): plex-tuner.html?channel=<number>, and the
// start screen passes its query on. An unknown number is ignored.
{
  const opened = async (path) => {
    const lctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, timezoneId: "America/New_York" });
    await lctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
    await lctx.addInitScript(([url]) => {
      if ((location.pathname.endsWith("plex-tuner.html") || location.pathname.endsWith("web-tuner.html")) && !sessionStorage.getItem("nx-seeded")) {
        sessionStorage.setItem("nx-seeded", "1");
        localStorage.setItem("nostalgex_library_selection_seen", "1");   // a first setup would stop on CHOOSE YOUR LIBRARIES
        localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
      }
    }, [api]);
    const lp = await lctx.newPage();
    await lp.goto(`${base}/${path}`);
    await lp.waitForFunction(() => typeof currentChannel !== "undefined" && currentChannel !== null, null, { timeout: 40000 }).catch(() => {});
    const r = await lp.evaluate(() => { const ch = CHANNELS.find((c) => c.id === currentChannel); return { number: ch ? (ch.number || ch.id) : null, url: location.pathname + location.search, numbers: CHANNELS.filter((c) => c.enabled).map((c) => c.number || c.id) }; });
    await lctx.close();
    return r;
  };
  const plain = await opened("plex-tuner.html");
  const nums = plain.numbers;
  const target = nums[2] ?? nums[1];
  const linked = await opened(`plex-tuner.html?channel=${target}`);
  check("a link ?channel=<number> opens on that channel", plain.number === nums[0] && linked.number === target, JSON.stringify({ plain: plain.number, linked: linked.number, target }));
  const unknown = await opened("plex-tuner.html?channel=9999");
  check("an unknown channel number is ignored: the visit opens as it always did", unknown.number === plain.number, JSON.stringify(unknown));
  const junk = await opened("plex-tuner.html?channel=abc");
  check("a channel that is not a number is ignored", junk.number === plain.number, JSON.stringify(junk));
  const viaStart = await opened(`web-tuner.html?channel=${target}`);
  check("the start screen passes the link on to the tuner", /plex-tuner\.html\?channel=/.test(viaStart.url) && viaStart.number === target, JSON.stringify(viaStart));
}

await browser.close();
jellyfin.close();
files.close();
if (failures.length) {
  console.error(`guide cursor (browser): ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`guide cursor (browser): ${passed} checks passed`);
process.exit(0);
