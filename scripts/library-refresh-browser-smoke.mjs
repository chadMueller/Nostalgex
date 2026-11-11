#!/usr/bin/env node
/**
 * Reading the library again while the page stays open, in the real plex-tuner.html (headless) with Playwright's clock (#259).
 *
 * The Apple TV checks every 15 minutes and reads the library again once 6 hours have passed, in the background with the guide
 * staying up; on Plex it first asks for a fingerprint of the sections and skips the read while nothing changed, up to a 24 hour
 * cap. This runs a Plex-shaped stub through that: a film added on the server shows up after about 6 hours with no reload, no
 * loading screen and no retune; an unchanged library is not read again at the next check; the 24 hour cap reads it anyway.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:library-refresh:browser`.
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
let contentChangedAt = 100;
let allCalls = 0, sectionCalls = 0;
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
  if (u.pathname === "/library/sections") { sectionCalls += 1; return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie", updatedAt: 50, scannedAt: Date.now(), contentChangedAt }] } })); }
  if (u.pathname === "/library/sections/1/all") { allCalls += 1; return res.end(JSON.stringify({ MediaContainer: { size: library.length, totalSize: library.length, Metadata: library } })); }
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
try {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: "en-US" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.route(/plex\.tv\/api\/v2\/resources/, (route) => route.fulfill({
    status: 200, contentType: "application/json", headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*" },
    body: JSON.stringify([{ name: "Stub", provides: "server", owned: true, accessToken: "t", clientIdentifier: "stub-plex", presence: true,
      connections: [{ protocol: "http", address: "127.0.0.1", port: plexPort, uri: `http://127.0.0.1:${plexPort}`, local: true, relay: false }] }]),
  }));
  await ctx.addInitScript(() => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      sessionStorage.setItem("plex90_token", "t");
      sessionStorage.setItem("plex90_pick_server", "1");
    }
  });
  const page = await ctx.newPage();
  await page.clock.install();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.goto(`${base}/plex-tuner.html`);
  await page.locator(".library-continue").click({ timeout: 30000 }).catch(() => {});
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length >= 3 && typeof currentChannel !== "undefined" && currentChannel, null, { timeout: 30000 });
  await page.waitForTimeout(1500);
  // Watch for the loading screen, and note the channel on air.
  await page.evaluate(() => { window.__loaderShown = false; new MutationObserver(() => { if (document.getElementById("loading-library").style.display === "flex") window.__loaderShown = true; }).observe(document.getElementById("loading-library"), { attributes: true, attributeFilter: ["style"] }); window.__channel0 = currentChannel; });
  const titles = () => page.evaluate(() => allItemsCache.map((i) => i.title));
  const n0 = (await titles()).length;
  const all0 = allCalls;

  // 1. A film added on the server; about 6 hours pass.
  library.push(film(99, "Added On The Server", "mp4")); contentChangedAt = 200;
  await page.clock.fastForward("05:30:00");
  await page.waitForTimeout(1500);
  check("5 hours 30 minutes: not read again yet", allCalls === all0 && (await titles()).length === n0, `${allCalls} vs ${all0}`);
  await page.clock.fastForward("00:45:00");
  await page.waitForFunction(() => allItemsCache.some((i) => i.title === "Added On The Server"), null, { timeout: 20000 }).catch(() => {});
  check("after 6 hours the added film is in the library, with no reload", (await titles()).includes("Added On The Server"), String((await titles()).length));
  check("it was one read", allCalls === all0 + 1, `${allCalls} vs ${all0}`);
  check("no loading screen showed and the channel did not change", !(await page.evaluate(() => window.__loaderShown)) && (await page.evaluate(() => currentChannel === window.__channel0)));
  await page.waitForFunction(() => !!localStorage.getItem("nostalgex_library_signature"), null, { timeout: 15000 }).catch(() => {});
  check("the fingerprint is kept", !!(await page.evaluate(() => localStorage.getItem("nostalgex_library_signature"))));

  // 2. Nothing changed: the next check asks for the fingerprint and does not read.
  const all1 = allCalls, sections1 = sectionCalls;
  await page.clock.fastForward("06:30:00");
  await page.waitForTimeout(1500);
  check("6 hours on, nothing changed: the fingerprint is asked, the library is not read", sectionCalls > sections1 && allCalls === all1, `${sectionCalls} vs ${sections1}, ${allCalls} vs ${all1}`);

  // 3. A change shows at the next check.
  library.push(film(100, "Added Later", "mp4")); contentChangedAt = 300;
  await page.clock.fastForward("06:30:00");
  await page.waitForFunction(() => allItemsCache.some((i) => i.title === "Added Later"), null, { timeout: 20000 }).catch(() => {});
  check("a change at the next check is read", (await titles()).includes("Added Later"), String(allCalls));

  // 4. The 24 hour cap reads it even when nothing changed.
  const all3 = allCalls;
  await page.clock.fastForward("06:30:00");
  await page.waitForTimeout(1000);
  check("unchanged and under the cap: not read", allCalls === all3, `${allCalls} vs ${all3}`);
  await page.clock.fastForward("18:30:00");
  await page.waitForTimeout(2500);
  check("past 24 hours with nothing changed: read once", allCalls > all3, `${allCalls} vs ${all3}`);
  check("no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
} catch (err) {
  failures.push(`flow stopped: ${String(err.message || err).split("\n")[0]}`);
}
await browser.close();
plex.closeAllConnections?.(); files.closeAllConnections?.(); plex.close(); files.close();
if (failures.length) { console.error(`library refresh (browser): ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`library refresh (browser): ${passed} checks passed`);
