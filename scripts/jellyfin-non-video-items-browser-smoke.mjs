#!/usr/bin/env node
/**
 * A Jellyfin or Emby playlist never becomes a programme, and what happens if one does (Discord
 * report: a workout playlist of eight songs on CH 07 VHS VAULT, "Jellyfin answered HTTP 500").
 *
 * The real plex-tuner.html, headless, with the real hls.js, against a Jellyfin-shaped and an
 * Emby-shaped stub that records every request. Its libraries: Movies, Shows, Music Videos, Music,
 * Collections and Playlists. The Playlists view answers the way Jellyfin's PlaylistsFolder does,
 * with its playlists whatever IncludeItemTypes says. A playlist has no media source, so the stub
 * answers HTTP 500 to PlaybackInfo and to the HLS playlist for a playlist id: that answer is
 * modelled, not measured (no real server was asked), and is the one thing here that is assumed.
 *
 * It checks, on each backend:
 *   - nothing but films, episodes and music videos is in the scanned library, and no channel pool
 *     holds a playlist, a song, an album, an artist or a collection;
 *   - no request names a playlist id, so nothing asks the server to play one;
 *   - the Playlists, Music and Collections views are never asked for items;
 *   - HIGH ROTATION still has the music videos and VHS VAULT its six films.
 * If the page does hold a playlist item (origin/main), it then plays it and reports what the
 * tuner showed and which requests it made, so the check says what a viewer would have seen.
 * Negative control: TUNER_ROOT=/path runs another checkout (origin/main), which must fail.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable
 * `playwright`; and `npm ci` for hls.js. Run: `npm run test:jellyfin-non-video:browser`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const repo = fileURLToPath(new URL("../", import.meta.url));
const root = process.env.TUNER_ROOT ? process.env.TUNER_ROOT.replace(/\/?$/, "/") : repo;
const hlsPath = [join(root, "node_modules/hls.js/dist/hls.min.js"), join(repo, "node_modules/hls.js/dist/hls.min.js")].find(existsSync);

const TICKS = (min) => min * 60 * 10000000;
const STREAMS = [
  { Type: "Video", Codec: "h264", Width: 1920, Height: 1080, Index: 0, IsDefault: true },
  { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true, DisplayTitle: "English AAC" },
];
const base = (id, type, name, minutes, extra = {}) => ({
  Id: id, Name: name, Type: type, RunTimeTicks: TICKS(minutes), ProviderIds: {}, Studios: [],
  DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "", ...extra,
});
const video = (id, type, name, minutes, extra = {}) => base(id, type, name, minutes, {
  ProductionYear: 1988, Genres: ["Drama"], OfficialRating: "PG", CommunityRating: 7,
  MediaSources: [{ Id: `ms-${id}`, Container: "mp4", Bitrate: 6000000, RunTimeTicks: TICKS(minutes), Size: 1000000, SupportsDirectPlay: false, MediaStreams: STREAMS }], ...extra,
});

const PLAYLIST = base("pl-audio", "Playlist", "Workout Mix", 33, { MediaType: "Audio", IsFolder: true, ChildCount: 8 });
const SONGS = Array.from({ length: 8 }, (_, i) => base(`song${i}`, "Audio", `Track ${i}`, 4, { ProductionYear: 1994, Genres: ["Rock"], MediaType: "Audio" }));
const ALBUM = base("album1", "MusicAlbum", "Some Album", 33, { ProductionYear: 1994, Genres: ["Rock"], IsFolder: true });
const ARTIST = base("artist1", "MusicArtist", "Some Artist", 0, { IsFolder: true });
const BOXSET = base("box1", "BoxSet", "Rocky Collection", 600, { ProductionYear: 1985, Genres: ["Drama"], IsFolder: true });
const NON_VIDEO = ["pl-audio", "album1", "artist1", "box1", ...SONGS.map((s) => s.Id)];

const held = {
  "lib-movies": Array.from({ length: 6 }, (_, i) => video(`mv${i}`, "Movie", `Feature Film ${i}`, 100)),
  "lib-clips": [
    ...Array.from({ length: 4 }, (_, i) => video(`vid${i}`, "MusicVideo", `Artist ${i} - Song ${i}`, 4, { Genres: ["Pop"] })),
    video("vidm0", "Movie", "Old Artist - Old Song", 4, { Genres: ["Pop"] }),
  ],
  "lib-music": [ALBUM, ...SONGS, ARTIST],
  "lib-boxsets": [BOXSET],
  "lib-playlists": [PLAYLIST],
  show1: Array.from({ length: 4 }, (_, i) => ({ ...video(`ep${i}`, "Episode", `Pilot ${i}`, 45), ParentIndexNumber: 1, IndexNumber: i + 1 })),
};
const series = [{ Id: "show1", Name: "Test Show", Type: "Series", ProductionYear: 1995, Genres: ["Drama"], Studios: [], ProviderIds: {}, OfficialRating: "TV-PG" }];
const VIEWS = [
  { Id: "lib-movies", Name: "Movies", CollectionType: "movies" },
  { Id: "lib-tv", Name: "Shows", CollectionType: "tvshows" },
  { Id: "lib-clips", Name: "Music Videos", CollectionType: "musicvideos" },
  { Id: "lib-music", Name: "Music", CollectionType: "music" },
  { Id: "lib-boxsets", Name: "Collections", CollectionType: "boxsets" },
  { Id: "lib-playlists", Name: "Playlists", CollectionType: "playlists" },
];

const log = [];
let serverKind = "jellyfin";
const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  res.setHeader("Access-Control-Allow-Methods", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = req.url;
  req.on("data", () => {});
  req.on("end", () => {
    log.push({ method: req.method, url });
    const q = new URL(url, "http://x").searchParams;
    const path = new URL(url, "http://x").pathname;
    if (url.startsWith("/System/Info/Public")) {
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(JSON.stringify(serverKind === "emby"
        ? { ServerName: "lab", Version: "4.10.1.0", Id: "lab", LocalAddresses: [api] }
        : { ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
    }
    // A playlist has nothing to play: the server errors (modelled, see the header).
    if (/\/Items\/pl-audio\/PlaybackInfo$/.test(path) || /\/Videos\/pl-audio\//.test(path)) {
      res.writeHead(500, { "Content-Type": "application/json" });
      return res.end("{}");
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    if (url.startsWith("/UserViews") || /^\/Users\/[^/]+\/Views/.test(url)) {
      return res.end(JSON.stringify({ Items: VIEWS, TotalRecordCount: VIEWS.length }));
    }
    if (url.startsWith("/Items") || /^\/Users\/[^/]+\/Items/.test(url)) {
      const asked = (q.get("IncludeItemTypes") || "").split(",").filter(Boolean);
      const parent = q.get("ParentId");
      let list;
      if (parent === "lib-playlists") list = held[parent];                    // PlaylistsFolder: Recursive, [Playlist]
      else if (parent === "lib-tv") list = asked.includes("Series") ? series : [];
      else list = (held[parent] || []).filter((i) => asked.includes(i.Type));
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
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(readFileSync(p));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${server.address().port}`;
const base_ = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });

async function launch(backend) {
  serverKind = backend;
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: "en-US" });
  // Off this machine nothing is reached, except hls.js, which is served from node_modules.
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => {
    if (hlsPath && /hls\.js/.test(route.request().url())) return route.fulfill({ path: hlsPath, contentType: "text/javascript" });
    return route.abort();
  });
  await ctx.addInitScript(([url, kind]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: kind, jellyfinUserId: "u" }));
      localStorage.setItem("nostalgex_enabled_bundles", JSON.stringify(["nostalgex", "high-rotation"]));
    }
  }, [api, backend]);
  const page = await ctx.newPage();
  page.setDefaultTimeout(15000);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.goto(`${base_}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  return { ctx, page, errors };
}

const typesAsked = (parent) => log
  .filter((l) => l.url.includes("/Items") && new URL(l.url, "http://x").searchParams.get("ParentId") === parent)
  .map((l) => (new URL(l.url, "http://x").searchParams.get("IncludeItemTypes") || "").split(",").sort().join(","));

for (const backend of ["jellyfin", "emby"]) try {
  log.length = 0;
  const { ctx, page, errors } = await launch(backend);
  const tag = backend.toUpperCase();
  check(`${tag}: the page runs as ${backend}`, (await page.evaluate(() => mediaBackend)) === backend);

  const info = await page.evaluate((nonVideo) => {
    const all = typeof allChannelsUnfiltered !== "undefined" ? allChannelsUnfiltered : CHANNELS;
    const pool = (name) => { const c = all.find((x) => x.name === name); return c && Array.isArray(c.itemPool) ? c.itemPool.map((i) => i.ratingKey).sort() : null; };
    const holders = all.filter((c) => Array.isArray(c.itemPool) && c.itemPool.some((i) => nonVideo.includes(i.ratingKey))).map((c) => `CH ${c.number} ${c.name}`);
    return {
      keys: allItemsCache.map((i) => i.ratingKey),
      holders, vhs: pool("VHS VAULT"), hr: pool("HIGH ROTATION"),
    };
  }, NON_VIDEO);
  const leaked = NON_VIDEO.filter((id) => info.keys.includes(id));
  check(`${tag}: no playlist, song, album, artist or collection is in the library`, leaked.length === 0, leaked.join(", "));
  check(`${tag}: none of them is in a channel's pool`, info.holders.length === 0, info.holders.join(", "));
  check(`${tag}: nothing else is in the library (6 films, 5 clips, 4 episodes)`, info.keys.length === 15, `${info.keys.length}: ${info.keys.join(", ")}`);
  check(`${tag}: VHS VAULT has its six films`, !!info.vhs && JSON.stringify(info.vhs) === JSON.stringify(["mv0", "mv1", "mv2", "mv3", "mv4", "mv5"]), JSON.stringify(info.vhs));
  check(`${tag}: HIGH ROTATION has the music videos`, !!info.hr && ["vid0", "vid1", "vid2", "vid3"].every((k) => info.hr.includes(k)), JSON.stringify(info.hr));

  for (const [view, name] of [["lib-playlists", "Playlists"], ["lib-music", "Music"], ["lib-boxsets", "Collections"]]) {
    check(`${tag}: the ${name} view is not asked for items`, typesAsked(view).length === 0, JSON.stringify(typesAsked(view)));
  }
  check(`${tag}: Movies is asked for Movie, Music Videos for Movie and MusicVideo`,
    typesAsked("lib-movies").every((t) => t === "Movie") && typesAsked("lib-clips").every((t) => t === "Movie,MusicVideo") && typesAsked("lib-movies").length > 0 && typesAsked("lib-clips").length > 0,
    JSON.stringify([typesAsked("lib-movies"), typesAsked("lib-clips")]));

  // If the playlist is in the library, play it, as a viewer's guide would when its slot comes up.
  const held_ = await page.evaluate(() => allItemsCache.find((i) => i.ratingKey === "pl-audio") || null);
  if (held_) {
    log.length = 0;
    const result = await page.evaluate(async () => {
      const item = allItemsCache.find((i) => i.ratingKey === "pl-audio");
      const channel = (typeof allChannelsUnfiltered !== "undefined" ? allChannelsUnfiltered : CHANNELS).find((c) => c.name === "VHS VAULT");
      playCurrentItem(item, channel);
      const until = Date.now() + 20000;
      while (Date.now() < until) {
        const s = document.getElementById("display-status");
        if (s && /HTTP \d+/.test(s.textContent)) return { card: s.textContent };
        await new Promise((r) => setTimeout(r, 250));
      }
      const s = document.getElementById("display-status");
      return { card: s ? s.textContent : "(no card)" };
    });
    const mine = log.filter((l) => l.url.includes("pl-audio")).map((l) => `${l.method} ${new URL(l.url, "http://x").pathname}`);
    // Not a check (the library check above already fails): what the viewer would have seen.
    console.log(`MEASURED ${tag}: playing the playlist from VHS VAULT showed ${JSON.stringify(result.card)}; requests naming it: ${JSON.stringify([...new Set(mine)])}`);
  } else {
    check(`${tag}: no request names a playlist id`, !log.some((l) => l.url.includes("pl-audio")), JSON.stringify(log.filter((l) => l.url.includes("pl-audio")).map((l) => l.url)));
  }
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
  console.error(`jellyfin non-video items: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`jellyfin non-video items: ${passed} checks passed`);
process.exit(0);
