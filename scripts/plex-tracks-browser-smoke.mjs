#!/usr/bin/env node
/**
 * Plex audio and subtitle choices in the real plex-tuner.html (headless), against a Plex-shaped stub (#249, #250).
 *
 * The web tuner used to ignore the tracks of a Plex file: no AUDIO LANGUAGE, no subtitles, and a director's commentary
 * that Plex marked selected played. Now, when a Plex program is tuned, the page asks the item's metadata for its streams
 * and acts on them the way the Apple TV does:
 *   - a commentary is never the audio pick while another track exists (the English track, not the selected commentary);
 *   - AUDIO LANGUAGE picks a track and asks the server stream for it (audioStreamID);
 *   - subtitles that live inside the file are burned into the server stream (subtitles=burn, subtitleStreamID) when they
 *     are on, and a subtitle file beside the film is fetched from /library/streams/<id> and drawn by the page;
 *   - a file played directly (mp4) with nothing to pick is not sent to a server stream for it.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (origin/main's); the checks must fail there.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:plex-tracks:browser`.
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
const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, timezoneId: "America/New_York", locale: "en-US" });
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
const errors = [];
page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
try {
  await page.goto(`${base}/plex-tuner.html`);
  await page.locator(".library-continue").click({ timeout: 30000 }).catch(() => {});
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length >= 3, null, { timeout: 30000 });
  await page.waitForTimeout(1500);
  await page.evaluate(() => { isVideoFullscreen = () => true; });   // subtitles are fullscreen-only

  const play = async (title) => {
    log.length = 0;
    await page.evaluate((t) => { const item = allItemsCache.find((i) => i.title === t); playCurrentItem({ ...item, offsetSeconds: 0 }, CHANNELS.find((c) => c.id === currentChannel)); }, title);
    await page.waitForTimeout(900);
    return [...log];
  };
  const starts = (l) => l.filter((x) => x.includes("/transcode/universal/start.m3u8"));

  // 1. A selected commentary is passed over: the English track (27), asked of the server stream. mkv: it is a server stream anyway.
  let l = await play("Pick Test");
  check("the item's metadata is read", l.some((x) => x.startsWith("/library/metadata/1")), l.join(" | "));
  check("the commentary Plex marks selected is passed over: audioStreamID is the English track (27)", starts(l).some((x) => x.includes("audioStreamID=27")), starts(l).join(" | "));
  check("subtitles off: no subtitle parameter", starts(l).every((x) => !x.includes("subtitles=")), starts(l).join(" | "));

  // 2. AUDIO LANGUAGE French asks for the French track.
  await page.evaluate(() => setAudioLanguage("fr"));
  await page.waitForTimeout(900);
  l = await play("Pick Test");
  check("AUDIO LANGUAGE French asks for the French track (28)", starts(l).some((x) => x.includes("audioStreamID=28")), starts(l).join(" | "));
  await page.evaluate(() => setAudioLanguage("__system__"));

  // 3. Subtitles on, inside the file: burned into the server stream.
  await page.evaluate(() => { subtitlesEnabled = true; });
  l = await play("Pick Test");
  check("subtitles inside the file are burned in (subtitles=burn, subtitleStreamID=29)", starts(l).some((x) => x.includes("subtitles=burn") && x.includes("subtitleStreamID=29")), starts(l).join(" | "));
  await page.evaluate(() => { subtitlesEnabled = false; });

  // 4. A subtitle file beside the film: fetched and drawn by the page; the file still plays directly.
  await page.evaluate(() => { subtitlesEnabled = true; });
  l = await play("Sidecar Test");
  check("a subtitle file beside the film is fetched from /library/streams/32", l.some((x) => x.startsWith("/library/streams/32")), l.join(" | "));
  check("and the film plays directly, not through a server stream", starts(l).length === 0 && l.some((x) => x.startsWith("/library/parts/2/")), l.join(" | "));
  const tracks = await page.evaluate(() => [...document.querySelectorAll("#plex-video track")].map((t) => t.srclang));
  check("one subtitle track is on the video, in English", tracks.length === 1 && tracks[0] === "eng", JSON.stringify(tracks));
  await page.evaluate(() => { subtitlesEnabled = false; });

  // 5. Two tracks, Plex's own selection is the viewer's language: nothing to change, so it plays directly.
  l = await play("Two Tracks Test");
  check("two tracks and the selected one is English: plays directly", starts(l).length === 0 && l.some((x) => x.startsWith("/library/parts/3/")), l.join(" | "));
  await page.evaluate(() => setAudioLanguage("fr"));
  await page.waitForTimeout(900);
  l = await play("Two Tracks Test");
  check("AUDIO LANGUAGE French on that film goes to a server stream for the French track (35)", starts(l).some((x) => x.includes("audioStreamID=35")), l.join(" | "));
  check("no page errors", errors.length === 0, errors.join(" | "));
} catch (err) {
  failures.push(`flow stopped: ${String(err.message || err).split("\n")[0]}`);
}
await browser.close();
plex.closeAllConnections?.(); files.closeAllConnections?.(); plex.close(); files.close();
if (failures.length) { console.error(`plex tracks (browser): ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`plex tracks (browser): ${passed} checks passed`);
