#!/usr/bin/env node
/**
 * Jellyfin and Emby music video libraries load (I-067, reported by @owenvoke on PR #151).
 *
 * A music video library holds items of type MusicVideo, but the scan asked it for
 * IncludeItemTypes=Movie only. Measured on Jellyfin 12.4.0 with four files: Movie returns 0,
 * MusicVideo returns 4. So the library contributed nothing and HIGH ROTATION (source musicVideo,
 * minItems 3) stayed empty.
 *
 * This loads the real plex-tuner.html, headless, against a Jellyfin-shaped and an Emby-shaped
 * server (the same API, with Emby's own library list) that record every request and answer
 * IncludeItemTypes the way Jellyfin does (only the types asked for, comma separated), with a
 * Movies library, a TV library and a Music Videos library, and checks, on each backend:
 *   - the four music videos are in the scanned library, marked librarySource "musicVideo";
 *   - HIGH ROTATION has them as its pool;
 *   - the Movies library is still asked for "Movie" only and the TV library for Series and
 *     Episode, so a film library does not start pulling in MusicVideo items;
 *   - the music video library is asked for Movie and MusicVideo (a few people file their clips
 *     as Movie, so both stay);
 *   - the films, the episodes and a music video filed as a Movie all still load.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (origin/main's) in place
 * of plex-tuner.html; it must fail.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:jellyfin-music-video:browser`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const repo = fileURLToPath(new URL("../", import.meta.url));
const root = process.env.TUNER_ROOT ? process.env.TUNER_ROOT.replace(/\/?$/, "/") : repo;

const TICKS = (min) => min * 60 * 10000000;
const STREAMS = [
  { Type: "Video", Codec: "h264", Width: 1920, Height: 1080, Index: 0, IsDefault: true },
  { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true, DisplayTitle: "English AAC" },
];
function item(id, type, name, minutes, extra = {}) {
  return {
    Id: id, Name: name, Type: type, ProductionYear: 1988, Genres: extra.genres || ["Drama"], OfficialRating: "PG",
    RunTimeTicks: TICKS(minutes), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", CommunityRating: 7, Overview: "",
    MediaSources: [{ Id: `ms-${id}`, Container: "mp4", Bitrate: 6000000, RunTimeTicks: TICKS(minutes), Size: 1000000, SupportsDirectPlay: false, MediaStreams: STREAMS }],
    ...extra.fields,
  };
}

// Items by library (ParentId). Jellyfin returns an item only when IncludeItemTypes lists its type.
const library = {
  "lib-movies": Array.from({ length: 6 }, (_, i) => item(`mv${i}`, "Movie", `Feature Film ${i}`, 100)),
  "lib-tv": [],
  "lib-clips": [
    ...Array.from({ length: 4 }, (_, i) => item(`vid${i}`, "MusicVideo", `Artist ${i} - Song ${i}`, 4, { genres: ["Pop"], fields: { Artists: [`Artist ${i}`] } })),
    // A clip filed as a Movie, as some libraries do. It must still load.
    item("vidm0", "Movie", "Old Artist - Old Song", 4, { genres: ["Pop"] }),
  ],
  show1: Array.from({ length: 4 }, (_, i) => ({
    ...item(`ep${i}`, "Episode", `Pilot ${i}`, 45), ParentIndexNumber: 1, IndexNumber: i + 1,
  })),
};
const series = [{ Id: "show1", Name: "Test Show", Type: "Series", ProductionYear: 1995, Genres: ["Drama"], Studios: [], ProviderIds: {}, OfficialRating: "TV-PG" }];

const log = [];
let serverKind = "jellyfin";
const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = req.url;
  req.on("data", () => {});
  req.on("end", () => {
    log.push({ method: req.method, url });
    res.writeHead(200, { "Content-Type": "application/json" });
    const q = new URL(url, "http://x").searchParams;
    if (url.startsWith("/System/Info/Public")) {
      return res.end(JSON.stringify(serverKind === "emby"
        ? { ServerName: "lab", Version: "4.10.1.0", Id: "lab", LocalAddresses: [api] }
        : { ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
    }
    // Jellyfin lists libraries at /UserViews, Emby at /Users/<id>/Views.
    if (url.startsWith("/UserViews") || /^\/Users\/[^/]+\/Views/.test(url)) {
      const views = [
        { Id: "lib-movies", Name: "Movies", CollectionType: "movies" },
        { Id: "lib-tv", Name: "Shows", CollectionType: "tvshows" },
        { Id: "lib-clips", Name: "Music Videos", CollectionType: "musicvideos" },
      ];
      return res.end(JSON.stringify({ Items: views, TotalRecordCount: views.length }));
    }
    if (url.startsWith("/Items") || /^\/Users\/[^/]+\/Items/.test(url)) {
      const types = (q.get("IncludeItemTypes") || "").split(",").filter(Boolean);
      const parent = q.get("ParentId");
      let list = [];
      if (parent === "lib-tv") list = types.includes("Series") ? series : [];
      else list = (library[parent] || []).filter((i) => types.includes(i.Type));
      const start = Number(q.get("StartIndex") || 0);
      const limit = Number(q.get("Limit") || 200);
      return res.end(JSON.stringify({ Items: list.slice(start, start + limit), TotalRecordCount: list.length }));
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
  // Everything off this machine is refused, so MusicBrainz and the TMDB relay answer at once with nothing.
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url, kind]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: kind, jellyfinUserId: "u" }));
      // HIGH ROTATION is its own bundle and off until someone turns it on.
      localStorage.setItem("nostalgex_enabled_bundles", JSON.stringify(["nostalgex", "high-rotation"]));
    }
  }, [api, backend]);
  const page = await ctx.newPage();
  page.setDefaultTimeout(15000);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  return { ctx, page, errors };
}

/** The IncludeItemTypes the page sent for one library, as a sorted list per request. */
const typesAsked = (parent) => log
  .filter((l) => l.url.includes("/Items") && new URL(l.url, "http://x").searchParams.get("ParentId") === parent)
  .map((l) => (new URL(l.url, "http://x").searchParams.get("IncludeItemTypes") || "").split(",").sort().join(","));

