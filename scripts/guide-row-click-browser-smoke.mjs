#!/usr/bin/env node
/**
 * A click or a tap on a guide row moves the cursor to it (plex-tuner.html, headless). Before, the click tuned the channel but left
 * the cyan highlight and the info panel on the row the cursor was on before, which after a bundle stripe select is the bundle's first
 * channel ("picking a channel from the bundle strip leaves the info stuck on the bundle's first channel", Discord #support 2026-11-21).
 * Down then Enter always moved them; only the mouse and the touch path did not.
 *   - with nothing clicked yet, the cursor, the info panel and the playing channel are one channel;
 *   - a click on the bundle stripe's name leaves the cursor on that bundle's first channel;
 *   - a click on a later channel row tunes it AND moves the highlight and the info panel to it (channel tag and title);
 *   - Down from there goes on from the clicked row, not from the bundle's first channel;
 *   - at desktop, 960x540 at DPR 2 (a TV browser, pointer only) and phone width.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:guide-row-click:browser`. Headless only.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (the one before this change): the checks must fail.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

// ── A Jellyfin-shaped server: one library of shows, two of them, 14 numbered episodes each ──
const TICKS = (min) => min * 60 * 10000000;
const episode = (show, i) => {
  const season = 1 + Math.floor(i / 7);
  const number = (i % 7) + 1;
  const id = `${show}-s${season}e${number}`;
  return {
    Id: id, Name: `${show} ${season}x${number}`, Type: "Episode", ParentIndexNumber: season, IndexNumber: number, RunTimeTicks: TICKS(22),
    ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "", ProductionYear: 1992, Genres: ["Comedy"], OfficialRating: "TV-PG", CommunityRating: 7,
    MediaSources: [{ Id: `ms-${id}`, Container: "mp4", Bitrate: 4000000, RunTimeTicks: TICKS(22), Size: 1000000, SupportsDirectPlay: true,
      MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true }] }],
  };
};
// Two different shows with one name ("Twin Show", years apart) number their episodes alike: grouped by title they would be
// one show with every episode twice. A show is its server id (showKey), so each pairs with itself.
const SHOWS = ["alpha", "beta", "twin1", "twin2"];
const NAMES = { alpha: "Alpha Show", beta: "Beta Show", twin1: "Twin Show", twin2: "Twin Show" };
const YEARS = { alpha: 1992, beta: 1992, twin1: 1991, twin2: 1994 };
const EPISODES = Object.fromEntries(SHOWS.map((s) => [s, Array.from({ length: 14 }, (_, i) => episode(s, i))]));
const SERIES = SHOWS.map((s) => ({ Id: s, Name: NAMES[s], Type: "Series", ProductionYear: YEARS[s], Genres: ["Comedy"], Studios: [], ProviderIds: {}, OfficialRating: "TV-PG", CommunityRating: 7 }));
const VIEWS = [{ Id: "lib-tv", Name: "Shows", CollectionType: "tvshows" }];
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  const u = new URL(req.url, "http://x");
  if (req.url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.11.11", ProductName: "Jellyfin Server", Id: "lab" }));
  if (u.pathname === "/UserViews" || /^\/Users\/[^/]+\/Views$/.test(u.pathname)) return res.end(JSON.stringify({ Items: VIEWS, TotalRecordCount: VIEWS.length }));
  if (u.pathname === "/Items") {
    const parent = u.searchParams.get("ParentId");
    const asked = String(u.searchParams.get("IncludeItemTypes") || "").split(",");
    const list = parent === "lib-tv" ? (asked.includes("Series") ? SERIES : []) : (asked.includes("Episode") ? (EPISODES[parent] || []) : []);
    const start = Number(u.searchParams.get("StartIndex") || 0);
    const limit = Number(u.searchParams.get("Limit") || list.length || 1);
    return res.end(JSON.stringify({ Items: list.slice(start, start + limit), TotalRecordCount: list.length }));
  }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});

// ── The page server ──────────────────────────────────────────────────────────
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    if (process.env.NX_TUNER_HTML) body = readFileSync(process.env.NX_TUNER_HTML);
    body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
for (const s of [jellyfin, files]) await new Promise((r) => s.listen(0, "127.0.0.1", r));
const jf = `http://127.0.0.1:${jellyfin.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const browser = await chromium.launch({ headless: true });

const session = { plex90_token: "t", plex90_server_url: jf, plex90_server_name: "lab", plex90_backend: "jellyfin", plex90_jellyfin_user_id: "u" };
const settledGuide = (page) => page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof allItemsCache !== "undefined" && allItemsCache.length > 0
  && document.getElementById("loading-library").style.display === "none", null, { timeout: 45000 }).then(() => page.waitForTimeout(800));

const shown = (page) => page.evaluate(() => ({
  focus: (getEnabledChannels()[guideFocusIndex] || {}).name,
  playing: (CHANNELS.find((c) => c.id === currentChannel) || {}).name,
  tag: (document.getElementById("info-channel-tag") || {}).textContent || "",
  highlighted: [...document.querySelectorAll("#grid-body > .grid-row.focused")].map((r) => Number(r.dataset.channelId)),
  stripeMode: guideStripeMode,
}));
const idOf = (page, name) => page.evaluate((n) => (CHANNELS.find((c) => c.name === n) || {}).id, name);

async function flow(label, width, height, dpr = 1) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: dpr });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  await ctx.addInitScript((sess) => {
    if (!location.pathname.endsWith("plex-tuner.html") || localStorage.getItem("nx-seeded")) return;
    localStorage.setItem("nx-seeded", "1");
    for (const [k, v] of Object.entries(sess)) sessionStorage.setItem(k, v);
    localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: sess.plex90_server_url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
  }, session);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/plex-tuner.html`);
  await settledGuide(page);

  const names = await page.evaluate(() => getEnabledChannels().map((c) => c.name));
  check(`${label}: the lab library gives three channels, the first two in one bundle`, names.length === 3 && names[0] === "90S SITCOMS" && names[1] === "AFTER SCHOOL TV", JSON.stringify(names));
  const groups = await page.evaluate(() => guideStripeGroups().map((g) => ({ pkg: g.pkg && g.pkg.name, first: g.first, count: g.count })));
  check(`${label}: one bundle stripe covers the first two channels`, groups.length === 2 && !!groups[0].pkg && groups[0].first === 0 && groups[0].count === 2, JSON.stringify(groups));

  const start = await shown(page);
  check(`${label}: at the start the cursor, the info panel and the playing channel are one channel`, start.focus === start.playing && start.tag.includes(start.playing), JSON.stringify(start));

  // The cursor goes to the last row, then the bundle's name is clicked: the cursor is on the bundle's first channel.
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  check(`${label}: Down twice puts the cursor on LOCAL WEATHER`, (await shown(page)).focus === "LOCAL WEATHER", JSON.stringify(await shown(page)));
  await page.locator(".grid-stripe-label").first().click();
  await page.waitForTimeout(500);
  const afterStripe = await shown(page);
  check(`${label}: a click on the bundle's name leaves the cursor on its first channel`, afterStripe.focus === "90S SITCOMS" && !afterStripe.stripeMode, JSON.stringify(afterStripe));

  // Now a click on the bundle's second channel: it tunes, and the cursor and the info panel follow.
  const second = await idOf(page, "AFTER SCHOOL TV");
  const row = page.locator(`#grid-body > .grid-row[data-channel-id="${second}"]`);
  await row.scrollIntoViewIfNeeded();
  await row.click({ position: { x: 200, y: 10 } });
  await page.waitForTimeout(800);
  const clicked = await shown(page);
  check(`${label}: a click on a channel row tunes it`, clicked.playing === "AFTER SCHOOL TV", JSON.stringify(clicked));
  check(`${label}: ... and the cursor is on it, not on the bundle's first channel`, clicked.focus === "AFTER SCHOOL TV" && clicked.highlighted.length === 1 && clicked.highlighted[0] === second, JSON.stringify(clicked));
  check(`${label}: ... and the info panel shows it`, clicked.tag.includes("AFTER SCHOOL TV") && !clicked.tag.includes("90S SITCOMS"), JSON.stringify(clicked));

  // The next Down goes on from the clicked row.
  await page.keyboard.press("ArrowDown");
  await page.waitForTimeout(300);
  const down = await shown(page);
  check(`${label}: Down goes on from the clicked row`, down.focus === "LOCAL WEATHER", JSON.stringify(down));

  // A click on a row that is already playing moves nothing else and breaks nothing.
  await page.keyboard.press("ArrowUp");
  await page.waitForTimeout(300);
  await row.click({ position: { x: 200, y: 10 } });
  await page.waitForTimeout(500);
  const again = await shown(page);
  check(`${label}: a click on the playing row keeps the cursor on it`, again.focus === "AFTER SCHOOL TV" && again.playing === "AFTER SCHOOL TV", JSON.stringify(again));
  check(`${label}: no page error`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}

await flow("desktop 1280x800", 1280, 800);
await flow("TV browser 960x540", 960, 540, 2);
await flow("phone 390x844", 390, 844, 2);

await browser.close();
for (const s of [jellyfin, files]) s.close();
if (failures.length) {
  console.error(`guide row click smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`guide row click smoke: ${passed} checks passed (a click or a tap on a guide row moves the cursor, the highlight and the info panel to it, after a bundle stripe select too; desktop, 960x540 and phone)`);
process.exit(0);
