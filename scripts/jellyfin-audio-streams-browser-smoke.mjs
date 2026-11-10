#!/usr/bin/env node
/**
 * Jellyfin and Emby items keep their audio tracks (issue #176, reported by @owenvoke).
 *
 * The scan's `mediaInfo` read every audio stream of a file into `audioStreams`, but the movie and
 * episode items it built took only `subtitles`, so on the web tuner and in Docker
 * `pickAudioStream(item.audioStreams || [])` always saw an empty list: AUDIO LANGUAGE was ignored
 * and the foreign-audio subtitle fallback (`shouldAutoEnableSubs`) never switched on.
 *
 * This loads the real plex-tuner.html, headless, against a Jellyfin-shaped and an Emby-shaped
 * server (the same API, with Emby's own library list) that record every request, and checks, on
 * each backend:
 *   - a scanned movie and a scanned episode carry their audio tracks (index and language);
 *   - AUDIO LANGUAGE Auto asks for the Apple TV's track (the English one, not the file's French default); English, picked in
 *     Settings by click, asks the server for the English track (`AudioStreamIndex` in the
 *     PlaybackInfo body), then German, then French on an episode;
 *   - a film whose audio is all in other languages turns the subtitles on by itself (the request
 *     for its English track goes out), and a film with an English track does not.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (origin/main's) in place
 * of plex-tuner.html; it must fail.
 *
 * CACHE_MEASURE=<n> instead measures what the audio tracks add to the saved library: a synthetic
 * library of n films (three audio tracks and two subtitle tracks each, a 350 character summary),
 * loaded, then the items as the page holds them and the browser's storage in use, printed. Run it
 * against both pages and compare.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:jellyfin-audio:browser`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const repo = fileURLToPath(new URL("../", import.meta.url));
const root = process.env.TUNER_ROOT ? process.env.TUNER_ROOT.replace(/\/?$/, "/") : repo;
const measure = Number(process.env.CACHE_MEASURE || 0);

const TICKS = (min) => min * 60 * 10000000;
const SUMMARY = "A long-running family drama about a small town, its rivalries and the summer that changed everything for the people who lived there. ".repeat(3).slice(0, 350);

/** Audio fr (default), en, de and an English text subtitle, as a multi-language MKV carries them. */
const MULTI = [
  { Type: "Video", Codec: "h264", Width: 1920, Height: 1080, Index: 0, IsDefault: true },
  { Type: "Audio", Codec: "ac3", Language: "fre", Channels: 6, Index: 1, IsDefault: true, DisplayTitle: "French AC3 5.1" },
  { Type: "Audio", Codec: "ac3", Language: "eng", Channels: 6, Index: 2, DisplayTitle: "English AC3 5.1" },
  { Type: "Audio", Codec: "aac", Language: "ger", Channels: 2, Index: 3, DisplayTitle: "German AAC" },
  { Type: "Subtitle", Codec: "srt", Language: "eng", Index: 4, IsForced: false, IsExternal: false },
  { Type: "Subtitle", Codec: "srt", Language: "fre", Index: 5, IsForced: false, IsExternal: false },
];
/** Audio only in French and German, with English subtitles: the foreign-audio fallback's case. */
const FOREIGN = [
  { Type: "Video", Codec: "h264", Width: 1920, Height: 1080, Index: 0, IsDefault: true },
  { Type: "Audio", Codec: "ac3", Language: "fre", Channels: 6, Index: 1, IsDefault: true, DisplayTitle: "French AC3 5.1" },
  { Type: "Audio", Codec: "aac", Language: "ger", Channels: 2, Index: 2, DisplayTitle: "German AAC" },
  { Type: "Subtitle", Codec: "srt", Language: "eng", Index: 3, IsForced: false, IsExternal: false },
];

/** Two English stereo tracks, the first a director's commentary the file marks default (#153, #250). */
const COMMENTARY = [
  { Type: "Video", Codec: "h264", Width: 1920, Height: 1080, Index: 0, IsDefault: true },
  { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true, Title: "Director's Commentary", DisplayTitle: "English - Commentary - AAC - Stereo" },
  { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 2, DisplayTitle: "English - AAC - Stereo" },
];

