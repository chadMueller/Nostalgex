#!/usr/bin/env node
/**
 * A library of any size loads, and a storage failure is never reported as an unreachable
 * server (issue #152, reported on a self-hosted tuner with about 6,200 episodes and 519
 * movies).
 *
 * What happened: saveLibraryCache() wrote the whole library to localStorage, which gives an
 * origin about 5 MB for everything. On a library that size it fit with almost nothing to
 * spare, so the next write, the few KB of channel config, threw QuotaExceededError. The error
 * came up through fetchPlexLibrary() and was shown as "COULD NOT LOAD LIBRARY. YOUR SERVER
 * MAY BE UNREACHABLE". A first try/catch around that one write only moved the throw to the
 * next unguarded write (the "first load done" flag in nostalgex-library-load.js).
 *
 * The fix, checked here against the real plex-tuner.html in headless Chromium and a
 * Plex-shaped server:
 *   A. 6,738 items, Chromium's real quota: loads, config saved, localStorage nowhere near
 *      full, the library cached whole in IndexedDB and restored on reload without asking
 *      the server again.
 *   B. The state a 1.0.9 browser was left in (localStorage filled by the old library cache):
 *      the page frees it and loads.
 *   C. A quota already used up by rebuildable data: a small setting evicts it, in order.
 *   D. A quota used up by data the page cannot rebuild: the load still finishes, and nothing
 *      blames the server.
 *   E. The error screen: a server that is down still says so; a storage failure and a build
 *      failure say what they are.
 *   F. Sign-out: the cache is invalid the instant the id is removed, even if IndexedDB has
 *      not finished deleting.
 *   G. IndexedDB missing, and IndexedDB that never answers: the load still finishes.
 *
 * Run it against another checkout (a release, or origin/main before the fix) with
 * TUNER_ROOT=/path/to/checkout to see which of these fail there. REPORT=1 prints the
 * measurements as JSON. SUMMARY_CHARS tunes how large the fake library's summaries are.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:storage-quota`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = (process.env.TUNER_ROOT ? resolve(process.env.TUNER_ROOT) : fileURLToPath(new URL("../", import.meta.url)).replace(/\/$/, "")) + "/";
const REPORT = !!process.env.REPORT;
const VERBOSE = !!process.env.VERBOSE;
// How long a load may take before it counts as stuck. Lower it when running against code that is expected to hang.
const SETTLE_MS = Number(process.env.SETTLE_MS || 120000);
// FIRST_LOAD_ONLY=1 stops scenario A after the first load (no reload, no sign-out): for code with no IndexedDB cache.
const FIRST_LOAD_ONLY = !!process.env.FIRST_LOAD_ONLY;
// ITEM_PAD characters are added to every item's studio name. The reported library left the old
// cache within a few KB of the quota; ITEM_PAD=<n> makes this one do the same, for running against
// a release that still caches in localStorage (it is 0 for the smoke: the fix does not depend on it).
const ITEM_PAD = Number(process.env.ITEM_PAD || 0);
const pad = "p".repeat(ITEM_PAD);
// SEED_JUNK_CHARS adds a key of somebody else's data before the page runs, to take the last few KB the
// old cache left (a browser with a few more settings saved than the reporter's).
const SEED_JUNK_CHARS = Number(process.env.SEED_JUNK_CHARS || 0);
// ONLY=A,C runs just those scenarios (letters as in the header).
const ONLY = (process.env.ONLY || "A,B,C,D,E,G").split(",");
const scenario = (letter) => ONLY.includes(letter);
const SUMMARY_CHARS = Number(process.env.SUMMARY_CHARS || 330);
const CACHE_ID_KEY = "plex90_library_cache_id";

// ── A Plex-shaped library ────────────────────────────────────────────────────

const GENRES = ["Drama", "Comedy", "Action", "Science Fiction", "Animation", "Crime", "Family", "Horror", "Thriller", "Adventure"];
const RATINGS = ["PG", "PG-13", "R", "TV-14", "TV-MA", "TV-PG", "TV-G"];
const WORDS = "the a an of and to in on at by for with from after before during against under over about into through between family friend stranger secret night day city town road house door window letter promise storm river mountain summer winter dinner wedding funeral trial journey return escape discovery mistake surprise visit message plan crew captain doctor teacher neighbor brother sister mother father detective ghost robot stranger".split(" ");
function sentence(seed, chars) {
  let out = "";
  let i = seed * 7919;
  while (out.length < chars) {
    i = (i * 1103515245 + 12345) & 0x7fffffff;
    out += (out ? " " : "") + WORDS[i % WORDS.length];
  }
  return out.slice(0, chars).replace(/^./, (c) => c.toUpperCase()) + ".";
}
const media = (n, minutes) => [{
  container: "mkv", videoResolution: "1080", bitrate: 6000 + (n % 5) * 1000, videoCodec: "h264", audioCodec: "aac",
  Part: [{ key: `/library/parts/${n}/file.mkv` }],
}].map((m) => ({ ...m, duration: minutes * 60000 }));

function makeLibrary({ movies, shows, episodesPerShow, lastShowEpisodes }) {
  const movieItems = Array.from({ length: movies }, (_, i) => ({
    ratingKey: String(1000 + i), title: `Movie ${i + 1} ${sentence(i, 14)}`.slice(0, 40), summary: sentence(i + 11, SUMMARY_CHARS),
    year: 1960 + (i % 60), duration: (88 + (i % 40)) * 60000, type: "movie", addedAt: 1700000000 + i * 1000,
    contentRating: RATINGS[i % 4], rating: 5 + (i % 5), Genre: [{ tag: GENRES[i % 10] }, { tag: GENRES[(i + 3) % 10] }],
    Director: [{ tag: `Director ${i % 50}` }], studio: `Studio ${i % 30}${pad}`, thumb: `/library/metadata/${1000 + i}/thumb/1699999999`, art: `/library/metadata/${1000 + i}/art/1699999999`,
    Guid: [{ id: `tmdb://${50000 + i}` }], Media: media(i, 90 + (i % 30)),
  }));
  const showItems = Array.from({ length: shows }, (_, i) => ({
    ratingKey: String(5000 + i), title: `Show ${i + 1} ${sentence(i + 3, 12)}`.slice(0, 36), summary: sentence(i + 5, SUMMARY_CHARS),
    year: 1970 + (i % 45), contentRating: RATINGS[3 + (i % 4)], rating: 6 + (i % 4), type: "show",
    Genre: [{ tag: GENRES[i % 10] }, { tag: GENRES[(i + 4) % 10] }], studio: `Network ${i % 12}${pad}`, thumb: `/library/metadata/${5000 + i}/thumb/1699999999`, art: `/library/metadata/${5000 + i}/art/1699999999`,
    Guid: [{ id: `tmdb://${90000 + i}` }], originallyAvailableAt: `${1970 + (i % 45)}-01-01`,
  }));
  const episodes = new Map();
  showItems.forEach((show, s) => {
    const count = s === shows - 1 && lastShowEpisodes != null ? lastShowEpisodes : episodesPerShow;
    episodes.set(show.ratingKey, Array.from({ length: count }, (_, e) => ({
      ratingKey: String(100000 + s * 1000 + e), title: `Episode ${e + 1} ${sentence(s * 131 + e, 10)}`.slice(0, 34),
      summary: sentence(s * 977 + e, SUMMARY_CHARS), parentIndex: 1 + Math.floor(e / 20), index: 1 + (e % 20),
      duration: (21 + (e % 3) * 10) * 60000, addedAt: 1700000000 + s * 100 + e, viewCount: 0,
      thumb: `/library/metadata/${100000 + s * 1000 + e}/thumb/1699999999`,
      originallyAvailableAt: `${1970 + (s % 45)}-0${1 + (e % 9)}-1${e % 9}`,
      Media: media(s * 1000 + e, 22 + (e % 3) * 10),
    })));
  });
  return { movieItems, showItems, episodes, total: movieItems.length + [...episodes.values()].reduce((n, l) => n + l.length, 0) };
}

const BIG = makeLibrary({ movies: 519, shows: 63, episodesPerShow: 100, lastShowEpisodes: 19 });   // 6,738 items
const SMALL = makeLibrary({ movies: 60, shows: 6, episodesPerShow: 25 });                          // 210 items

function startPlex(library) {
  const counts = { sectionAll: 0, allLeaves: 0, other: 0 };
  const server = http.createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Headers", "*");
    if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
    const url = new URL(req.url, "http://x");
    const path = url.pathname;
    res.setHeader("Content-Type", "application/json");
    const container = (list, start, size) => {
      const page = list.slice(start, start + size);
      return JSON.stringify({ MediaContainer: { size: page.length, totalSize: list.length, Metadata: page } });
    };
    if (path === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
    if (path === "/library/sections") {
      return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }, { key: "2", title: "TV Shows", type: "show" }] } }));
    }
    const all = path.match(/^\/library\/sections\/(\d+)\/all$/);
    if (all) {
      counts.sectionAll += 1;
      const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0);
      const size = Number(url.searchParams.get("X-Plex-Container-Size") || 100000);
      return res.end(container(all[1] === "1" ? library.movieItems : library.showItems, start, size));
    }
    const leaves = path.match(/^\/library\/metadata\/(\d+)\/allLeaves$/);
    if (leaves) {
      counts.allLeaves += 1;
      return res.end(container(library.episodes.get(leaves[1]) || [], 0, 100000));
    }
    counts.other += 1;
    res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
  });
  return new Promise((r) => server.listen(0, "127.0.0.1", () => r({ server, counts, url: `http://127.0.0.1:${server.address().port}` })));
}

// ── The page ─────────────────────────────────────────────────────────────────

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    body = body.toString()
      .replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>")
      // Test hooks, after the channels are built: ?throw=plain breaks the build, ?throw=quota
      // makes it throw what a full Storage throws. Pages without the line are left alone.
      .replace(
        "autoGenerateChannels(allItems);",
        "autoGenerateChannels(allItems);\n    if (/[?&]throw=plain/.test(location.search)) throw new Error('test: the build broke');\n"
        + "    if (/[?&]throw=quota/.test(location.search)) throw new DOMException('The quota has been exceeded.', 'QuotaExceededError');",
      );
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const measurements = {};

const browser = await chromium.launch({ headless: true });

/**
 * Opens the tuner signed in to `plexUrl`. `quota` (characters, keys plus values) stands in for a
 * small localStorage; `seed` is written before it is enforced; `initScript` runs first.
 */
