#!/usr/bin/env node
/**
 * Jellyfin and Emby libraries in the real plex-tuner.html (headless), against a stub server with several libraries
 * and a synthetic library of N titles, three ways:
 *
 *   CHOICE (always). First setup, through the real sign-in: the CHOOSE YOUR LIBRARIES step lists the libraries (not the
 *   Playlists or Music views), and the server has been asked for no title yet. A library switched off there is never
 *   asked for items, and its titles are not in the guide. In Settings the libraries are rows; switching one on or off
 *   reads again without it; the last library that is on cannot be switched off. On Jellyfin a library the user hides
 *   from My Media is listed only after the hidden-libraries switch is on, and then is asked for like any other.
 *
 *   SCALE (MEASURE=1, or N above 3000). The same first setup with every library on and N titles (3 in 4 films,
 *   1 in 4 episodes of 24-episode shows), each answer sized like the real thing (a source with its audio and subtitle
 *   streams, about 4 KB a title). It prints what the scan cost the page: the time to the guide, the peak JS heap,
 *   the longest stretch the main thread was busy (a long task) and how many, the most requests the server had in
 *   flight at once, and how many it was asked.
 *
 * Env: N (titles, default 1200), BACKEND=jellyfin|emby (default both), LATENCY_MS (server think time per request, default 0),
 *   PAGE_LATENCY_MS (extra think time for a full 200-title page, default 0), MEASURE=1, WAIT_MS (default 900000), TUNER_ROOT=/path (another checkout, e.g. origin/main, as a negative control).
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:mediabrowser-libraries:browser`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = process.env.TUNER_ROOT ? resolve(process.env.TUNER_ROOT) : fileURLToPath(new URL("../", import.meta.url));
const N = Number(process.env.N || 1200);
const MEASURE = !!process.env.MEASURE || N > 3000;
const SCALE_ONLY = !!process.env.SCALE_ONLY;   // skip the choice checks (they read the whole library more than once)
const LATENCY = Number(process.env.LATENCY_MS || 0);
const PAGE_LATENCY = Number(process.env.PAGE_LATENCY_MS || 0);   // extra think time for a full page of 200 titles (a real server builds its answer from the database)
const WAIT_MS = Number(process.env.WAIT_MS || 900000);
const BACKENDS = process.env.BACKEND ? [process.env.BACKEND] : ["jellyfin", "emby"];

// ── The stub's library ──
const GENRES = ["Action", "Comedy", "Drama", "Thriller", "Horror", "Romance", "Science Fiction", "Adventure", "Animation", "Family", "Crime", "Mystery", "War", "Western", "Documentary", "Music", "Fantasy", "History"];
const CERTS = ["G", "PG", "PG-13", "R", "NC-17", "", "TV-14", "TV-MA", "TV-Y"];
const MOVIES = Math.floor(N * 0.55), KIDS = Math.floor(N * 0.10), EPS = N - MOVIES - KIDS, PER_SHOW = 24, SHOWS = Math.ceil(EPS / PER_SHOW), HIDDEN = 40;
const tick = (min) => min * 60 * 10000000;
const streams = (i) => [
  { Type: "Video", Codec: i % 3 ? "h264" : "hevc", Width: 1920, Height: 1080, Index: 0, IsDefault: true, DisplayTitle: "1080p H264 SDR", BitRate: 8000000, ExtendedVideoSubType: "None", Profile: "High", Level: 41, AspectRatio: "16:9", AverageFrameRate: 23.976, RealFrameRate: 23.976, PixelFormat: "yuv420p", ColorSpace: "bt709" },
  { Type: "Audio", Codec: "eac3", Language: "eng", Index: 1, IsDefault: true, Channels: 6, DisplayTitle: "English (EAC3 5.1)", Title: "English", BitRate: 640000, SampleRate: 48000, ChannelLayout: "5.1" },
  { Type: "Audio", Codec: "aac", Language: "spa", Index: 2, Channels: 2, DisplayTitle: "Spanish (AAC Stereo)", Title: "Spanish", BitRate: 128000, SampleRate: 48000, ChannelLayout: "stereo" },
  { Type: "Subtitle", Codec: "subrip", Language: "eng", Index: 3, IsDefault: false, IsForced: false, IsExternal: false, DisplayTitle: "English (SUBRIP)", Title: "English" },
  { Type: "Subtitle", Codec: "subrip", Language: "spa", Index: 4, IsDefault: false, IsForced: false, IsExternal: false, DisplayTitle: "Spanish (SUBRIP)", Title: "Spanish" },
  { Type: "Subtitle", Codec: "ass", Language: "eng", Index: 5, IsDefault: false, IsForced: true, IsExternal: false, DisplayTitle: "English Forced (ASS)", Title: "Forced" },
];
const source = (id, i, minutes) => ({ Id: id, Container: "mkv", RunTimeTicks: tick(minutes), Size: 4000000000 + i, Bitrate: 8800000, SupportsDirectPlay: true, SupportsTranscoding: true, Path: `/media/library/${id}/file-${i}.mkv`, Name: `file-${i}`, MediaStreams: streams(i) });
const base = (id, i, name, type) => ({
  Id: id, Name: name, Type: type, ServerId: "lab", Overview: `Overview ${i}. ` + "A story about a small town and the people who live there. ".repeat(5),
  ProductionYear: 1950 + (i % 75), PremiereDate: `${1950 + (i % 75)}-0${1 + (i % 9)}-15T00:00:00.0000000Z`, DateCreated: "2020-01-01T00:00:00.0000000Z",
  OfficialRating: CERTS[i % CERTS.length] || undefined, CommunityRating: i % 4 === 0 ? undefined : 4 + (i % 50) / 10,
  Genres: [GENRES[i % GENRES.length], GENRES[(i * 5 + 1) % GENRES.length]], Studios: [{ Name: "Universal Pictures", Id: "s1" }],
  ProviderIds: i % 5 === 0 ? {} : { Tmdb: String(5000 + i), Imdb: `tt${1000000 + i}` }, UserData: { PlayCount: i % 7 === 0 ? 1 : 0, Played: false, IsFavorite: false, PlaybackPositionTicks: 0 },
  ImageTags: { Primary: "abc" }, BackdropImageTags: ["def"],
});
const movie = (lib, i) => ({ ...base(`${lib}-m${i}`, i, `Film ${(i * 7919) % 9973}`, "Movie"), RunTimeTicks: tick(80 + (i % 100)), MediaSources: [source(`${lib}-m${i}`, i, 80 + (i % 100))] });
const series = (s) => ({ ...base(`s${s}`, s, `Show ${s}`, "Series") });
const episode = (s, e) => { const i = s * PER_SHOW + e; return { ...base(`s${s}-e${e}`, i, `Episode ${i}`, "Episode"), SeriesName: `Show ${s}`, ParentIndexNumber: 1 + Math.floor(e / 12), IndexNumber: (e % 12) + 1, RunTimeTicks: tick(20 + (i % 40)), MediaSources: [source(`s${s}-e${e}`, i, 20 + (i % 40))] }; };
const episodesOf = (s) => Math.min(PER_SHOW, EPS - s * PER_SHOW);
const VIEWS = [
  { Id: "v-movies", Name: "Movies", CollectionType: "movies", count: MOVIES },
  { Id: "v-kids", Name: "Kids Movies", CollectionType: "movies", count: KIDS },
  { Id: "v-tv", Name: "TV Shows", CollectionType: "tvshows", count: SHOWS },
  { Id: "v-playlists", Name: "Playlists", CollectionType: "playlists", count: 3 },
  { Id: "v-music", Name: "Music", CollectionType: "music", count: 10 },
];
const BOX = Number(process.env.BOXSETS || Math.max(8, Math.floor(N / 40))), BOX_SIZE = 6;   // collections, each of 6 films of the Movies library
const HIDDEN_VIEW = { Id: "v-hidden", Name: "Hidden Films", CollectionType: "movies", count: HIDDEN };

let emby = false;
const asked = [];          // every /Items request: { parent, type, start, limit }
const viewPaths = [];      // every request for the library list
let inflight = 0, maxInflight = 0, requests = 0, movieInflight = 0, maxMovieInflight = 0;   // movieInflight: page requests of the Movies library in flight
const media = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  const json = (body, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(typeof body === "string" ? body : JSON.stringify(body)); };
  const p = url.pathname;
  if (p === "/System/Info/Public") {
    return json(emby ? { ServerName: "lab", Version: "4.10.1.0", Id: "lab", LocalAddresses: [] } : { ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" });
  }
  if (p.startsWith("/QuickConnect/Enabled")) return json("false");
  if (p.startsWith("/Users/Public")) return json("[]");
  if (p.startsWith("/Users/AuthenticateByName")) { req.resume(); return req.on("end", () => json({ AccessToken: "TOKEN", User: { Id: "uid1", Name: "bob", ServerName: "lab" } })); }
  const respond = () => {
    requests++; inflight++; maxInflight = Math.max(maxInflight, inflight);
    // think time: a fixed part, and a part in proportion to the rows in the answer (200 rows = PAGE_LATENCY)
    const done = (fn, rows = 0) => setTimeout(() => { try { fn(); } finally { inflight--; } }, LATENCY + PAGE_LATENCY * Math.min(rows, 200) / 200);
    const strip = (v) => ({ Id: v.Id, Name: v.Name, CollectionType: v.CollectionType });
    if (p === "/UserViews" || /^\/Users\/[^/]+\/Views$/.test(p)) {
      viewPaths.push(req.url);
      const hidden = url.searchParams.get("includeHidden") === "true" && !emby;
      return done(() => json({ Items: [...VIEWS, ...(hidden ? [HIDDEN_VIEW] : [])].map(strip), TotalRecordCount: VIEWS.length + (hidden ? 1 : 0) }));
    }
    if (p === "/Items") {
      const parent = url.searchParams.get("ParentId") || "";
      const type = url.searchParams.get("IncludeItemTypes") || "";
      const start = Number(url.searchParams.get("StartIndex") || 0);
      const limit = Number(url.searchParams.get("Limit") || 100000);
      asked.push({ parent, type, start, limit });
      const rowsOf = (total) => Math.max(0, Math.min(limit, total - start));
      const page = (total, make) => { const rows = []; for (let i = start; i < Math.min(total, start + limit); i++) rows.push(make(i)); return { Items: rows, TotalRecordCount: total }; };
      if (!parent && type === "BoxSet") return done(() => json(page(BOX, (b) => ({ Id: `b${b}`, Name: `Collection ${b}`, Type: "BoxSet", ChildCount: BOX_SIZE, ImageTags: { Primary: "x" } }))));
      const bm = /^b(\d+)$/.exec(parent);
      if (bm) { const b = Number(bm[1]); return done(() => json(page(BOX_SIZE, (k) => ({ Id: `a-m${(b * BOX_SIZE + k) % MOVIES}`, Name: "x", Type: "Movie" })))); }
      if (parent === "v-movies") { movieInflight++; maxMovieInflight = Math.max(maxMovieInflight, movieInflight); return done(() => { movieInflight--; json(page(MOVIES, (i) => movie("a", i))); }, rowsOf(MOVIES)); }
      if (parent === "v-kids") return done(() => json(page(KIDS, (i) => movie("k", i))), rowsOf(KIDS));
      if (parent === "v-hidden") return done(() => json(page(HIDDEN, (i) => movie("h", i))), rowsOf(HIDDEN));
      if (parent === "v-tv") return done(() => json(page(SHOWS, series)), rowsOf(SHOWS));
      const m = /^s(\d+)$/.exec(parent);
      if (m) { const s = Number(m[1]); return done(() => json(page(episodesOf(s), (e) => episode(s, e))), rowsOf(episodesOf(s))); }
      if (parent === "v-playlists") return done(() => json({ Items: [{ Id: "pl1", Name: "A playlist", Type: "Playlist", RunTimeTicks: tick(33) }], TotalRecordCount: 1 }));
      return done(() => json({ Items: [], TotalRecordCount: 0 }));
    }
    done(() => json({}));
  };
  respond();
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  let p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!extname(p) && existsSync(p + ".html")) p += ".html";
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => media.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${media.address().port}`;
const site = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true, args: ["--js-flags=--max-old-space-size=6000"] });

/** First setup through the real sign-in, up to the CHOOSE YOUR LIBRARIES step. Returns the page and what it needs to measure. */
async function firstSetup(kind, { hiddenSwitch = false } = {}) {
  emby = kind === "emby";
  asked.length = 0; viewPaths.length = 0; requests = 0; maxInflight = 0; movieInflight = 0; maxMovieInflight = 0;
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  await ctx.addInitScript((hidden) => {
    if (hidden) localStorage.setItem("nostalgex_include_hidden_libraries", "1");
    window.__long = [];
    try { new PerformanceObserver((l) => window.__long.push(...l.getEntries().map((e) => ({ at: e.startTime, ms: e.duration })))).observe({ entryTypes: ["longtask"] }); } catch (e) {}
  }, hiddenSwitch);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  const cdp = await ctx.newCDPSession(page);
  await cdp.send("Performance.enable");
  await page.goto(`${site}/web-tuner.html`);
  await page.waitForSelector("#connect-btn", { state: "visible" });
  await page.click(kind === "emby" ? "#connect-emby-btn" : "#connect-jellyfin-btn");
  await page.click("#find-type-btn");
  await page.fill("#address-input", api);
  await page.click("#address-connect");
  await page.waitForSelector("#signin-user", { state: "visible", timeout: 15000 });
  await page.fill("#signin-user", "bob");
  await page.fill("#signin-pass", "pw");
  await page.click("#signin-btn");
  await page.waitForURL(/plex-tuner\.html/, { timeout: 15000 });
  await page.waitForSelector("#library-picker.active .library-continue", { timeout: 30000 });
  return { ctx, page, cdp, errors };
}
const pickerRows = (page) => page.evaluate(() => [...document.querySelectorAll("#library-picker .setup-row")].map((r) => ({ title: r.querySelector(".setup-row-title").textContent, on: r.getAttribute("aria-checked") === "true", sub: r.querySelector(".setup-row-sub").textContent })));
const toGuide = (page) => page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof allItemsCache !== "undefined" && allItemsCache.length > 0, null, { timeout: WAIT_MS });
const itemRequests = () => asked.filter((a) => a.type && a.type !== "BoxSet" && !/^b\d+$/.test(a.parent));   // libraries only; collections are read server-wide
const boxRequests = () => asked.filter((a) => a.type === "BoxSet" || /^b\d+$/.test(a.parent));