function film(id, name, streams, extra = {}) {
  return {
    Id: id, Name: name, Type: "Movie", ProductionYear: 1990 + (Number(id.replace(/\D/g, "")) % 9), Genres: ["Drama"], OfficialRating: "PG",
    RunTimeTicks: TICKS(100), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", CommunityRating: 7, Overview: extra.overview || "",
    MediaSources: [{ Id: `ms-${id}`, Container: "mkv", Bitrate: 8000000, RunTimeTicks: TICKS(100), Size: 3000000, SupportsDirectPlay: false, MediaStreams: streams }],
  };
}
const movies = [];
for (let i = 0; i < 24; i++) movies.push(film(`mm${i}`, `Multi Film ${i}`, MULTI));
for (let i = 0; i < 6; i++) movies.push(film(`mf${i}`, `Foreign Film ${i}`, FOREIGN));
for (let i = 0; i < 2; i++) movies.push(film(`mc${i}`, `Commentary Film ${i}`, COMMENTARY));
const episodes = [];
for (let i = 0; i < 6; i++) {
  episodes.push({
    Id: `ep${i}`, Name: `Pilot ${i}`, Type: "Episode", ParentIndexNumber: 1, IndexNumber: i + 1, RunTimeTicks: TICKS(45),
    DateCreated: "2020-01-01T00:00:00.0000000Z",
    MediaSources: [{ Id: `ms-ep${i}`, Container: "mkv", Bitrate: 5000000, RunTimeTicks: TICKS(45), Size: 1000000, SupportsDirectPlay: false, MediaStreams: MULTI }],
  });
}
const series = [{ Id: "show1", Name: "Multi Show", Type: "Series", ProductionYear: 1995, Genres: ["Drama"], Studios: [], ProviderIds: {}, OfficialRating: "TV-PG" }];

// The synthetic library for CACHE_MEASURE: n films like MULTI, with a real-sized summary.
const bigMovies = measure ? Array.from({ length: measure }, (_, i) => film(`bg${i}`, `Big Film ${i}`, MULTI, { overview: SUMMARY })) : [];

const log = [];
const open = new Set();
let serverKind = "jellyfin";   // what /System/Info/Public says this server is
const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = req.url;
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    log.push({ method: req.method, url, body });
    // Subtitles come back; the picture never does (a video left loading has nothing to recover from).
    if (url.includes("/Subtitles/")) { res.writeHead(200, { "Content-Type": "text/vtt" }); return res.end("WEBVTT\n\n"); }
    if (url.startsWith("/Videos/")) {
      open.add(res);
      res.on("close", () => open.delete(res));
      // A browser holds six connections to one host; pictures left loading would fill them and
      // queue the next request. Only the newest few are kept, the older ones belong to programmes
      // the page has already moved on from.
      while (open.size > 3) { const oldest = open.values().next().value; open.delete(oldest); oldest.destroy(); }
      return;
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    const q = new URL(url, "http://x").searchParams;
    const page = (list) => {
      const start = Number(q.get("StartIndex") || 0);
      const limit = Number(q.get("Limit") || 200);
      return JSON.stringify({ Items: list.slice(start, start + limit), TotalRecordCount: list.length });
    };
    // Jellyfin names itself in ProductName; Emby leaves it out and lists LocalAddresses.
    if (url.startsWith("/System/Info/Public")) {
      return res.end(JSON.stringify(serverKind === "emby"
        ? { ServerName: "lab", Version: "4.10.1.0", Id: "lab", LocalAddresses: [api] }
        : { ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
    }
    // Jellyfin lists libraries at /UserViews, Emby at /Users/<id>/Views.
    if (url.startsWith("/UserViews") || /^\/Users\/[^/]+\/Views/.test(url)) {
      const views = measure ? [{ Id: "lib-movies", Name: "Movies", CollectionType: "movies" }]
        : [{ Id: "lib-movies", Name: "Movies", CollectionType: "movies" }, { Id: "lib-tv", Name: "Shows", CollectionType: "tvshows" }];
      return res.end(JSON.stringify({ Items: views, TotalRecordCount: views.length }));
    }
    if (url.includes("/PlaybackInfo")) {
      const id = (/\/Items\/([^/]+)\/PlaybackInfo/.exec(url) || [])[1] || "x";
      return res.end(JSON.stringify({ PlaySessionId: "s1", MediaSources: [{ Id: `ms-${id}`, TranscodingUrl: `/Videos/${id}/master.m3u8?PlaySessionId=s1` }] }));
    }
    if (url.startsWith("/Items") || /^\/Users\/[^/]+\/Items/.test(url)) {
      const types = q.get("IncludeItemTypes") || "";
      const parent = q.get("ParentId");
      if (types === "Movie" && parent === "lib-movies") return res.end(page(measure ? bigMovies : movies));
      if (types === "Series" && parent === "lib-tv") return res.end(page(series));
      if (types === "Episode" && parent === "show1") return res.end(page(episodes));
      return res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
    }
    res.end("{}");
  });
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let bodyBytes = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    if (process.env.NX_TUNER_HTML) bodyBytes = readFileSync(process.env.NX_TUNER_HTML);
    bodyBytes = Buffer.from(bodyBytes.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>"));
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(bodyBytes);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${server.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });

async function launch(backend) {
  serverKind = backend;
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: "en-US" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url, kind]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: kind, jellyfinUserId: "u" }));
    }
  }, [api, backend]);
  const page = await ctx.newPage();
  page.setDefaultTimeout(15000);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  const started = Date.now();
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: measure ? 240000 : 30000 }).catch(() => {});
  // The page tunes its first channel when the load ends; let that settle before a test plays anything.
  await page.waitForTimeout(measure ? 2500 : 2000);
  return { ctx, page, errors, loadMs: Date.now() - started };
}