async function open(plexUrl, { quota = null, seed = {}, noIndexedDB = false, hangIndexedDB = false, query = "" } = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url, quotaChars, seedData, noIdb, hangIdb]) => {
    const proto = Object.getPrototypeOf(localStorage);
    const realSet = proto.setItem;
    const realGet = proto.getItem;
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      realSet.call(localStorage, "plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "plex", userToken: "t" }));
      for (const [k, v] of Object.entries(seedData)) realSet.call(localStorage, k, v);
    }
    if (quotaChars != null) {
      const used = () => {
        let n = 0;
        for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); n += k.length + (realGet.call(localStorage, k) || "").length; }
        return n;
      };
      proto.setItem = function (k, v) {
        if (this !== localStorage) return realSet.call(this, k, v);
        const before = realGet.call(this, k);
        const delta = (k.length + String(v).length) - (before == null ? 0 : k.length + before.length);
        if (used() + delta > quotaChars) throw new DOMException("The quota has been exceeded.", "QuotaExceededError");
        return realSet.call(this, k, v);
      };
    }
    if (noIdb) Object.defineProperty(window, "indexedDB", { value: undefined, configurable: true });
    if (hangIdb) {
      const real = window.indexedDB;
      Object.defineProperty(window, "indexedDB", {
        configurable: true,
        value: { open: (name, ...rest) => (name === "nostalgex-library" ? ({}) : real.open.call(real, name, ...rest)), databases: () => real.databases() },
      });
    }
  }, [plexUrl, quota, seed, noIndexedDB, hangIndexedDB]);
  const page = await ctx.newPage();
  const started = Date.now();
  const errors = [];
  const consoleLog = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 300)));
  page.on("console", (m) => {
    if (["error", "warning"].includes(m.type())) consoleLog.push(`${m.type()}: ${m.text().slice(0, 300)}`);
    if (VERBOSE) console.error(`  [${((Date.now() - started) / 1000).toFixed(1)}s ${m.type()}] ${m.text().slice(0, 200)}`);
  });
  await page.goto(`${base}/plex-tuner.html${query}`);
  return { ctx, page, errors, consoleLog, started };
}

