#!/usr/bin/env node
/**
 * GUIDE TIMEOUT in the real plex-tuner.html (headless), with Playwright's clock (#252).
 *
 * The Apple TV's GUIDE TIMEOUT (PR #234): OFF, 5 MIN or 15 MIN, 5 MIN by default. Left alone that long, with a channel playing under
 * a visible guide, the page shows the picture alone (body.nx-idle; not browser full screen). Any key, click, tap or pointer move
 * brings it back and restarts the clock. Settings open, a loading screen and a guide with nothing playing are left alone.
 * The value is kept (key nostalgex_guide_timeout) and the chips in Settings > PLAYBACK & PICTURE set it.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:guide-timeout:browser`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

const film = (n, title, container, container2 = container) => ({
  ratingKey: String(n), title, summary: "", year: 1990 + n, duration: 5400000, type: "movie", addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Drama" }],
  Media: [{ container, videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${n}/file.${container2}` }] }],
});
const library = [film(1, "Pick Test", "mkv"), film(2, "Sidecar Test", "mp4"), film(3, "Two Tracks Test", "mp4")];
for (let i = 4; i < 12; i++) library.push(film(i, `Filler ${i}`, "mp4"));
const aud = (id, lang, title, selected, channels = 2) => ({ id, streamType: 2, languageCode: lang, codec: "aac", channels, selected, title, displayTitle: `${lang} (AAC Stereo)` });
const streams = {
  1: [{ id: 25, streamType: 1, codec: "h264" }, aud(26, "eng", "Director's Commentary", true), aud(27, "eng", "English", false), aud(28, "fra", "Francais", false),
      { id: 29, streamType: 3, languageCode: "eng", codec: "srt", displayTitle: "English" }],
  2: [{ id: 30, streamType: 1, codec: "h264" }, aud(31, "eng", "", true), { id: 32, streamType: 3, languageCode: "eng", codec: "srt", format: "srt", key: "/library/streams/32" }],
  3: [{ id: 33, streamType: 1, codec: "h264" }, aud(34, "eng", "English", true), aud(35, "fra", "Francais", false)],
};
const SRT = "1\n00:00:00,500 --> 00:00:03,000\nHello from the subtitle file\n";

const log = [];
const open = new Set();
const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const u = new URL(req.url, "http://x");
  log.push(u.pathname + u.search);
  if (u.pathname === "/identity") { res.setHeader("Content-Type", "application/json"); return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "stub-plex", version: "1.43.4" } })); }
  if (u.pathname.startsWith("/library/streams/")) { res.setHeader("Content-Type", "text/plain"); return res.end(SRT); }
  res.setHeader("Content-Type", "application/json");
  if (u.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }] } }));
  if (u.pathname === "/library/sections/1/all") return res.end(JSON.stringify({ MediaContainer: { size: library.length, totalSize: library.length, Metadata: library } }));
  const m = /^\/library\/metadata\/(\d+)$/.exec(u.pathname);
  if (m) return res.end(JSON.stringify({ MediaContainer: { Metadata: [{ ratingKey: m[1], Media: [{ Part: [{ Stream: streams[m[1]] || [] }] }] }] } }));
  if (u.pathname.includes("/transcode/universal/start") || u.pathname.startsWith("/library/parts/")) {
    // The picture never comes (nothing to recover from). A browser holds six connections to one host, so only the newest
    // few are kept open; the older ones belong to programs the page has moved on from.
    open.add(res); res.on("close", () => open.delete(res));
    while (open.size > 3) { const oldest = open.values().next().value; open.delete(oldest); oldest.destroy(); }
    return;
  }
  if (u.pathname.includes("/transcode/")) { res.end("{}"); return; }
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});
await new Promise((r) => plex.listen(0, "127.0.0.1", r));
const plexPort = plex.address().port;

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
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0; const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });
async function openPage(stored) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: "en-US" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.route(/plex\.tv\/api\/v2\/resources/, (route) => route.fulfill({
    status: 200, contentType: "application/json", headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*" },
    body: JSON.stringify([{ name: "Stub", provides: "server", owned: true, accessToken: "t", clientIdentifier: "stub-plex", presence: true,
      connections: [{ protocol: "http", address: "127.0.0.1", port: plexPort, uri: `http://127.0.0.1:${plexPort}`, local: true, relay: false }] }]),
  }));
  await ctx.addInitScript((value) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      sessionStorage.setItem("plex90_token", "t");
      sessionStorage.setItem("plex90_pick_server", "1");
      if (value !== null) localStorage.setItem("nostalgex_guide_timeout", value);
    }
  }, stored === undefined ? null : stored);
  const page = await ctx.newPage();
  await page.clock.install();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.goto(`${base}/plex-tuner.html`);
  await page.locator(".library-continue").click({ timeout: 30000 }).catch(() => {});
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length >= 3 && typeof currentChannel !== "undefined" && currentChannel, null, { timeout: 30000 });
  await page.waitForTimeout(1500);
  return { ctx, page, errors };
}
const idle = (page) => page.evaluate(() => document.body.classList.contains("nx-idle"));
const guideUp = (page) => page.evaluate(() => guideVisible);

try {
  // 1. The default is 5 MIN.
  let { ctx, page, errors } = await openPage();
  check("a new browser has 5 MIN", await page.evaluate(() => guideTimeout) === "5m");
  check("the guide is up with a channel playing", await guideUp(page));
  await page.clock.fastForward("04:00");
  check("4 minutes alone: not yet", !(await idle(page)));
  await page.clock.fastForward("01:30");
  check("5 minutes alone: the picture alone", await idle(page));
  check("the picture fills the window", await page.evaluate(() => { const r = document.getElementById("video-container").getBoundingClientRect(); return r.width >= innerWidth - 1 && r.height >= innerHeight - 1; }));
  await page.keyboard.press("ArrowDown");
  check("a key brings everything back", !(await idle(page)));
  await page.clock.fastForward("04:00");
  check("and restarts the clock: 4 minutes later, still not", !(await idle(page)));
  await page.clock.fastForward("01:30");
  check("5 minutes after that key: idle again", await idle(page));
  await page.mouse.move(200, 200); await page.mouse.move(260, 240);
  check("a pointer move brings it back", !(await idle(page)));

  // 2. Settings open: left alone.
  await page.evaluate(() => showConfig());
  await page.clock.fastForward("20:00");
  check("Settings open: never idle", !(await idle(page)));

  // 3. The chips set it, and it is kept.
  await page.evaluate(() => switchConfigTab("general"));
  await page.locator('#cfg-guide-timeout-chips [data-timeout="15m"]').click();
  check("15 MIN is saved under the Apple TV's key", await page.evaluate(() => localStorage.getItem("nostalgex_guide_timeout")) === "15m");
  check("and its chip reads pressed", await page.locator('#cfg-guide-timeout-chips [data-timeout="15m"]').getAttribute("aria-pressed") === "true");
  await page.evaluate(() => hideConfig());
  await page.clock.fastForward("14:00");
  check("15 MIN: 14 minutes, not yet", !(await idle(page)));
  await page.clock.fastForward("02:00");
  check("15 MIN: 16 minutes, idle", await idle(page));
  check("no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();

  // 4. OFF never does it.
  ({ ctx, page, errors } = await openPage("off"));
  await page.clock.fastForward("01:00:00");
  check("OFF: an hour alone, never idle", !(await idle(page)));
  await ctx.close();
} catch (err) {
  failures.push(`flow stopped: ${String(err.message || err).split("\n")[0]}`);
}
await browser.close();
plex.closeAllConnections?.(); files.closeAllConnections?.(); plex.close(); files.close();
if (failures.length) { console.error(`guide timeout (browser): ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`guide timeout (browser): ${passed} checks passed`);