if (measure) {
  // What the audio tracks add to the saved library. Loaded once; the numbers are the page's own.
  const { ctx, page, loadMs } = await launch("jellyfin");
  const out = await page.evaluate(async () => {
    const items = allItemsCache;
    const json = JSON.stringify(items);
    const withAudio = items.filter((i) => Array.isArray(i.audioStreams) && i.audioStreams.length > 0).length;
    const est = navigator.storage && navigator.storage.estimate ? await navigator.storage.estimate() : {};
    const cached = await NostalgexStorage.libraryCache.load().catch(() => null);
    return { count: items.length, withAudio, jsonBytes: json.length, usage: est.usage || null, cachedItems: cached && cached.items ? cached.items.length : null, cachedJson: cached ? JSON.stringify(cached).length : null };
  });
  console.log(JSON.stringify({ page: process.env.NX_TUNER_HTML ? "other page" : "this page", films: measure, ...out, loadMs, bytesPerItem: Math.round(out.jsonBytes / out.count) }));
  await ctx.close();
  await browser.close();
  for (const res of open) res.destroy();
  server.closeAllConnections?.(); files.closeAllConnections?.(); server.close(); files.close();
  process.exit(0);
}

const lastBody = (idPart) => {
  const hits = log.filter((l) => l.method === "POST" && l.url.includes(`/Items/${idPart}/PlaybackInfo`));
  if (!hits.length) return null;
  try { return JSON.parse(hits[hits.length - 1].body); } catch { return null; }
};
const playItem = async (page, title, episode = false) => {
  await page.evaluate(([t, ep]) => {
    const item = allItemsCache.find((i) => (ep ? i.episodeTitle === t : i.title === t));
    // On the channel the page itself tuned: a request is only the current one on its own channel.
    playCurrentItem({ ...item, offsetSeconds: 0 }, CHANNELS.find((c) => c.id === currentChannel));
  }, [title, episode]);
  await page.waitForTimeout(700);
};