/** Waits for the load to end, either way. */
async function settle(h, timeoutMs = SETTLE_MS) {
  await h.page.waitForFunction(() => document.getElementById("loading-library").style.display === "flex", null, { timeout: 15000 }).catch(() => {});
  const done = await h.page.waitForFunction(() => {
    const loadingDone = document.getElementById("loading-library").style.display === "none";
    const errorShown = document.getElementById("plex-error-label").style.display === "block";
    return loadingDone || errorShown;
  }, null, { timeout: timeoutMs }).then(() => true).catch(() => false);
  h.ms = Date.now() - h.started;
  await h.page.waitForTimeout(400);
  return done;
}

async function snapshot(page) {
  return page.evaluate(async () => {
    const sizes = {};
    let total = 0;
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      const n = k.length + (localStorage.getItem(k) || "").length;
      sizes[k] = n;
      total += n;
    }
    let idb = null;
    try {
      const dbs = indexedDB.databases ? await indexedDB.databases() : [];
      if (dbs.some((d) => d.name === "nostalgex-library")) {
        idb = await new Promise((resolve) => {
          const open = indexedDB.open("nostalgex-library");
          open.onerror = () => resolve(null);
          open.onsuccess = () => {
            const db = open.result;
            if (!db.objectStoreNames.contains("cache")) { db.close(); resolve(null); return; }
            const get = db.transaction("cache").objectStore("cache").get("library");
            get.onsuccess = () => { db.close(); resolve(get.result ? { id: get.result.id, jsonChars: get.result.json.length } : null); };
            get.onerror = () => { db.close(); resolve(null); };
          };
        });
      }
    } catch (e) { idb = null; }
    return {
      sizes, total, idb,
      loadingDone: document.getElementById("loading-library").style.display === "none",
      errorShown: document.getElementById("plex-error-label").style.display === "block",
      errorText: document.getElementById("plex-error-label").textContent,
      connectShown: document.getElementById("plex-connect").style.display === "flex",
      enabled: typeof CHANNELS !== "undefined" ? CHANNELS.filter((c) => c.enabled).length : -1,
      hasConfig: localStorage.getItem("plex90_channel_config") !== null,
      configChars: (localStorage.getItem("plex90_channel_config") || "").length,
      initialLoadFlag: localStorage.getItem("nostalgex_completed_initial_load"),
      items: typeof allItemsCache !== "undefined" ? allItemsCache.length : -1,
    };
  });
}