for (const backend of ["jellyfin", "emby"]) try {
  log.length = 0;
  const { ctx, page, errors } = await launch(backend);
  const tag = backend.toUpperCase();
  const mode = await page.evaluate(() => mediaBackend);
  check(`${tag}: the page runs as ${backend}`, mode === backend, mode);

  const info = await page.evaluate(() => {
    const clips = allItemsCache.filter((i) => i.librarySource === "musicVideo");
    const hr = CHANNELS.find((c) => c.name === "HIGH ROTATION");
    return {
      total: allItemsCache.length,
      clips: clips.map((i) => i.ratingKey).sort(),
      films: allItemsCache.filter((i) => i.type === "movie" && i.librarySource === "movie").map((i) => i.ratingKey).sort(),
      episodes: allItemsCache.filter((i) => i.type === "episode").length,
      pool: hr && Array.isArray(hr.itemPool) ? hr.itemPool.map((i) => i.ratingKey).sort() : null,
    };
  });
  check(`${tag}: the four MusicVideo items are in the library as music videos (plus the clip filed as a Movie)`,
    JSON.stringify(info.clips) === JSON.stringify(["vid0", "vid1", "vid2", "vid3", "vidm0"]), JSON.stringify(info.clips));
  check(`${tag}: HIGH ROTATION has the clips`, !!info.pool && ["vid0", "vid1", "vid2", "vid3"].every((k) => info.pool.includes(k)), JSON.stringify(info.pool));
  check(`${tag}: the Movies library still loads its six films`, info.films.length === 6, JSON.stringify(info.films));
  check(`${tag}: the TV library still loads its episodes`, info.episodes === 4, String(info.episodes));

  const movies = typesAsked("lib-movies");
  check(`${tag}: the Movies library is asked for Movie and nothing else`, movies.length > 0 && movies.every((t) => t === "Movie"), JSON.stringify(movies));
  const clips = typesAsked("lib-clips");
  check(`${tag}: the Music Videos library is asked for Movie and MusicVideo`, clips.length > 0 && clips.every((t) => t === "Movie,MusicVideo"), JSON.stringify(clips));
  const tv = [...typesAsked("lib-tv"), ...typesAsked("show1")];
  check(`${tag}: the TV library is asked for Series, then Episode, as before`, JSON.stringify([...new Set(tv)].sort()) === JSON.stringify(["Episode", "Series"]), JSON.stringify(tv));
  check(`${tag}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
} catch (err) {
  failures.push(`${backend} flow stopped: ${String(err.message || err).split("\n")[0]}`);
}

await browser.close();
server.closeAllConnections?.();
files.closeAllConnections?.();
server.close();
files.close();

if (failures.length) {
  console.error(`jellyfin music videos: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`jellyfin music videos: ${passed} checks passed`);
process.exit(0);
