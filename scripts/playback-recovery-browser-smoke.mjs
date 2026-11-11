#!/usr/bin/env node
/**
 * Playback recovery in the real plex-tuner.html (headless), against a Plex-shaped stub that fails on demand (#258).
 *
 * The Apple TV's ladder: direct play, then the server stream, then ONE retry capped at 1080p, then the failure card and the next program;
 * five failures in a row stop the channel (the web stopped after three); a stream that was playing and is starved (three stalls in two
 * minutes, or one freeze of 20 s) is asked again capped at 1080p from where it is, once, then skipped. This drives each rung and reads the
 * requests the stub sees.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:playback-recovery:browser`.
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
const library = Array.from({ length: 12 }, (_, i) => film(i + 1, `Recovery ${i + 1}`, "mkv"));
library.push(film(20, "Direct Recovery", "mp4"));
let mode = "fail";   // fail: every transcode start answers 500; hang: it never answers
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
  if (u.pathname.includes("/transcode/universal/start")) {
    if (mode === "fail") { res.writeHead(500, { "Content-Type": "text/plain" }); return res.end("no"); }
    open.add(res); res.on("close", () => open.delete(res));
    while (open.size > 3) { const oldest = open.values().next().value; open.delete(oldest); oldest.destroy(); }
    return;
  }
  if (u.pathname.startsWith("/library/parts/")) { if (mode === "fail") { res.writeHead(404); return res.end(); } return; }
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
async function openPage() {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: "en-US" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.route(/plex\.tv\/api\/v2\/resources/, (route) => route.fulfill({
    status: 200, contentType: "application/json", headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*" },
    body: JSON.stringify([{ name: "Stub", provides: "server", owned: true, accessToken: "t", clientIdentifier: "stub-plex", presence: true,
      connections: [{ protocol: "http", address: "127.0.0.1", port: plexPort, uri: `http://127.0.0.1:${plexPort}`, local: true, relay: false }] }]),
  }));
  await ctx.addInitScript(() => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1"); sessionStorage.setItem("plex90_token", "t"); sessionStorage.setItem("plex90_pick_server", "1");
    }
  });
  const page = await ctx.newPage();
  await page.clock.install();
  const errors = []; page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  if (process.env.DEBUG_CONSOLE) page.on("console", (m) => { if (/PLEX 90|starv/i.test(m.text())) console.log("  [page]", m.text().slice(0, 200)); });
  mode = "hang";   // so the first tune does not start the failure run before the test does
  await page.goto(`${base}/plex-tuner.html`);
  await page.locator(".library-continue").click({ timeout: 30000 }).catch(() => {});
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length >= 3 && typeof currentChannel !== "undefined" && currentChannel, null, { timeout: 30000 });
  await page.waitForTimeout(1500);
  return { ctx, page, errors };
}
const starts = () => log.filter((x) => x.includes("/transcode/universal/start.m3u8"));
const play = async (page, i = 0) => {
  log.length = 0;
  await page.evaluate((n) => { const item = allItemsCache.filter((x) => /^Recovery/.test(x.title))[n]; playCurrentItem({ ...item, offsetSeconds: 0 }, CHANNELS.find((c) => c.id === currentChannel)); }, i);
};

try {
  // 1. A server stream that fails goes to one retry capped at 1080p, then the failure card.
  let { ctx, page, errors } = await openPage();
  mode = "fail";
  await play(page);
  await page.waitForTimeout(1500);
  let s = starts();
  check("the server stream is asked for first, with no cap", s.length >= 1 && !s[0].includes("videoResolution="), s[0]);
  check("it failed, so the page asks once more, capped at 1080p", s.length === 2 && s[1].includes("videoResolution=1920x1080") && s[1].includes("maxVideoBitrate=12000") && s[1].includes("autoAdjustQuality=0"), s.join(" | "));
  await page.waitForTimeout(800);
  check("and no third time", starts().length === 2, String(starts().length));
  check("the failure card is up", await page.evaluate(() => !!document.querySelector(".channel-display.has-failure, #channel-display.has-failure") || consecutivePlaybackFailures >= 1));

  // 1b. A file played directly that fails goes to the server stream first, then the capped retry: parts, start, start (capped).
  log.length = 0;
  await page.evaluate(() => { const item = allItemsCache.find((x) => x.title === "Direct Recovery"); playCurrentItem({ ...item, offsetSeconds: 0 }, CHANNELS.find((c) => c.id === currentChannel)); });
  await page.waitForTimeout(2000);
  const order = log.filter((x) => x.startsWith("/library/parts/") || x.includes("start.m3u8")).map((x) => x.startsWith("/library/parts/") ? "direct" : (x.includes("videoResolution=1920x1080") ? "capped" : "server"));
  check("direct play, then the server stream, then the capped retry, in that order", JSON.stringify(order.slice(0, 3)) === JSON.stringify(["direct", "server", "capped"]), JSON.stringify(order));

  // 2. When the viewer already caps quality at 1080p or lower there is no capped retry.
  await page.evaluate(() => { localStorage.setItem("nostalgex_stream_quality", "medium"); });
  await play(page, 1);
  await page.waitForTimeout(1500);
  s = starts();
  check("STREAM QUALITY MEDIUM: one request, no second capped one", s.length === 1 && s[0].includes("videoResolution=1280x720"), s.join(" | "));
  await page.evaluate(() => { localStorage.removeItem("nostalgex_stream_quality"); });

  // 3. Five in a row stop the channel (the web stopped after three).
  await page.evaluate(() => { consecutivePlaybackFailures = 0; });
  let seen = [];
  for (let i = 0; i < 8; i++) {
    await page.clock.fastForward("00:06");
    await page.waitForTimeout(500);
    seen.push(await page.evaluate(() => consecutivePlaybackFailures));
  }
  check("the failure run counts to five", seen.includes(5) || Math.max(...seen) >= 5, JSON.stringify(seen));
  check("and the limit is five, not three", await page.evaluate(() => MAX_CONSECUTIVE_FAILURES) === 5);
  const before = log.length;
  await page.clock.fastForward("00:30");
  await page.waitForTimeout(800);
  check("once stopped, the channel asks for nothing more", log.length === before, `${log.length} vs ${before}`);
  check("no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();

  // 4. A stream that was playing and freezes for 20 s is asked again capped at 1080p, from where it is, once; then it is skipped.
  ({ ctx, page, errors } = await openPage());
  mode = "hang";
  await play(page, 2);
  await page.waitForTimeout(800);
  await page.evaluate(() => {
    const v = document.getElementById("plex-video");
    window.__head = 0;
    Object.defineProperty(v, "currentTime", { configurable: true, get: () => window.__head, set: () => {} });
    Object.defineProperty(v, "paused", { configurable: true, get: () => false });
  });
  for (let i = 0; i < 4; i++) { await page.evaluate(() => { window.__head += 1; }); await page.clock.runFor("00:01"); }
  log.length = 0;
  await page.clock.runFor("00:25");
  await page.waitForTimeout(800);
  s = starts();
  check("a 20 second freeze after playing: one capped retry from where it froze", s.length >= 1 && s[0].includes("videoResolution=1920x1080") && /offset=[1-9]/.test(s[0]), s.join(" | "));
  const retries = s.length;
  await page.evaluate(() => {
    const v = document.getElementById("plex-video");
    window.__head = 0;
    Object.defineProperty(v, "currentTime", { configurable: true, get: () => window.__head, set: () => {} });
    Object.defineProperty(v, "paused", { configurable: true, get: () => false });
  });
  for (let i = 0; i < 4; i++) { await page.evaluate(() => { window.__head += 1; }); await page.clock.runFor("00:01"); }
  log.length = 0;
  await page.clock.runFor("00:25");
  await page.waitForTimeout(800);
  s = starts();
  check("frozen again on the capped stream: no second capped retry, the next program is asked for", s.length >= 1 && !/offset=[1-9]/.test(s[0] || "") || s.every((x) => !(x.includes("videoResolution=1920x1080") && /offset=[1-9]/.test(x))), s.join(" | "));
  check("no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
} catch (err) {
  failures.push(`flow stopped: ${String(err.message || err).split("\n")[0]}`);
}
await browser.close();
plex.closeAllConnections?.(); files.closeAllConnections?.(); plex.close(); files.close();
if (failures.length) { console.error(`playback recovery (browser): ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`playback recovery (browser): ${passed} checks passed`);