/** The quota Chromium really gives this origin, in characters of key plus value. */
async function probeQuota() {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto(`${base}/404.html`);
  const quota = await page.evaluate(() => {
    localStorage.clear();
    const chunk = "x".repeat(1024);
    let n = 0;
    try { for (;;) { localStorage.setItem("probe" + String(n).padStart(6, "0"), chunk); n += 1; } } catch (e) { /* full */ }
    const full = n * (11 + 1024);
    localStorage.clear();
    return full;
  });
  await ctx.close();
  return quota;
}

const unreachableText = (t) => /SERVER MAY BE UNREACHABLE|COULD NOT REACH/.test(t);
const plex = await startPlex(BIG);
const quotaChars = await probeQuota();
measurements.realQuotaChars = quotaChars;

// ── A. The reported library, Chromium's real quota ───────────────────────────
if (scenario("A")) {
  const h = await open(plex.url, { seed: SEED_JUNK_CHARS ? { somebody_elses_data: "z".repeat(SEED_JUNK_CHARS) } : {} });
  const ended = await settle(h);
  let s = await snapshot(h.page);
  // The cache write is not awaited by the page; give it a moment to land.
  for (let i = 0; i < 40 && !s.idb && !s.errorShown; i++) { await h.page.waitForTimeout(250); s = await snapshot(h.page); }
  measurements.A_firstLoad = { ms: h.ms, items: s.items, enabledChannels: s.enabled, localStorageChars: s.total, configChars: s.configChars, hasConfig: s.hasConfig, initialLoadFlag: s.initialLoadFlag, idbJsonChars: s.idb && s.idb.jsonChars, byKeyTop: Object.entries(s.sizes).sort((a, b) => b[1] - a[1]).slice(0, 3), errorText: s.errorText, errorShown: s.errorShown, pageErrors: h.errors.slice(0, 2), consoleErrors: h.consoleLog.filter((m) => /Quota|quota|Library fetch/.test(m)).slice(0, 3) };
  check("A: the load ends", ended, JSON.stringify(s));
  check("A: the error screen never shows", s.errorShown === false, s.errorText);
  check("A: all 6,738 items are in the guide", s.items === BIG.total, `${s.items} of ${BIG.total}`);
  check("A: channels are on the air", s.enabled > 0, String(s.enabled));
  check("A: the channel config was saved", s.hasConfig === true);
  check("A: the first-load flag was saved", s.initialLoadFlag === "1", String(s.initialLoadFlag));
  check("A: localStorage is nowhere near full (headroom for the small settings)", s.total < quotaChars * 0.5, `${s.total} of ${quotaChars}`);
  check("A: no old-style library cache in localStorage", s.sizes.plex90_library_cache === undefined);
  check("A: the whole library is cached in IndexedDB, summaries included", !!s.idb && s.idb.jsonChars > BIG.total * SUMMARY_CHARS, JSON.stringify(s.idb));
  check("A: no uncaught page error", h.errors.length === 0, h.errors.join(" | "));
  check("A: the console never reports a failed save", !h.consoleLog.some((m) => /Could not (save|cache)/.test(m)), h.consoleLog.join(" | "));

  if (FIRST_LOAD_ONLY) { await h.ctx.close(); } else {
  // Back to it: the cache restores the guide and the server is not asked for the library again.
  plex.counts.sectionAll = 0; plex.counts.allLeaves = 0;
  const reloadStarted = Date.now();
  await h.page.reload();
  const ended2 = await settle({ ...h, page: h.page, started: reloadStarted }, SETTLE_MS);
  const s2 = await snapshot(h.page);
  measurements.A_reload = { ms: Date.now() - reloadStarted, items: s2.items, enabledChannels: s2.enabled, sectionRequests: plex.counts.sectionAll, allLeavesRequests: plex.counts.allLeaves };
  check("A reload: the load ends", ended2, JSON.stringify(s2));
  check("A reload: no error screen", s2.errorShown === false, s2.errorText);
  check("A reload: the guide comes from the cache, not the server", plex.counts.sectionAll === 0 && plex.counts.allLeaves === 0, `${plex.counts.sectionAll} section and ${plex.counts.allLeaves} episode requests`);
  check("A reload: the same library is on the air", s2.items === BIG.total && s2.enabled === s.enabled, `${s2.items} items, ${s2.enabled} channels (was ${s.enabled})`);

  // F. Sign-out. The id is the switch: with it gone the cache cannot load, whatever IndexedDB still holds.
  const cleared = await h.page.evaluate((key) => {
    clearLibraryCache();
    return localStorage.getItem(key) === null;
  }, CACHE_ID_KEY);
  check("F: clearing the library cache removes the id at once, before IndexedDB finishes", cleared === true);
  await h.page.waitForTimeout(500);
  await h.page.evaluate(async () => {
    // Put a record back with no id, as a delete that never ran would leave it.
    await new Promise((resolve) => {
      const open = indexedDB.open("nostalgex-library");
      open.onsuccess = () => {
        const tx = open.result.transaction("cache", "readwrite");
        tx.objectStore("cache").put({ id: "left-behind", json: JSON.stringify({ v: 3, ts: Date.now(), url: "x", items: [] }) }, "library");
        tx.oncomplete = () => { open.result.close(); resolve(); };
      };
    });
  });
  plex.counts.sectionAll = 0;
  await h.page.reload();
  await settle({ ...h, page: h.page, started: Date.now() }, SETTLE_MS);
  const s3 = await snapshot(h.page);
  check("F: after clearing, the next visit reads the server again", plex.counts.sectionAll > 0, `${plex.counts.sectionAll} section requests`);
  check("F: and the guide is whole", s3.items === BIG.total && s3.errorShown === false, `${s3.items} items`);
  await h.ctx.close();
  }
}