for (const kind of BACKENDS) {
  // ── CHOICE ──
  if (!SCALE_ONLY) {
    const { ctx, page, errors } = await firstSetup(kind);
    const rows = await pickerRows(page);
    check(`${kind}: CHOOSE YOUR LIBRARIES lists the video libraries, all on`, JSON.stringify(rows.map((r) => r.title)) === JSON.stringify(["Movies", "Kids Movies", "TV Shows"]) && rows.every((r) => r.on), JSON.stringify(rows));
    check(`${kind}: it does not list the Playlists or Music views`, !rows.some((r) => /Playlists|Music/.test(r.title)));
    check(`${kind}: each row says what kind of library it is`, rows[0].sub === "Movies" && rows[2].sub === "TV Shows", JSON.stringify(rows.map((r) => r.sub)));
    check(`${kind}: no title has been asked for before CONTINUE`, itemRequests().length === 0, JSON.stringify(itemRequests().slice(0, 2)));
    check(`${kind}: the library list is asked for the way ${kind} takes it`, viewPaths.length > 0 && viewPaths.every((v) => (kind === "emby" ? v === "/Users/uid1/Views" : /^\/UserViews\?userId=uid1$/.test(v))), viewPaths.join(" "));
    await page.click(`#library-picker .setup-row:has-text("Kids Movies")`);
    await page.click(`#library-picker .setup-row:has-text("TV Shows")`);
    const after = await pickerRows(page);
    check(`${kind}: clicking a row switches it off`, after.filter((r) => !r.on).map((r) => r.title).join() === "Kids Movies,TV Shows", JSON.stringify(after));
    await page.click(".library-continue");
    await toGuide(page);
    const parents = [...new Set(itemRequests().map((a) => a.parent))];
    check(`${kind}: only the library left on is asked for titles`, parents.join() === "v-movies", JSON.stringify(itemRequests().filter((a) => a.parent !== "v-movies").slice(0, 3)));
    const lib = await page.evaluate(() => ({ n: allItemsCache.length, types: [...new Set(allItemsCache.map((i) => i.type))], ids: allItemsCache.slice(0, 3).map((i) => i.ratingKey) }));
    check(`${kind}: a library of several pages is read with the next pages asked for ahead (2 or 3 at once, no more)`, MOVIES <= 600 || (maxMovieInflight >= 2 && maxMovieInflight <= 3), `${maxMovieInflight} at most in flight`);
    check(`${kind}: the guide holds only that library's titles`, lib.n === MOVIES && lib.types.join() === "movie", JSON.stringify(lib));
    // Settings: the libraries are rows, switching one on reads again with it.
    await page.evaluate(() => refreshLibraryRows());
    await page.waitForFunction(() => document.querySelectorAll("#cfg-library-rows .cfg-row").length === 3, null, { timeout: 15000 });
    const settingsRows = await page.evaluate(() => [...document.querySelectorAll("#cfg-library-rows .cfg-row")].map((r) => ({ title: r.querySelector(".cfg-row-title").textContent, on: r.getAttribute("aria-checked") === "true", desc: r.querySelector(".cfg-row-desc").textContent })));
    check(`${kind}: Settings has a row per library with the same on and off`, settingsRows.map((r) => `${r.title}:${r.on}`).join() === "Movies:true,Kids Movies:false,TV Shows:false", JSON.stringify(settingsRows));
    check(`${kind}: the last library that is on is marked and cannot be switched off`, /only enabled library/.test(settingsRows[0].desc));
    await page.evaluate(() => document.querySelector('#cfg-library-rows .cfg-row').click());
    await page.waitForTimeout(300);
    check(`${kind}: clicking the last one on does nothing`, (await page.evaluate(() => document.querySelector('#cfg-library-rows .cfg-row').getAttribute("aria-checked"))) === "true");
    const before = asked.length;
    await page.evaluate(() => [...document.querySelectorAll("#cfg-library-rows .cfg-row")].find((r) => /Kids Movies/.test(r.textContent)).click());
    await page.waitForFunction((k) => allItemsCache.length === k, MOVIES + KIDS, { timeout: WAIT_MS }).catch(() => {});
    const n2 = await page.evaluate(() => allItemsCache.length);
    check(`${kind}: switching Kids Movies on in Settings reads it, and only it adds titles`, n2 === MOVIES + KIDS, `${n2} vs ${MOVIES + KIDS}`);
    check(`${kind}: the guide stayed up while it read`, (await page.evaluate(() => getComputedStyle(document.getElementById("guide-grid")).display)) !== "none");
    check(`${kind}: no page errors`, errors.length === 0, errors.join(" | "));
    await ctx.close();
  }
  // ── Hidden libraries (Jellyfin only: Emby's list has no such switch) ──
  if (kind === "jellyfin" && !SCALE_ONLY) {
    const off = await firstSetup(kind);
    check(`${kind}: a library hidden from My Media is not listed while the switch is off`, !(await pickerRows(off.page)).some((r) => /Hidden Films/.test(r.title)));
    await off.ctx.close();
    const on = await firstSetup(kind, { hiddenSwitch: true });
    const rows = await pickerRows(on.page);
    check(`${kind}: with the switch on it is listed, with the others`, rows.some((r) => /Hidden Films/.test(r.title)), JSON.stringify(rows));
    await on.page.click(".library-continue");
    await toGuide(on.page);
    check(`${kind}: and it is asked for like any other`, itemRequests().some((a) => a.parent === "v-hidden"));
    await on.ctx.close();
  }
  // ── SCALE ──
  if (MEASURE) {
    const { ctx, page, cdp, errors } = await firstSetup(kind);
    let peak = 0;
    const heapMB = async () => { const m = (await cdp.send("Performance.getMetrics")).metrics.find((x) => x.name === "JSHeapUsedSize"); return m ? m.value / 1048576 : -1; };
    const sampler = setInterval(async () => { try { peak = Math.max(peak, await heapMB()); } catch (e) {} }, 500);
    const PROFILE = !!process.env.PROFILE;
    if (PROFILE) { await cdp.send("Profiler.enable"); await cdp.send("Profiler.setSamplingInterval", { interval: 1000 }); await cdp.send("Profiler.start"); }
    const before = await heapMB();
    const t0 = Date.now();
    await page.click(".library-continue");
    const expected = MOVIES + KIDS + EPS;
    await page.waitForFunction((n) => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof allItemsCache !== "undefined" && allItemsCache.length >= n, expected, { timeout: WAIT_MS }).catch(() => {});
    const ms = Date.now() - t0;
    clearInterval(sampler);
    if (PROFILE) {
      const { profile } = await cdp.send("Profiler.stop");
      const self = new Map(), byId = new Map(profile.nodes.map((n) => [n.id, n]));
      const dt = profile.timeDeltas; let total = 0;
      profile.samples.forEach((id, i) => { const n = byId.get(id), f = n.callFrame, key = `${f.functionName || "(anon)"} ${f.url.split("/").pop()}:${f.lineNumber + 1}`; self.set(key, (self.get(key) || 0) + dt[i]); total += dt[i]; });
      console.log(`PROFILE ${kind}: top self time of ${(total / 1000).toFixed(0)} ms sampled`);
      for (const [k, v] of [...self.entries()].sort((x, y) => y[1] - x[1]).slice(0, 14)) console.log(`  ${(v / 1000).toFixed(0).padStart(6)} ms  ${k}`);
    }
    const after = await heapMB();
    const longs = await page.evaluate(() => window.__long.filter((l) => l.at > 0));
    const worst = Math.max(0, ...longs.map((l) => l.ms)), total = longs.reduce((a, l) => a + l.ms, 0);
    const state = await page.evaluate(() => ({ n: allItemsCache.length, channels: typeof CHANNELS !== "undefined" ? CHANNELS.length : -1, guide: getComputedStyle(document.getElementById("guide-grid")).display }));
    const itemsAsked = itemRequests().length, boxAsked = boxRequests().length;
    console.log(`MEASURE ${kind} N=${N} (latency ${LATENCY} ms, ${PAGE_LATENCY} ms a full page): ${(ms / 1000).toFixed(1)} s to the guide; ${state.n} of ${expected} titles on ${state.channels} channels; heap ${before.toFixed(0)} MB before, ${peak.toFixed(0)} MB peak, ${after.toFixed(0)} MB after; ${longs.length} long tasks (longest ${worst.toFixed(0)} ms, ${total.toFixed(0)} ms in all); ${requests} requests (${itemsAsked} for titles, ${boxAsked} for ${BOX} collections), at most ${maxInflight} in flight`);
    check(`${kind} scale: every title is in the library`, state.n === expected, `${state.n} of ${expected}`);
    check(`${kind} scale: the guide is up`, state.guide !== "none", state.guide);
    check(`${kind} scale: no page errors`, errors.length === 0, errors.join(" | "));
    await ctx.close();
  }
}
await browser.close();
media.close(); files.close();
if (failures.length) {
  console.error(`mediabrowser libraries (browser): ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`mediabrowser libraries (browser): ${passed} checks passed${MEASURE ? ` (with the scale run at N=${N})` : ""}`);
