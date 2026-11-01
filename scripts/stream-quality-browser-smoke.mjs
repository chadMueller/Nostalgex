#!/usr/bin/env node
/**
 * STREAM QUALITY on the real page (issue #123), headless, against a Jellyfin-shaped and a
 * Plex-shaped server that record every request the tuner makes when it starts a program.
 *
 * For each level it starts a program the server must transcode (an MKV) and one it could
 * direct play (an MP4 at 20 Mbps) and reads what was asked:
 *   - AUTO and MAXIMUM leave every request exactly as it was before the setting existed
 *     (Jellyfin and Emby: 120 Mbps, MaxWidth 3840, no VideoBitrate; Plex: none of the four
 *     quality parameters), so nobody's playback changes until they pick a level.
 *   - HIGH, MEDIUM and LOW add their ceiling: Plex gets maxVideoBitrate, videoQuality,
 *     videoResolution and autoAdjustQuality=0; Jellyfin and Emby get MaxStreamingBitrate in the
 *     PlaybackInfo body and device profile and VideoBitrate and MaxWidth on the fallback URL.
 *   - A file whose bitrate is above a capped level's ceiling goes through the transcoder instead
 *     of direct playing (a 20 Mbps MP4 at HIGH, MEDIUM and LOW; a 3 Mbps one only at LOW). At AUTO
 *     and MAXIMUM both direct play, as before.
 * It also clicks the real controls: the rail's QUALITY button, the picker, Settings > PLAYBACK.
 * A choice is saved, reloads, and does not touch the program that is already playing.
 * Negative control: the same page with the ceilings taken out, which must fail the capped levels.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:stream-quality:browser`.
 */
import http from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = new URL("../", import.meta.url).pathname;