// ── B. The browser a 1.0.9 tuner left full ───────────────────────────────────
if (scenario("B")) {
  // The old cache key, holding most of the quota, as the old page wrote it.
  const filler = "x".repeat(Math.max(0, quotaChars - 40000));
  const h = await open(plex.url, { seed: { plex90_library_cache: filler } });
  const ended = await settle(h);
  const s = await snapshot(h.page);
  measurements.B_fullBrowser = { ms: h.ms, startedWithLocalStorageChars: filler.length, endedWithLocalStorageChars: s.total, errorShown: s.errorShown, errorText: s.errorText, hasConfig: s.hasConfig };
  check("B: the load ends", ended, JSON.stringify(s));
  check("B: the error screen never shows", s.errorShown === false, s.errorText);
  check("B: the old cache is gone, freeing the quota", s.sizes.plex90_library_cache === undefined, String(s.sizes.plex90_library_cache));
  check("B: the channel config was saved", s.hasConfig === true);
  check("B: the first-load flag was saved", s.initialLoadFlag === "1", String(s.initialLoadFlag));
  check("B: the guide is whole", s.items === BIG.total, `${s.items}`);
  await h.ctx.close();
}

// ── C, D, E use the small library: the storage logic does not depend on its size ──
const small = await startPlex(SMALL);

