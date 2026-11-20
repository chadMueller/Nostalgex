#!/usr/bin/env node
/**
 * EPISODE ORDER (I-103) in the real plex-tuner.html (headless), against a Jellyfin-shaped stub with two shows of
 * numbered episodes. The engine and its goldens are `npm run test:episode-order` and `test:schedule-parity`
 * (scripts/nostalgex-daily-manifest.js, the file the Apple TV and Roku port); this is the page around it:
 *   - every episode the scan reads carries its seTag ("S01E04"), which CLASSIC RERUNS needs to find the next one, and a
 *     library saved before that gets it back from the item's meta when it is restored;
 *   - CHANNELS & BUNDLES has an EPISODE ORDER row, CLASSIC RERUNS by default, with the Apple TV's words
 *     ("Two episodes of a show back to back, in order." ... "Movie channels are not affected.");
 *   - on CLASSIC RERUNS a channel airs a show's episodes two consecutive ones at a time (no two of one show in a row
 *     that are not neighbours in the series); one press makes it SHUFFLE (one at a time, a different schedule), saved
 *     in localStorage and kept across a reload; another press is back to CLASSIC RERUNS, with the first schedule again
 *     and the saved key removed (the default is no key, as on the Apple TV);
 *   - the row is a real button that fits the screen and can be pressed with the mouse at desktop, 960x540 (DPR 2, a TV
 *     browser with no keys) and phone width.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:episode-order:browser`. Headless only.
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
const SHOWS = ["alpha", "beta"];
const EPISODES = Object.fromEntries(SHOWS.map((s) => [s, Array.from({ length: 14 }, (_, i) => episode(s, i))]));
const SERIES = SHOWS.map((s) => ({ Id: s, Name: s === "alpha" ? "Alpha Show" : "Beta Show", Type: "Series", ProductionYear: 1992, Genres: ["Comedy"], Studios: [], ProviderIds: {}, OfficialRating: "TV-PG", CommunityRating: 7 }));
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
const ORDER_KEY = "nostalgex_episode_order";
const settledGuide = (page) => page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof allItemsCache !== "undefined" && allItemsCache.length > 0
  && document.getElementById("loading-library").style.display === "none", null, { timeout: 45000 }).then(() => page.waitForTimeout(800));
const stored = (page) => page.evaluate((k) => localStorage.getItem(k), ORDER_KEY);

// The channel with the most episode blocks for both shows, as its schedule stands: [{ show, se }] in air order.
const airing = (page) => page.evaluate(() => {
  const withBlocks = CHANNELS.filter((c) => c.enabled && c._manifestBlocks && c._manifestBlocks.some((b) => b.item.type === "episode"));
  let best = null;
  for (const c of withBlocks) {
    const shows = new Set(c._manifestBlocks.filter((b) => b.item.type === "episode").map((b) => b.item.title));
    if (!best || shows.size > best.shows) best = { c, shows: shows.size };
  }
  if (!best) return { channel: null, blocks: [], channels: CHANNELS.filter((c) => c.enabled).map((c) => c.name) };
  const blocks = best.c._manifestBlocks.filter((b) => b.item.type === "episode").map((b) => ({ show: b.item.title, se: b.item.seTag, key: b.item.ratingKey }));
  return { channel: best.c.name, blocks };
});
// Adjacent blocks of one show: are they neighbours in that show's series order (S01E01 ... S02E07, then round to S01E01)?
function pairs(blocks) {
  const order = {};
  for (const s of SHOWS) order[s === "alpha" ? "Alpha Show" : "Beta Show"] = EPISODES[s].map((e) => `S${String(e.ParentIndexNumber).padStart(2, "0")}E${String(e.IndexNumber).padStart(2, "0")}`);
  let consecutive = 0, other = 0;
  for (let i = 0; i + 1 < blocks.length; i++) {
    const a = blocks[i], b = blocks[i + 1];
    if (a.show !== b.show) continue;
    const list = order[a.show];
    const ia = list.indexOf(a.se), ib = list.indexOf(b.se);
    if (ia >= 0 && ib === (ia + 1) % list.length) consecutive++; else other++;
  }
  return { consecutive, other };
}
const sequence = (blocks) => blocks.map((b) => b.key).join();

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

  const read = await page.evaluate(() => allItemsCache.filter((i) => i.type === "episode").map((i) => i.seTag));
  check(`${label}: every episode the scan read carries its seTag`, read.length === 28 && read.every((t) => /^S0[12]E0[1-7]$/.test(t)), JSON.stringify(read.slice(0, 5)));
  check(`${label}: with nothing saved, the engine is on CLASSIC RERUNS`, await page.evaluate(() => NostalgexDailyManifest.getEpisodeOrder()) === "classic" && (await stored(page)) === null);

  // A library saved before the scan kept seTag has none: the number is read back from the item's meta when it is restored.
  const restored = await page.evaluate(async () => {
    saveLibraryCache(allItemsCache.map((i) => { const c = { ...i }; delete c.seTag; return c; }));
    for (let n = 0; n < 25; n++) {
      await new Promise((r) => setTimeout(r, 200));
      const back = await loadLibraryCache(true);
      if (back && back.items.length) return back.items.filter((i) => i.type === "episode").map((i) => `${i.title}:${i.seTag}`);
    }
    return null;
  });
  check(`${label}: a library saved without seTag gets it back from the item's meta when it is restored`, restored && restored.length === 28 && restored.every((t) => /:S0[12]E0[1-7]$/.test(t)), JSON.stringify((restored || []).slice(0, 3)));

  const first = await airing(page);
  check(`${label}: some channel airs episodes of both shows`, first.channel !== null && new Set(first.blocks.map((b) => b.show)).size === 2, JSON.stringify(first.channels || first.channel));
  const classic = pairs(first.blocks);
  check(`${label}: CLASSIC RERUNS: shows air in pairs, and no two in a row from one show are anything but neighbours in the series`, classic.consecutive > 0 && classic.other === 0, JSON.stringify(classic));

  // The row, in CHANNELS & BUNDLES.
  await page.evaluate(() => { showConfig(); switchConfigTab("bundles"); });
  await page.waitForSelector("#cfg-episode-order-btn", { state: "visible", timeout: 10000 });
  const row = () => page.evaluate(() => {
    const b = document.getElementById("cfg-episode-order-btn"); b.scrollIntoView({ block: "center" }); const r = b.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return { button: b.textContent, desc: document.getElementById("cfg-episode-order-desc").textContent, title: document.querySelector("#chan-episode-order-row .cfg-row-title").textContent,
      reachable: !!hit && (hit === b || b.contains(hit)), inside: r.left >= 0 && r.right <= innerWidth + 0.5, fits: document.documentElement.scrollWidth <= innerWidth + 1 };
  });
  let r = await row();
  check(`${label}: the row is EPISODE ORDER, on CLASSIC RERUNS, with the Apple TV's words`, r.title === "EPISODE ORDER" && r.button === "CLASSIC RERUNS" && r.desc === "Two episodes of a show back to back, in order. Movie channels are not affected.", JSON.stringify(r));
  check(`${label}: the button is a real button that fits the screen and can be pressed`, r.reachable && r.inside && r.fits, JSON.stringify(r));

  // One press: SHUFFLE.
  await page.click("#cfg-episode-order-btn");
  await page.waitForTimeout(600);
  r = await row();
  check(`${label}: a press makes it SHUFFLE, with its own words`, r.button === "SHUFFLE" && r.desc === "One episode at a time, picked at random. Movie channels are not affected.", JSON.stringify(r));
  check(`${label}: it is saved ("shuffle") and the engine is on it`, (await stored(page)) === "shuffle" && await page.evaluate(() => NostalgexDailyManifest.getEpisodeOrder()) === "shuffle");
  const shuffled = await airing(page);
  const sp = pairs(shuffled.blocks);
  check(`${label}: the schedules were built again: a different order, one episode at a time`, sequence(shuffled.blocks) !== sequence(first.blocks) && sp.other > 0, JSON.stringify(sp));

  // A reload keeps it.
  await page.reload();
  await settledGuide(page);
  check(`${label}: a reload keeps SHUFFLE`, (await stored(page)) === "shuffle" && await page.evaluate(() => NostalgexDailyManifest.getEpisodeOrder()) === "shuffle");
  await page.evaluate(() => { showConfig(); switchConfigTab("bundles"); });
  await page.waitForSelector("#cfg-episode-order-btn", { state: "visible", timeout: 10000 });
  r = await row();
  check(`${label}: and the row says so`, r.button === "SHUFFLE", r.button);

  // Back to CLASSIC RERUNS: the first schedule again, and no key.
  await page.click("#cfg-episode-order-btn");
  await page.waitForTimeout(600);
  r = await row();
  const again = await airing(page);
  check(`${label}: a second press is CLASSIC RERUNS again, with no saved key`, r.button === "CLASSIC RERUNS" && (await stored(page)) === null && await page.evaluate(() => NostalgexDailyManifest.getEpisodeOrder()) === "classic", JSON.stringify(r));
  check(`${label}: and the first schedule is back, episode for episode`, sequence(again.blocks) === sequence(first.blocks));
  check(`${label}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}
await flow("desktop 1440x900", 1440, 900);
await flow("TV browser 960x540", 960, 540, 2);
await flow("phone 390x844", 390, 844);

await browser.close();
for (const s of [jellyfin, files]) s.close();
if (failures.length) {
  console.error(`episode order browser smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`episode order browser smoke: ${passed} checks passed (seTag on every episode; EPISODE ORDER row on CLASSIC RERUNS by default, SHUFFLE after a press, saved and kept across a reload, back again; desktop, 960x540 and phone)`);
process.exit(0);