// ── The servers ──────────────────────────────────────────────────────────────
const log = [];                         // every request the tuner makes: { method, url, body }
const now = new Date().toISOString();
const jfMedia = (id, container, bitrateBps) => [{
  Id: id, Container: container, Bitrate: bitrateBps,
  MediaStreams: [{ Type: "Video", Codec: "h264", Height: 720, Index: 0 }, { Type: "Audio", Codec: "aac", Index: 1, Channels: 2 }],
}];
const jfFilm = (n, container, bitrateBps) => ({
  Id: `jf${n}`, Name: `Tape ${n}`, Type: "Movie", ProductionYear: 1985 + n, Genres: ["Action"], OfficialRating: "R",
  RunTimeTicks: 54000000000, ProviderIds: {}, Studios: [], DateCreated: now, MediaSources: jfMedia(`jf${n}`, container, bitrateBps),
});
const jellyfinFilms = [jfFilm(1, "mkv", 8000000), jfFilm(2, "mp4", 20000000), jfFilm(3, "mp4", 3000000), jfFilm(4, "mkv", 8000000), jfFilm(5, "mkv", 8000000), jfFilm(6, "mkv", 8000000)];
const plexFilm = (n, container, kbps) => ({
  ratingKey: String(100 + n), title: `Tape ${n}`, summary: "", year: 1985 + n, duration: 5400000, type: "movie", addedAt: Math.floor(Date.now() / 1000),
  Genre: [{ tag: "Action" }],
  Media: [{ container, videoResolution: "720", bitrate: kbps, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${n}/file.${container}` }] }],
});
const plexFilms = [plexFilm(1, "mkv", 8000), plexFilm(2, "mp4", 20000), plexFilm(3, "mp4", 3000), plexFilm(4, "mkv", 8000), plexFilm(5, "mkv", 8000), plexFilm(6, "mkv", 8000)];

function readBody(req) {
  return new Promise((resolve) => { const chunks = []; req.on("data", (c) => chunks.push(c)); req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8"))); });
}
function cors(res) { res.setHeader("Access-Control-Allow-Origin", "*"); res.setHeader("Access-Control-Allow-Headers", "*"); res.setHeader("Access-Control-Allow-Methods", "*"); }

const jellyfin = http.createServer(async (req, res) => {
  cors(res);
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const body = await readBody(req);
  log.push({ server: "jellyfin", method: req.method, url: req.url, body });
  const url = req.url;
  if (url.includes("/PlaybackInfo")) { res.writeHead(500); return res.end(); }   // so the tuner builds its fallback URL
  if (url.startsWith("/Videos/")) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  if (url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
  if (url.startsWith("/UserViews")) return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.includes("IncludeItemTypes=Movie")) return res.end(JSON.stringify({ Items: jellyfinFilms, TotalRecordCount: jellyfinFilms.length }));
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});
const plex = http.createServer(async (req, res) => {
  cors(res);
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  log.push({ server: "plex", method: req.method, url: req.url, body: "" });
  const path = req.url.split("?")[0];
  if (path.startsWith("/video/") || path.startsWith("/library/parts/")) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  if (path === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex" } }));
  if (path === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }] } }));
  if (path === "/library/sections/1/all") return res.end(JSON.stringify({ MediaContainer: { size: plexFilms.length, totalSize: plexFilms.length, Metadata: plexFilms } }));
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  // hls.js is stubbed (the page then sets the stream URL on the <video> itself, which is the request we read).
  if (p.endsWith("plex-tuner.html")) {
    let text = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
    // ?nocap: the quality module answering as if no level were capped, for the negative control.
    if (req.url.includes("nocap")) {
      const stripped = text.replace('<script src="scripts/nostalgex-stream-quality.js"></script>', "");
      if (stripped === text && !process.env.ALLOW_MISSING) { res.writeHead(500); return res.end("stream quality script tag not found"); }
      text = stripped.replace("</head>", `<script>window.NostalgexStreamQuality = { current: () => 'auto', plexTranscodeQuery: () => '', mediaBrowserMaxBitrate: () => 120000000, mediaBrowserFallbackOptions: () => ({}), directPlayAllowed: () => true, infoLabel: () => 'x', isCapped: () => false, save() { return true; }, level: () => ({ name: 'Auto' }), chipLabel: (i) => i.toUpperCase(), detail: () => '', LEVELS: [{ id: 'auto' }, { id: 'maximum' }, { id: 'high' }, { id: 'medium' }, { id: 'low' }] };</script></head>`);
    }
    body = text;
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
for (const s of [jellyfin, plex, files]) await new Promise((r) => s.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });
async function open(backend, query = "", viewport = { width: 1440, height: 900 }) {
  const server = backend === "plex" ? plex : jellyfin;
  const ctx = await browser.newContext({ viewport });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url, kind]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      const auth = { token: "t", serverUrl: url, serverName: "lab", backend: kind };
      if (kind === "jellyfin") auth.jellyfinUserId = "u"; else auth.userToken = "t";
      localStorage.setItem("plex90_saved_auth", JSON.stringify(auth));
    }
  }, [`http://127.0.0.1:${server.address().port}`, backend]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/plex-tuner.html${query}`);
  await page.waitForFunction(() => typeof appState !== "undefined" && appState === "player" && allItemsCache.length === 6, null, { timeout: 40000 }).catch(() => {});
  await page.waitForTimeout(800);
  return { ctx, page, errors };
}

/** Starts `ratingKey` through the page's own player and returns the requests it made. */
async function start(page, server, ratingKey, level) {
  await page.evaluate((l) => localStorage.setItem("nostalgex_stream_quality", l), level);
  log.length = 0;
  await page.evaluate((key) => {
    const item = allItemsCache.find((i) => i.ratingKey === key);
    const channel = CHANNELS.find((c) => c.enabled) || CHANNELS[0];
    playCurrentItem({ ...item, offsetSeconds: 0 }, channel);
  }, ratingKey);
  await page.waitForTimeout(1200);
  return log.filter((r) => r.server === server);
}
const q = (url, name) => new URL(url, "http://x").searchParams.get(name);

// ── Jellyfin ─────────────────────────────────────────────────────────────────
const jf = await open("jellyfin");
check("jellyfin: six films load", true);
const CEIL = { high: 12000000, medium: 4000000, low: 1500000 };
const WIDTH = { high: 1920, medium: 1280, low: 854 };
for (const level of ["auto", "maximum", "high", "medium", "low"]) {
  const reqs = await start(jf.page, "jellyfin", "jf1", level);   // an MKV: always the server's transcoder
  const info = reqs.find((r) => r.url.includes("/PlaybackInfo"));
  const master = reqs.find((r) => r.url.includes("/master.m3u8"));
  const body = info ? JSON.parse(info.body) : {};
  if (CEIL[level]) {
    check(`jellyfin ${level}: PlaybackInfo body asks for ${CEIL[level]} bps`, body.MaxStreamingBitrate === CEIL[level], String(body.MaxStreamingBitrate));
    check(`jellyfin ${level}: the device profile asks for the same`, body.DeviceProfile && body.DeviceProfile.MaxStreamingBitrate === CEIL[level]);
    check(`jellyfin ${level}: the fallback URL carries VideoBitrate and MaxWidth`, master && q(master.url, "VideoBitrate") === String(CEIL[level]) && q(master.url, "MaxWidth") === String(WIDTH[level]), master && master.url);
  } else {
    check(`jellyfin ${level}: PlaybackInfo is exactly what it was (120000000)`, body.MaxStreamingBitrate === 120000000 && body.DeviceProfile.MaxStreamingBitrate === 120000000, String(body.MaxStreamingBitrate));
    check(`jellyfin ${level}: the fallback URL is exactly what it was (MaxWidth 3840, no VideoBitrate)`, master && q(master.url, "MaxWidth") === "3840" && q(master.url, "VideoBitrate") === null, master && master.url);
  }
}
// Direct play: the 20 Mbps MP4 (jf2) and the 3 Mbps MP4 (jf3).
// The first request that says how the program is delivered. A mock that 404s a direct play makes
// the page fall back to the transcoder a moment later, which is the page's own recovery and not the
// decision under test, so only the first one counts.
const firstDelivery = (reqs) => reqs.find((r) => /\/stream\.mp4|\/PlaybackInfo|\/master\.m3u8|\/library\/parts\/|\/transcode\/universal\/start/.test(r.url));
const direct = (reqs) => { const r = firstDelivery(reqs); return !!r && (r.url.includes("/stream.mp4") && r.url.includes("Static=true")); };
const viaServer = (reqs) => { const r = firstDelivery(reqs); return !!r && /\/PlaybackInfo|\/master\.m3u8/.test(r.url); };
for (const [level, expect20, expect3] of [["auto", true, true], ["maximum", true, true], ["high", false, true], ["medium", false, true], ["low", false, false]]) {
  const r20 = await start(jf.page, "jellyfin", "jf2", level);
  check(`jellyfin ${level}: a 20 Mbps MP4 ${expect20 ? "direct plays" : "goes through the transcoder"}`, expect20 ? direct(r20) && !viaServer(r20) : viaServer(r20) && !direct(r20), r20.map((r) => r.url.slice(0, 60)).join(" | "));
  const r3 = await start(jf.page, "jellyfin", "jf3", level);
  check(`jellyfin ${level}: a 3 Mbps MP4 ${expect3 ? "direct plays" : "goes through the transcoder"}`, expect3 ? direct(r3) && !viaServer(r3) : viaServer(r3) && !direct(r3), r3.map((r) => r.url.slice(0, 60)).join(" | "));
}
check("jellyfin: no page errors", jf.errors.length === 0, jf.errors.join(" | "));

// ── Plex ─────────────────────────────────────────────────────────────────────
const px = await open("plex");
const PLEX_PARAMS = { high: ["12000", "90", "1920x1080"], medium: ["4000", "75", "1280x720"], low: ["1500", "60", "854x480"] };
for (const level of ["auto", "maximum", "high", "medium", "low"]) {
  const reqs = await start(px.page, "plex", "101", level);   // an MKV
  const t = reqs.find((r) => r.url.includes("/transcode/universal/start.m3u8"));
  if (PLEX_PARAMS[level]) {
    const [kbps, index, res] = PLEX_PARAMS[level];
    check(`plex ${level}: the transcode URL carries the four parameters`, t && q(t.url, "maxVideoBitrate") === kbps && q(t.url, "videoQuality") === index && q(t.url, "videoResolution") === res && q(t.url, "autoAdjustQuality") === "0", t && t.url);
  } else {
    check(`plex ${level}: the transcode URL is exactly what it was (none of the four)`, t && ["maxVideoBitrate", "videoQuality", "videoResolution", "autoAdjustQuality"].every((n) => q(t.url, n) === null), t && t.url);
  }
}
const plexDirect = (reqs) => { const r = firstDelivery(reqs); return !!r && r.url.includes("/library/parts/"); };
const plexTranscode = (reqs) => { const r = firstDelivery(reqs); return !!r && r.url.includes("/transcode/universal/start.m3u8"); };
for (const [level, expect20, expect3] of [["auto", true, true], ["maximum", true, true], ["high", false, true], ["medium", false, true], ["low", false, false]]) {
  const r20 = await start(px.page, "plex", "102", level);
  check(`plex ${level}: a 20 Mbps MP4 ${expect20 ? "direct plays" : "is transcoded"}`, expect20 ? plexDirect(r20) && !plexTranscode(r20) : plexTranscode(r20) && !plexDirect(r20), r20.map((r) => r.url.slice(0, 60)).join(" | "));
  const r3 = await start(px.page, "plex", "103", level);
  check(`plex ${level}: a 3 Mbps MP4 ${expect3 ? "direct plays" : "is transcoded"}`, expect3 ? plexDirect(r3) && !plexTranscode(r3) : plexTranscode(r3) && !plexDirect(r3), r3.map((r) => r.url.slice(0, 60)).join(" | "));
}
check("plex: no page errors", px.errors.length === 0, px.errors.join(" | "));
await jf.ctx.close();
await px.ctx.close();

// ── A library cache written by the page before this setting ───────────────────
// Its items carry no bitrate. A cache is served for up to a day, so unless the version is
// bumped a 20 Mbps MP4 would direct play at LOW until it expired. Each case seeds the cache the
// way the previous page wrote it (version 2, no bitrate) and reloads.
async function staleCache(backend, ratingKey, version) {
  const { ctx, page } = await open(backend);
  // The library cache is an IndexedDB record ({ id, json }) next to an id in localStorage (#152).
  await page.evaluate(async (v) => {
    const db = await new Promise((resolve, reject) => { const r = indexedDB.open("nostalgex-library"); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
    const record = await new Promise((resolve) => { const g = db.transaction("cache").objectStore("cache").get("library"); g.onsuccess = () => resolve(g.result); });
    const cache = JSON.parse(record.json);
    cache.v = v;
    cache.items = cache.items.map((i) => { const { bitrate, ...rest } = i; return rest; });
    await new Promise((resolve) => {
      const tx = db.transaction("cache", "readwrite");
      tx.objectStore("cache").put({ id: record.id, json: JSON.stringify(cache) }, "library");
      tx.oncomplete = resolve;
    });
    db.close();
  }, version);
  await page.reload();
  await page.waitForFunction(() => typeof appState !== "undefined" && appState === "player" && allItemsCache.length === 6, null, { timeout: 40000 }).catch(() => {});
  await page.waitForTimeout(800);
  const withBitrate = await page.evaluate(() => allItemsCache.filter((i) => i.bitrate > 0).length);
  const reqs = await start(page, backend, backend === "plex" ? "102" : "jf2", "low");
  await ctx.close();
  return { withBitrate, reqs };
}
for (const backend of ["jellyfin", "plex"]) {
  const old = await staleCache(backend, null, 2);
  check(`${backend}: a version-2 library cache is refused and the library is read again`, old.withBitrate === 6, String(old.withBitrate));
  check(`${backend}: after that, a 20 Mbps MP4 goes through the transcoder at LOW`, backend === "plex" ? plexTranscode(old.reqs) && !plexDirect(old.reqs) : viaServer(old.reqs) && !direct(old.reqs), old.reqs.map((r) => r.url.slice(0, 50)).join(" | "));
  // Negative control: a cache the page would accept (current version) that holds no bitrate really does direct play.
  const kept = await staleCache(backend, null, 3);
  check(`${backend} negative control: an accepted cache with no bitrate direct plays at LOW`, kept.withBitrate === 0 && (backend === "plex" ? plexDirect(kept.reqs) : direct(kept.reqs)), `${kept.withBitrate} ${kept.reqs.map((r) => r.url.slice(0, 50)).join(" | ")}`);
}

// ── The controls ─────────────────────────────────────────────────────────────
{
  const { ctx, page, errors } = await open("plex");
  await page.evaluate(() => localStorage.removeItem("nostalgex_stream_quality"));
  await page.reload();
  await page.waitForFunction(() => typeof appState !== "undefined" && appState === "player" && allItemsCache.length === 6, null, { timeout: 40000 }).catch(() => {});
  check("controls: a new install is on AUTO (rail value)", (await page.textContent("#tb-quality-val")) === "AUTO");
  await page.click("#tb-quality");
  check("controls: the rail button opens the picker with five levels", await page.evaluate(() => !document.getElementById("quality-dialog").hidden && document.querySelectorAll("#quality-rows .sleep-row").length === 5));
  check("controls: AUTO is the active row", await page.evaluate(() => document.querySelector("#quality-rows .sleep-row.active .sleep-row-label").textContent) === "AUTO");
  if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}-dialog.png` });
  log.length = 0;
  await page.click('#quality-rows .sleep-row[data-level="medium"]');
  check("controls: choosing MEDIUM saves it, closes the picker and updates the rail", await page.evaluate(() => localStorage.getItem("nostalgex_stream_quality") === "medium" && document.getElementById("quality-dialog").hidden && document.getElementById("tb-quality-val").textContent === "MED"));
  await page.waitForTimeout(800);
  check("controls: choosing a level asks the server for nothing", !log.some((r) => r.url.includes("/transcode/") || r.url.includes("/library/parts/")), log.map((r) => r.url.slice(0, 50)).join(" | "));
  await page.keyboard.press("Escape");
  await page.reload();
  await page.waitForFunction(() => typeof appState !== "undefined" && appState === "player", null, { timeout: 40000 }).catch(() => {});
  check("controls: the choice survives a reload", (await page.textContent("#tb-quality-val")) === "MED");
  await page.evaluate(() => { showConfig(); switchConfigTab("general"); });
  const chips = await page.evaluate(() => [...document.querySelectorAll("#cfg-quality-chips .sleep-chip")].map((b) => [b.textContent, b.classList.contains("active")]));
  check("controls: Settings > PLAYBACK has the five chips with MEDIUM active", JSON.stringify(chips) === JSON.stringify([["AUTO", false], ["MAXIMUM", false], ["HIGH 1080P", false], ["MEDIUM 720P", true], ["LOW 480P", false]]), JSON.stringify(chips));
  await page.click('#cfg-quality-chips .sleep-chip[data-level="low"]');
  check("controls: a Settings chip saves too", await page.evaluate(() => localStorage.getItem("nostalgex_stream_quality") === "low" && document.getElementById("tb-quality-val").textContent === "LOW"));
  check("controls: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// ── Negative control ─────────────────────────────────────────────────────────
{
  const { ctx, page } = await open("plex", "?nocap");
  const reqs = await start(page, "plex", "101", "low");
  const t = reqs.find((r) => r.url.includes("/transcode/universal/start.m3u8"));
  check("negative control: without the module a capped level adds no ceiling", t && q(t.url, "maxVideoBitrate") === null, t && t.url);
  const direct20 = await start(page, "plex", "102", "low");
  check("negative control: without the module a 20 Mbps MP4 still direct plays at LOW", plexDirect(direct20));
  await ctx.close();
}

await browser.close();
for (const s of [jellyfin, plex, files]) s.close();
if (failures.length) {
  console.error(`stream-quality browser smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`stream-quality browser smoke: ${passed} checks passed (five levels on a Jellyfin-shaped and a Plex-shaped server, direct play, the controls, and the negative control)`);