// ── C. The quota is used up by data the page can rebuild ─────────────────────
if (scenario("C")) {
  // Three kinds of rebuildable data fill the quota to within 3 KB. The page's first big write,
  // the channel config, finds no room and has to take some from them: the cheapest first, and no more
  // than it needs. (The collection scan is written again by the page afterwards, small.)
  const seed = {
    nostalgex_collection_scan: "c".repeat(300000),
    nostalgex_music_video_enrichments_v1: "m".repeat(300000),
    plex90_manifest_junk_1_1: "d".repeat(296000),
  };
  const QUOTA = Object.entries(seed).reduce((n, [k, v]) => n + k.length + v.length, 0) + 3000;
  const h = await open(small.url, { quota: QUOTA, seed });
  const ended = await settle(h);
  const s = await snapshot(h.page);
  measurements.C_rebuildable = { quota: QUOTA, ms: h.ms, hasConfig: s.hasConfig, configChars: s.configChars, sizesAfter: Object.fromEntries(Object.keys(seed).map((k) => [k, s.sizes[k] ?? null])), total: s.total };
  check("C: the load ends", ended, JSON.stringify(s));
  check("C: the error screen never shows", s.errorShown === false, s.errorText);
  check("C: the config needed room (it is bigger than what was free)", s.configChars > 3000, `${s.configChars} chars`);
  check("C: the channel config was saved", s.hasConfig === true, `${s.configChars} chars, ${s.total} of ${QUOTA} used`);
  check("C: the first-load flag was saved", s.initialLoadFlag === "1", String(s.initialLoadFlag));
  check("C: the cheapest cache to lose went first", (s.sizes.nostalgex_collection_scan || 0) < 5000, String(s.sizes.nostalgex_collection_scan));
  check("C: it stopped as soon as there was room (the music cache is whole)", s.sizes.nostalgex_music_video_enrichments_v1 === "nostalgex_music_video_enrichments_v1".length + 300000, String(s.sizes.nostalgex_music_video_enrichments_v1));
  check("C: and so are the manifests", s.sizes.plex90_manifest_junk_1_1 === "plex90_manifest_junk_1_1".length + 296000, String(s.sizes.plex90_manifest_junk_1_1));
  check("C: nothing the page could not rebuild was touched", s.sizes.plex90_saved_auth !== undefined);
  check("C: no uncaught page error", h.errors.length === 0, h.errors.join(" | "));
  await h.ctx.close();
}

// ── D. The quota is used up by data the page cannot rebuild ──────────────────
if (scenario("D")) {
  const QUOTA = 400000;
  const h = await open(small.url, { quota: QUOTA, seed: { somebody_elses_data: "z".repeat(QUOTA - 3000) } });
  const ended = await settle(h);
  const s = await snapshot(h.page);
  measurements.D_nothingToEvict = { quota: QUOTA, ms: h.ms, hasConfig: s.hasConfig, errorShown: s.errorShown, errorText: s.errorText, enabled: s.enabled, console: h.consoleLog.slice(0, 3) };
  check("D: the load ends", ended, JSON.stringify(s));
  check("D: the error screen never shows", s.errorShown === false, s.errorText);
  check("D: nothing says the server is unreachable", !unreachableText(s.errorText), s.errorText);
  check("D: the guide is up", s.enabled > 0 && s.items === SMALL.total, `${s.enabled} channels, ${s.items} items`);
  check("D: what could not be saved stays out of storage, and the other data is untouched", s.sizes.somebody_elses_data === QUOTA - 3000 + "somebody_elses_data".length);
  check("D: the console says what could not be saved", h.consoleLog.some((m) => /Could not save/.test(m)), h.consoleLog.join(" | "));
  check("D: no uncaught page error", h.errors.length === 0, h.errors.join(" | "));
  await h.ctx.close();
}