for (const backend of ["jellyfin", "emby"]) try {
  log.length = 0;
  const { ctx, page, errors } = await launch(backend);
  const tag = backend.toUpperCase();
  const mode = await page.evaluate(() => mediaBackend);
  check(`${tag}: the page runs as ${backend}`, mode === backend, mode);

  const info = await page.evaluate(() => {
    const m = allItemsCache.find((i) => i.title === "Multi Film 0");
    const e = allItemsCache.find((i) => i.episodeTitle === "Pilot 0");
    const f = allItemsCache.find((i) => i.title === "Foreign Film 0");
    const brief = (x) => (x && Array.isArray(x.audioStreams) ? x.audioStreams.map((s) => `${s.index}:${s.lang}`).join(",") : null);
    return { movie: brief(m), episode: brief(e), foreign: brief(f),
      autoMulti: m ? shouldAutoEnableSubs(m.audioStreams || []) : null, autoForeign: f ? shouldAutoEnableSubs(f.audioStreams || []) : null };
  });
  check(`${tag}: a scanned movie carries its audio tracks`, info.movie === "1:fre,2:eng,3:ger", String(info.movie));
  check(`${tag}: a scanned episode carries its audio tracks`, info.episode === "1:fre,2:eng,3:ger", String(info.episode));
  check(`${tag}: foreign-audio fallback is off for a film with an English track`, info.autoMulti === false, String(info.autoMulti));
  check(`${tag}: foreign-audio fallback is on for a film with no English track`, info.autoForeign === true, String(info.autoForeign));

  // Auto is the Apple TV's rule: the English track (the browser's language), not the file's French default.
  await playItem(page, "Multi Film 0");
  let body = lastBody("mm0");
  check(`${tag}: AUDIO LANGUAGE Auto asks for the English track (AudioStreamIndex 2), not the file's French default`, !!body && body.AudioStreamIndex === 2, JSON.stringify(body && body.AudioStreamIndex));
  // A commentary the file marks default is never the pick while another track exists (#250).
  await playItem(page, "Commentary Film 0");
  body = lastBody("mc0");
  check(`${tag}: a default-flagged commentary is passed over (AudioStreamIndex 2)`, !!body && body.AudioStreamIndex === 2, JSON.stringify(body && body.AudioStreamIndex));
  // English, chosen in Settings by click: the English track, index 2 (the file's default is French).
  await page.locator(".v-btn:has(.v-btn-label:text-is('SETTINGS'))").first().click();
  await page.waitForTimeout(300);
  if (await page.locator("#rail-general").isVisible().catch(() => false)) await page.locator("#rail-general").click(); else await page.locator("#tab-general").click();
  await page.waitForTimeout(300);
  await page.locator("#cfg-audio-lang").selectOption("en");
  await page.waitForTimeout(300);
  await page.locator(".config-close").click();
  await page.waitForTimeout(400);
  await playItem(page, "Multi Film 0");
  body = lastBody("mm0");
  check(`${tag}: AUDIO LANGUAGE English asks for the English track (AudioStreamIndex 2), not the file's French default`, body && body.AudioStreamIndex === 2, JSON.stringify(body && body.AudioStreamIndex));
  // Then German.
  await page.evaluate(() => setAudioLanguage("de"));
  await playItem(page, "Multi Film 0");
  body = lastBody("mm0");
  check(`${tag}: AUDIO LANGUAGE German asks for the German track (AudioStreamIndex 3)`, body && body.AudioStreamIndex === 3, JSON.stringify(body && body.AudioStreamIndex));

  // French on an episode (the other place the item was built).
  await page.evaluate(() => setAudioLanguage("fr"));
  await playItem(page, "Pilot 0", true);
  body = lastBody("ep0");
  check(`${tag}: AUDIO LANGUAGE French on an episode asks for the French track (AudioStreamIndex 1)`, body && body.AudioStreamIndex === 1, JSON.stringify(body && body.AudioStreamIndex));

  // Back to Auto (English): a film with only French and German audio switches the subtitles on.
  await page.evaluate(() => setAudioLanguage("__system__"));
  log.length = 0;
  await page.evaluate(() => { isVideoFullscreen = () => true; });   // the subtitles are fullscreen-only
  await playItem(page, "Foreign Film 0");
  await page.waitForTimeout(500);
  const subRequest = log.find((l) => /\/Videos\/mf0\/ms-mf0\/Subtitles\/3\/Stream\.vtt/.test(l.url));
  check(`${tag}: a film with no English audio asks for its English subtitles by itself`, !!subRequest, log.map((l) => l.method + " " + l.url.split("?")[0]).join(" | ") + " | page errors: " + errors.join(" ; "));
  log.length = 0;
  await playItem(page, "Multi Film 1");
  await page.waitForTimeout(500);
  check(`${tag}: a film with an English track asks for no subtitles`, !log.some((l) => l.url.includes("/Subtitles/")), log.map((l) => l.url.split("?")[0]).join(" | "));
  check(`${tag}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
} catch (err) {
  failures.push(`${backend} flow stopped: ${String(err.message || err).split("\n")[0]}`);
}

await browser.close();
for (const res of open) res.destroy();
server.closeAllConnections?.();
files.closeAllConnections?.();
server.close();
files.close();

if (failures.length) {
  console.error(`jellyfin audio streams: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`jellyfin audio streams: ${passed} checks passed`);
process.exit(0);
