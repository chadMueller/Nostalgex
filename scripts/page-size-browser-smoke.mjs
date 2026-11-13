#!/usr/bin/env node
/**
 * PAGE SIZE in the real plex-tuner.html (headless) (#255): a PC on a TV at 1920x1080 draws the page 1:1, so LARGE lays it out like a
 * 1440 px window and scales it up by a third (html.nx-large). OFF is the default; AUTO does that at 1800x1000 and up with a mouse,
 * never on touch; LARGE does it from 1440 px wide. The guide keeps its 64 pt rows, and nothing leaves the screen.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:page-size:browser`.
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
async function openAt(width, height, { touch = false, stored = null } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, hasTouch: touch, isMobile: touch, locale: "en-US" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.route(/plex\.tv\/api\/v2\/resources/, (route) => route.fulfill({
    status: 200, contentType: "application/json", headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*" },
    body: JSON.stringify([{ name: "Stub", provides: "server", owned: true, accessToken: "t", clientIdentifier: "stub-plex", presence: true,
      connections: [{ protocol: "http", address: "127.0.0.1", port: plexPort, uri: `http://127.0.0.1:${plexPort}`, local: true, relay: false }] }]),
  }));
  await ctx.addInitScript((value) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1"); sessionStorage.setItem("plex90_token", "t"); sessionStorage.setItem("plex90_pick_server", "1");
      if (value) localStorage.setItem("nostalgex_page_size", value);
    }
  }, stored);
  const page = await ctx.newPage();
  const errors = []; page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.goto(`${base}/plex-tuner.html`);
  await page.locator(".library-continue").click({ timeout: 30000 }).catch(() => {});
  await page.waitForFunction(() => typeof currentChannel !== "undefined" && currentChannel, null, { timeout: 30000 });
  await page.waitForTimeout(1200);
  return { ctx, page, errors };
}
const large = (page) => page.evaluate(() => document.documentElement.classList.contains("nx-large"));
try {
  let { ctx, page, errors } = await openAt(1920, 1080);
  check("a new browser has it OFF, even at 1920x1080 with a mouse", !(await large(page)));
  await ctx.close();
  ({ ctx, page, errors } = await openAt(1920, 1080, { stored: "auto" }));
  check("1920x1080 with a mouse: AUTO is on", await large(page));
  const m = await page.evaluate(() => { const row = document.querySelector(".grid-row[data-channel-id]"); const body = document.getElementById("grid-body"); const z = parseFloat(getComputedStyle(document.documentElement).zoom); const panel = document.getElementById("info-panel"); return { z, rows: body.getBoundingClientRect().height / row.getBoundingClientRect().height, docW: document.documentElement.scrollWidth, vw: innerWidth, panelScroll: panel.scrollHeight, panelClient: panel.clientHeight }; });
  check("the page is scaled by a third", Math.abs(m.z - 1.3333) < 0.01, String(m.z));
  // A row is 64 pt times --guide-scale (0.74): 47 px on screen at 1080 with the page zoom divided out, so under the third the guide shows the
  // same 10 to 11 rows as without it (the guide's own proportion, not a third bigger).
  check("the guide keeps its rows (64 pt x the guide scale, 47 px on screen at 1080: 9.5 to 11.5 rows here)", m.rows >= 9.5 && m.rows <= 11.5, String(m.rows));
  check("the info window holds everything under the third (scrollHeight <= clientHeight)", m.panelScroll <= m.panelClient + 1, `${m.panelScroll} vs ${m.panelClient}`);
  check("nothing leaves the screen", m.docW <= m.vw + 1, `${m.docW} vs ${m.vw}`);
  await page.evaluate(() => showConfig());
  await page.waitForTimeout(400);
  await page.evaluate(() => switchConfigTab("general"));
  await page.locator('#cfg-page-size-chips [data-size="off"]').click();
  check("OFF takes it away at once", !(await large(page)));
  check("and is saved", await page.evaluate(() => localStorage.getItem("nostalgex_page_size")) === "off");
  await page.locator('#cfg-page-size-chips [data-size="large"]').click();
  check("LARGE puts it back", await large(page));
  check("no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();

  ({ ctx, page } = await openAt(1280, 800, { stored: "auto" }));
  check("1280x800: AUTO leaves it off", !(await large(page)));
  await ctx.close();
  ({ ctx, page } = await openAt(1280, 800, { stored: "large" }));
  check("1280x800 is under 1440: LARGE leaves it off too", !(await large(page)));
  await ctx.close();
  ({ ctx, page } = await openAt(1600, 900, { stored: "large" }));
  check("1600x900: LARGE turns it on", await large(page));
  await ctx.close();
  ({ ctx, page } = await openAt(1920, 1080, { touch: true, stored: "auto" }));
  check("a touch screen never gets it", !(await large(page)));
  await ctx.close();
  ({ ctx, page } = await openAt(1920, 1080, { stored: "off" }));
  check("1920x1080 with OFF saved: off", !(await large(page)));
  await ctx.close();
} catch (err) {
  failures.push(`flow stopped: ${String(err.message || err).split("\n")[0]}`);
}
await browser.close();
plex.closeAllConnections?.(); files.closeAllConnections?.(); plex.close(); files.close();
if (failures.length) { console.error(`page size (browser): ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`page size (browser): ${passed} checks passed`);