// ── E. The error screen says what went wrong ─────────────────────────────────
if (scenario("E")) {
  // A server that is not there: the old message, which is true here.
  const down = await open("http://127.0.0.1:9", {});
  await settle(down, 60000);
  const sd = await snapshot(down.page);
  check("E: a server that is down still says it may be unreachable", /YOUR SERVER MAY BE UNREACHABLE/.test(sd.errorText), sd.errorText);
  await down.ctx.close();

  const broken = await open(small.url, { query: "?throw=plain" });
  await settle(broken, 60000);
  const sb = await snapshot(broken.page);
  check("E: a build failure shows the error screen", sb.errorShown === true, JSON.stringify(sb));
  check("E: a build failure does not blame the server", !unreachableText(sb.errorText), sb.errorText);
  check("E: it says the guide could not be built", /GUIDE COULD NOT BE BUILT/.test(sb.errorText), sb.errorText);
  await broken.ctx.close();

  const full = await open(small.url, { query: "?throw=quota" });
  await settle(full, 60000);
  const sq = await snapshot(full.page);
  check("E: a storage failure shows the error screen", sq.errorShown === true, JSON.stringify(sq));
  check("E: a storage failure does not blame the server", !unreachableText(sq.errorText), sq.errorText);
  check("E: it says the browser ran out of storage", /RAN OUT OF STORAGE/.test(sq.errorText), sq.errorText);
  await full.ctx.close();
}

// ── G. No IndexedDB, and an IndexedDB that never answers ─────────────────────
if (scenario("G")) {
  const none = await open(small.url, { noIndexedDB: true });
  const ended = await settle(none);
  const sn = await snapshot(none.page);
  check("G: without IndexedDB the load ends", ended, JSON.stringify(sn));
  check("G: without IndexedDB there is no error and the guide is up", sn.errorShown === false && sn.items === SMALL.total, `${sn.items} items, ${sn.errorText}`);
  check("G: without IndexedDB the channel config is still saved", sn.hasConfig === true);
  small.counts.sectionAll = 0;
  await none.page.reload();
  await settle({ ...none, page: none.page, started: Date.now() }, 60000);
  const sn2 = await snapshot(none.page);
  check("G: without IndexedDB the next visit reads the server (nothing cached, nothing broken)", small.counts.sectionAll > 0 && sn2.errorShown === false && sn2.items === SMALL.total, `${small.counts.sectionAll} requests, ${sn2.errorText}`);
  await none.ctx.close();

  const hang = await open(small.url, { hangIndexedDB: true });
  const hEnded = await settle(hang);
  const sh = await snapshot(hang.page);
  check("G: with a stuck IndexedDB the first load still ends", hEnded && sh.errorShown === false && sh.items === SMALL.total, JSON.stringify({ items: sh.items, err: sh.errorText }));
  const t0 = Date.now();
  await hang.page.reload();
  await settle({ ...hang, page: hang.page, started: t0 }, 60000);
  const sh2 = await snapshot(hang.page);
  measurements.G_stuckIndexedDB = { secondLoadMs: Date.now() - t0 };
  check("G: with a stuck IndexedDB the next visit gives up on the cache and loads", sh2.errorShown === false && sh2.items === SMALL.total, JSON.stringify({ items: sh2.items, err: sh2.errorText }));
  check("G: and does not wait longer than the cache timeout allows", Date.now() - t0 < 25000, `${Date.now() - t0} ms`);
  await hang.ctx.close();
}

await browser.close();
plex.server.close();
small.server.close();
files.close();

if (REPORT) console.log(JSON.stringify({ root, summaryChars: SUMMARY_CHARS, measurements, passed, failed: failures }, null, 2));
if (failures.length) {
  console.error(`storage-quota smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(process.env.EXPECT_FAIL ? 0 : 1);
}
console.log(`storage-quota smoke: ${passed} checks passed`);
