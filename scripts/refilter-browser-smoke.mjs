#!/usr/bin/env node
/**
 * The launch-time refilter (GitHub #294), in the real plex-tuner.html (headless), against a Plex-shaped
 * stub with a synthetic library and a Supabase-shaped stub that holds an enrichment row for every title.
 *
 * What it does:
 *   1. Loads the page cold: the library is read from the stub, enrichment reads its rows from the Supabase
 *      stub and fills the browser's cache (IndexedDB), and `onCacheReady` runs the refilter.
 *   2. Reloads the page: the library comes back from the saved copy and every title is a local cache hit,
 *      which is the launch the issue measured.
 *   3. For each of the two, records every long task (PerformanceObserver `longtask`, over 50 ms) and which of
 *      them fall inside a call to refilterChannelsWithEnrichment(), however it is written (a plain call or
 *      one that gives the page back between slices): the call is wrapped from outside, so the same script
 *      runs against origin/main and against a branch.
 *   4. Fingerprints every channel's pool (count and a hash of the titles in order), the guide's lineup and
 *      the franchise channels, so a before and an after can be compared byte for byte:
 *        OUT=/path/before.json  node scripts/refilter-browser-smoke.mjs     (run on origin/main)
 *        COMPARE=/path/before.json  node scripts/refilter-browser-smoke.mjs  (run on the branch)
 *
 * Settings (environment): N=<titles> (default 10700), ALL_BUNDLES=1 switches all 14 bundles on,
 * THROTTLE=<n> slows the CPU n times (4 is a rough Google TV), TUNER_ROOT=/path runs another checkout,
 * NO_BEAT=1 drops the timer heartbeat (its 4 ms wake-ups cost time of their own; use it to read the total time),
 * MAX_TASK_MS=<ms> turns the longest long task inside the refilter into a check (off by default; the
 * default run reports it).
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable
 * `playwright`. Run: `npm run test:refilter:browser`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = process.env.TUNER_ROOT ? resolve(process.env.TUNER_ROOT) : fileURLToPath(new URL("../", import.meta.url));
const N = Number(process.env.N || 10700);
const ALL_BUNDLES = !!process.env.ALL_BUNDLES;
const THROTTLE = Number(process.env.THROTTLE || 1);
const MAX_TASK_MS = process.env.MAX_TASK_MS ? Number(process.env.MAX_TASK_MS) : null;
const WAIT_MS = Number(process.env.WAIT_MS || 600000);
const NO_BEAT = !!process.env.NO_BEAT;   // no timer heartbeat: its wake-ups slow the pass, so the wall time is read without it

// ── The Plex stub's library: 3 titles in 4 are films, 1 in 4 episodes of 25-episode shows. ──
const GENRES = ["Action", "Comedy", "Drama", "Thriller", "Horror", "Romance", "Science Fiction", "Adventure", "Animation", "Family", "Crime", "Mystery", "War", "Western", "Documentary", "Music", "Fantasy"];
const CERTS = ["G", "PG", "PG-13", "R", "NC-17", "", "TV-14", "TV-MA", "TV-Y"];
const STUDIOS = ["Universal Pictures", "Warner Bros.", "Paramount Pictures", "20th Century Fox", "", "Miramax"];
const FILMS = Math.floor(N * 3 / 4);
const SHOWS = Math.ceil((N - FILMS) / 25);
const noRuntime = (i) => i % 97 === 5;
const media = (i) => [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${i}/file.mp4` }] }];
const film = (i) => ({
  ratingKey: String(1000 + i), title: `Film ${(i * 7919) % 9973}`, summary: `Summary ${i}. ` + "A story about a small town. ".repeat(8), year: i % 11 === 0 ? undefined : 1950 + (i % 75),
  duration: noRuntime(i) ? 0 : (80 + (i % 100)) * 60000, type: "movie", addedAt: 1600000000 + i, contentRating: CERTS[i % CERTS.length] || undefined,
  rating: i % 4 === 0 ? undefined : 4 + (i % 50) / 10, studio: STUDIOS[i % STUDIOS.length] || undefined,
  Genre: i % 13 === 0 ? [] : [{ tag: GENRES[i % GENRES.length] }, { tag: GENRES[(i * 5 + 1) % GENRES.length] }],
  Guid: i % 5 === 0 ? [] : [{ id: `tmdb://${5000 + i}` }], Media: media(i),
});
const show = (s) => ({ ratingKey: String(900000 + s), title: `Show ${s}`, type: "show", year: 1960 + (s % 60), contentRating: CERTS[s % CERTS.length] || undefined, Genre: [{ tag: GENRES[s % GENRES.length] }], summary: "A show.", Guid: [{ id: `tmdb://${70000 + s}` }] });
const episodes = (s) => Array.from({ length: s === SHOWS - 1 ? (N - FILMS) - 25 * (SHOWS - 1) : 25 }, (_, e) => {
  const i = FILMS + s * 25 + e;
  return { ratingKey: String(2000000 + i), title: `Episode ${i}`, duration: noRuntime(i) ? 0 : (20 + (i % 40)) * 60000, parentIndex: 1 + Math.floor(e / 12), index: (e % 12) + 1, type: "episode", Media: media(i), addedAt: 1600000000 + i };
});
const sections = [{ key: "1", title: "Movies", type: "movie" }, { key: "2", title: "TV Shows", type: "show" }];

// ── The Supabase stub: one enrichment row per TMDB id, with keywords, networks and companies taken from the
//    channel rules themselves so that enrichment moves real channels. ──
const lineup = JSON.parse(readFileSync(join(root, "channels.json"), "utf8"));
const pool = { keywords: new Set(), networks: new Set(), productionCompanies: new Set() };
for (const ch of lineup.channels || []) {
  for (const k of Object.keys(pool)) for (const v of (ch.rules && ch.rules[k]) || []) pool[k].add(String(v).toLowerCase());
}
const KW = [...pool.keywords].sort(), NW = [...pool.networks].sort(), PC = [...pool.productionCompanies].sort();
const mix = (n) => { let x = (n * 2654435761) >>> 0; x ^= x >>> 15; x = Math.imul(x, 2246822519) >>> 0; x ^= x >>> 13; return x >>> 0; };
const pick = (list, n, count) => (list.length ? Array.from({ length: count }, (_, j) => list[mix(n * 31 + j) % list.length]) : []);
function enrichmentRow(id) {
  const n = Number(id);
  const m = mix(n);
  return {
    tmdb_id: Number(id), media_type: n >= 70000 ? "tv" : "movie", imdb_id: null,
    keywords: pick(KW, n, m % 4), networks: n >= 70000 ? pick(NW, n, m % 2) : [], production_companies: pick(PC, n, (m >> 3) % 3),
    tmdb_genres: [GENRES[m % GENRES.length], GENRES[(m >> 5) % GENRES.length]],
    franchise_id: m % 9 === 0 ? 100 + (m % 40) : null, franchise_name: m % 9 === 0 ? `Lab Collection ${m % 40}` : null,
    fetched_at: "2026-11-01T00:00:00Z",
  };
}

// The pages of a real server come back in whatever order the connections finish, so the library's own order differs
// between two loads, and the franchise and collection pass is order-sensitive. The stub answers in a fixed order (a
// delay by page and by show) so that two loads of the same code end with the same pools and a before and an after
// can be compared.
const later = (ms) => new Promise((r) => setTimeout(r, ms));
const api = http.createServer(async (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  res.setHeader("Content-Type", "application/json");
  if (url.pathname === "/sb/rest/v1/media_enrichments") {
    if (req.method !== "GET") { res.writeHead(201); return res.end(); }
    const m = (url.searchParams.get("tmdb_id") || "").match(/^in\.\((.*)\)$/);
    return res.end(JSON.stringify((m ? m[1].split(",").filter(Boolean) : []).map(enrichmentRow)));
  }
  if (url.pathname === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
  if (url.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: sections } }));
  const page = (total, make) => {
    const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0);
    const size = Number(url.searchParams.get("X-Plex-Container-Size") || total);
    const rows = [];
    for (let i = start; i < Math.min(total, start + size); i++) rows.push(make(i));
    return JSON.stringify({ MediaContainer: { size: rows.length, totalSize: total, Metadata: rows } });
  };
  if (url.pathname === "/library/sections/1/all" || url.pathname === "/library/sections/2/all") {
    const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0), size = Number(url.searchParams.get("X-Plex-Container-Size") || 1);
    await later(Math.floor(start / size) * 25);
    return res.end(url.pathname.endsWith("/1/all") ? page(FILMS, film) : page(SHOWS, show));
  }
  const leaves = url.pathname.match(/^\/library\/metadata\/(\d+)\/allLeaves$/);
  if (leaves) {
    const idx = Number(leaves[1]) - 900000;
    await later(idx * 6);
    const eps = episodes(idx);
    return res.end(JSON.stringify({ MediaContainer: { size: eps.length, totalSize: eps.length, Metadata: eps } }));
  }
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
let apiBase = "";
// Wraps the page's refilter from outside, after the page's own script has declared it and before anything
// asynchronous has run, so a plain call and one that gives the page back between slices are both timed.
const WRAP = `<script>(function(){var o=window.refilterChannelsWithEnrichment;if(typeof o!=="function")return;window.__refilter=[];
window.__beats=[];if(!${NO_BEAT ? 1 : 0})setInterval(function(){window.__beats.push(performance.now());},4);
window.refilterChannelsWithEnrichment=function(){var rec={start:performance.now(),end:null,result:null};window.__refilter.push(rec);
var r=o.apply(this,arguments);Promise.resolve(r).then(function(v){rec.end=performance.now();rec.result=v;},function(e){rec.end=performance.now();rec.error=String(e);});return r;};})();</script>`;
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    body = body.toString()
      .replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>")
      .replace("%VITE_SUPABASE_URL%", `${apiBase}/sb`).replace("%VITE_SUPABASE_ANON_KEY%", "lab-anon-key").replace("%VITE_TMDB_RELAY_URL%", `${apiBase}/relay`)
      .replace(/<\/body>/i, `${WRAP}</body>`);
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => api.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
apiBase = `http://127.0.0.1:${api.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true, args: ["--js-flags=--max-old-space-size=6000"] });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
await ctx.addInitScript(([url, allBundles]) => {
  if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
    sessionStorage.setItem("nx-seeded", "1");
    localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "plex", userToken: "t" }));
    if (allBundles) localStorage.setItem("nostalgex_enabled_bundles", JSON.stringify(["nostalgex", "kids", "truecrime", "essentials", "premium", "arthouse", "adventureland", "sports", "decades", "franchises", "streamers", "seasonal", "tis-the-season", "high-rotation"]));
  }
  window.__long = [];
  try { new PerformanceObserver((l) => window.__long.push(...l.getEntries().map((e) => ({ at: e.startTime, ms: e.duration })))).observe({ entryTypes: ["longtask"] }); } catch (e) {}
}, [apiBase, ALL_BUNDLES]);
const page = await ctx.newPage();
const cdp = await ctx.newCDPSession(page);
if (THROTTLE > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: THROTTLE });
const errors = [];
page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
const logs = [];
page.on("console", (m) => { if (/\[Enrichment\]/.test(m.text())) logs.push(m.text().slice(0, 160)); });

/** Waits for the library, the enrichment records and a finished refilter, then for a quiet stretch. */
async function settle(label) {
  await page.waitForFunction((n) => typeof allItemsCache !== "undefined" && allItemsCache.length > n * 0.95, N, { timeout: WAIT_MS });
  await page.waitForFunction(() => window.__refilter && window.__refilter.length > 0 && window.__refilter.every((r) => r.end !== null) && enrichmentRecords && enrichmentRecords.size > 0, null, { timeout: WAIT_MS });
  await page.waitForTimeout(2500);
  // Anything that started late (the final refilter after a relay fetch) has to be done too.
  await page.waitForFunction(() => window.__refilter.every((r) => r.end !== null), null, { timeout: WAIT_MS });
  return label;
}

/**
 * Every channel's pool as "count:on|off:members hash:order hash", plus the lineup. The stub answers in a fixed order,
 * so two loads of the same code agree on both hashes; the members hash alone says which titles are on the channel,
 * the order hash that they come in the order of the library.
 */
async function fingerprint() {
  return page.evaluate(() => {
    const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return h.toString(16).padStart(8, "0"); };
    const pools = {};
    for (const ch of allChannelsUnfiltered) {
      // The rating key alone: the stub's address (and so poolMemberKey) is a different port on every run.
      const keys = (ch.itemPool || []).map((it) => String(it.ratingKey));
      pools[ch.id] = `${keys.length}:${ch.enabled ? "on" : "off"}:${fnv(keys.slice().sort().join(","))}:${fnv(keys.join(","))}`;
    }
    return { pools, lineup: CHANNELS.map((c) => c.id).join(","), channels: allChannelsUnfiltered.length, items: allItemsCache.length, enriched: allItemsCache.filter((it) => it.enrichment).length };
  });
}

/**
 * In one page, the order and the members of every pool the refilter built against the old way: the whole library
 * through filterItems in one pass. The same library, the same enrichment, so any difference is the new code's.
 */
async function liveCheck() {
  return page.evaluate(() => {
    const LL = globalThis.NostalgexLibraryLoad;
    const poolIDs = LL.staticChannelIDsForPoolBuild({ buildAll: false, bundles, enabledBundleIDs, allChannelsUnfiltered });
    const out = { compared: 0, mismatched: [], sliced: typeof filterItemsSliced === "function", slicedCompared: 0, slicedMismatched: [], stale: [] };
    const same = (want, have, withVia) => {
      if (want.length !== have.length) return false;
      for (let i = 0; i < want.length; i++) if (poolMemberKey(want[i]) !== poolMemberKey(have[i]) || (withVia && want[i].poolVia !== have[i].poolVia)) return false;
      return true;
    };
    return (async () => {
      for (const ch of allChannelsUnfiltered) {
        if (isRuntimeChannel(ch) || !ch.rules) continue;
        const want = filterItems(allItemsCache, ch.rules, ch.id, ch.category);
        // The new filter against the old one, on this library: member, order and the way each title got in.
        if (out.sliced) {
          const got = await filterItemsSliced(allItemsCache, ch.rules, ch.id, ch.category, NostalgexSlicedFilter.makeSlicer({ sliceMs: 0 }), Math.floor(Date.now() / 1000));
          out.slicedCompared++;
          if (!got || !same(want, got, true)) out.slicedMismatched.push(`${ch.id} ${ch.name}: ${got ? got.length : "cancelled"} vs ${want.length}`);
        }
        // What the launch left in the pool against the old one-pass filter, for the pools it built. A pool whose
        // members did not change is kept as it was (samePoolMembers), so it can carry an older order or "via".
        const have = rulePoolOf(ch);
        if (!poolIDs.has(ch.id) && have.length === 0) continue;
        out.compared++;
        if (!same(want, have, false)) out.mismatched.push(`${ch.id} ${ch.name}: ${have.length} vs ${want.length}`);
        else if (!same(want, have, true)) out.stale.push(`${ch.id} ${ch.name}`);
      }
      return out;
    })();
  });
}

async function readCosts() {
  return page.evaluate(() => {
    const calls = window.__refilter.map((r) => ({ start: r.start, end: r.end, ms: r.end - r.start, result: r.result, error: r.error || null }));
    const inside = window.__long.filter((t) => calls.some((c) => t.at < c.end && t.at + t.ms > c.start));
    const all = window.__long;
    // The longest the main thread went without running a 4 ms timer between the start and the end of a refilter
    // call: the call itself counts as one gap when it never gave the page back.
    let gap = 0, beatsIn = 0;
    for (const c of calls) {
      const pts = [c.start, ...window.__beats.filter((t) => t > c.start && t < c.end), c.end];
      beatsIn += pts.length - 2;
      for (let i = 1; i < pts.length; i++) gap = Math.max(gap, pts[i] - pts[i - 1]);
    }
    const sum = (a) => Math.round(a.reduce((s, t) => s + t.ms, 0));
    return {
      calls: calls.map((c) => ({ ms: Math.round(c.ms), changed: c.result, error: c.error })),
      beatGapMs: Math.round(gap), beats: beatsIn,
      insideLongTasks: inside.length, insideLongest: Math.round(Math.max(0, ...inside.map((t) => t.ms))), insideTotal: sum(inside),
      allLongTasks: all.length, allLongest: Math.round(Math.max(0, ...all.map((t) => t.ms))), allTotal: sum(all),
    };
  });
}

const runs = {};
await page.goto(`${base}/plex-tuner.html`);
await settle("cold");
runs.cold = { cost: await readCosts(), fp: await fingerprint() };
await page.reload();
await settle("launch with the cache filled");
runs.launch = { cost: await readCosts(), fp: await fingerprint() };
runs.launch.live = await liveCheck();

for (const [name, r] of Object.entries(runs)) {
  console.log(`MEASURE ${name} (N=${N}, bundles ${ALL_BUNDLES ? "all" : "default"}, cpu x${THROTTLE}): refilter calls ${JSON.stringify(r.cost.calls)}; ${NO_BEAT ? "heartbeat off;" : `main thread unavailable at most ${r.cost.beatGapMs} ms between 4 ms timer beats (${r.cost.beats} beats) while it ran;`} long tasks inside the refilter ${r.cost.insideLongTasks} (longest ${r.cost.insideLongest} ms, ${r.cost.insideTotal} ms total); on the whole page ${r.cost.allLongTasks} (longest ${r.cost.allLongest} ms)`);
}
const L = runs.launch;
check("the library loaded", L.fp.items > N * 0.95, String(L.fp.items));
check("enrichment attached to the titles", L.fp.enriched > L.fp.items * 0.5, `${L.fp.enriched} of ${L.fp.items}`);
check("the refilter ran on the launch with the cache filled", L.cost.calls.length >= 1 && L.cost.calls.every((c) => !c.error), JSON.stringify(L.cost.calls));
check("the refilter moved some channels (the stub's enrichment bites)", L.cost.calls.some((c) => c.changed > 0), JSON.stringify(L.cost.calls));
console.log(`MEASURE live: ${L.live.compared} pools built at launch checked against the old one-pass filter: ${L.live.mismatched.length} differ in members or order, ${L.live.stale.length} keep an older "via" (${L.live.stale.slice(0, 4).join(", ")}); new filter ${L.live.sliced ? `compared on ${L.live.slicedCompared} channels, ${L.live.slicedMismatched.length} differ` : "not present"}`);
if (L.live.sliced) check(`the new filter returns the old filter's rows on every rules channel: members, order and "via" (${L.live.slicedCompared} channels)`, L.live.slicedCompared > 100 && L.live.slicedMismatched.length === 0, L.live.slicedMismatched.slice(0, 5).join(" | "));
check(`the pools the launch built hold the old filter's members, in its order (${L.live.compared} channels)`, L.live.compared > 20 && L.live.mismatched.length === 0, L.live.mismatched.slice(0, 5).join(" | "));
// (A cold load and a restored launch do not end with the same pools: the first build fills every channel's pool,
// a restored one only those of the bundles that are on. That is by design, so each is compared to its own before.)
if (MAX_TASK_MS !== null) check(`no long task inside the refilter over ${MAX_TASK_MS} ms`, L.cost.insideLongest <= MAX_TASK_MS, `${L.cost.insideLongest} ms`);
check("no page errors", errors.length === 0, errors.join(" | "));

if (process.env.OUT) {
  writeFileSync(process.env.OUT, JSON.stringify({ n: N, allBundles: ALL_BUNDLES, launch: L.fp, cold: runs.cold.fp }, null, 1));
  console.log(`fingerprint written: ${process.env.OUT}`);
}
if (process.env.COMPARE) {
  const before = JSON.parse(readFileSync(process.env.COMPARE, "utf8"));
  check("the comparison file was made with the same N and bundles", before.n === N && before.allBundles === ALL_BUNDLES, `${before.n}/${before.allBundles} vs ${N}/${ALL_BUNDLES}`);
  for (const run of ["cold", "launch"]) {
    const was = before[run], now = runs[run].fp;
    const diffs = [], orderDiffs = [];
    const head = (v) => String(v).split(":").slice(0, 3).join(":");
    for (const id of new Set([...Object.keys(was.pools), ...Object.keys(now.pools)])) {
      if (head(was.pools[id]) !== head(now.pools[id])) diffs.push(`channel ${id}: ${was.pools[id]} -> ${now.pools[id]}`);
      else if (was.pools[id] !== now.pools[id]) orderDiffs.push(`channel ${id}`);
    }
    check(`${run}: every channel's pool (${Object.keys(now.pools).length}) holds the same titles as before, and the same on/off`, diffs.length === 0, diffs.slice(0, 5).join(" | ") + (diffs.length > 5 ? ` (+${diffs.length - 5} more)` : ""));
    check(`${run}: every pool lists them in the same order as before`, orderDiffs.length === 0, orderDiffs.slice(0, 8).join(", ") + (orderDiffs.length > 8 ? ` (+${orderDiffs.length - 8} more)` : ""));
    check(`${run}: the guide's lineup is identical`, was.lineup === now.lineup);
    check(`${run}: the same titles were enriched`, was.enriched === now.enriched && was.items === now.items, `${was.enriched}/${was.items} vs ${now.enriched}/${now.items}`);
  }
}

// What interrupts a refilter, and what it does about it (the branch's refilter is async; origin/main's is one synchronous
// pass, so these only run where there is a sliced filter to interrupt). Each case starts from a few channels whose pools
// have been cut back, so the refilter has real work in both steps: it finds them changed and writes them back.
const conc = await page.evaluate(async () => {
  if (typeof filterItemsSliced !== "function") return null;
  const fnv = (a) => { const t = a.slice().sort().join(","); let h = 0x811c9dc5; for (let i = 0; i < t.length; i++) { h ^= t.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return h; };
  const keysOf = (ch) => rulePoolOf(ch).map((it) => String(it.ratingKey));
  const snap = () => JSON.stringify(allChannelsUnfiltered.map((ch) => [ch.id, (ch.itemPool || []).length, !!ch.enabled]));
  const victims = allChannelsUnfiltered.filter((ch) => !isRuntimeChannel(ch) && ch.rules && rulePoolOf(ch).length >= 100).slice(0, 5);
  const want = victims.map((ch) => [ch.id, fnv(keysOf(ch))]);
  const cutBack = () => victims.forEach((ch) => setRulePool(ch, rulePoolOf(ch).slice(0, Math.ceil(rulePoolOf(ch).length * 0.8))));
  const restored = () => victims.every((ch, i) => fnv(keysOf(ch)) === want[i][1]);
  const out = { victims: victims.length, franchisesBefore: foundFranchises.length };

  // 1. Two overlapping refilters: the older one stops without writing, the newer one answers. Nothing to change.
  const was = snap();
  const first = refilterChannelsWithEnrichment();
  const second = refilterChannelsWithEnrichment();
  const [r1, r2] = await Promise.all([first, second]);
  Object.assign(out, { r1, r2, unchangedByTwo: was === snap() });

  // 2. The library's array is replaced by a copy of itself while the refilter works, as MusicBrainz display metadata
  //    does after tune-in (itemsWithDisplayMetadata). The same library, so the refilter runs again on the new array and
  //    writes the pools back from its rows: the same members, and rows that carry what the new array carries.
  cutBack();
  let attempts = 0;
  const EN = globalThis.NostalgexEnrichment, attach = EN.attach;
  EN.attach = (...a) => { attempts++; return attach.apply(EN, a); };
  const third = refilterChannelsWithEnrichment();
  allItemsCache = allItemsCache.map((it) => ({ ...it, nxDisplay: 1 }));
  const r3 = await third;
  Object.assign(out, { r3, attempts3: attempts, restored3: restored(), rowsFromNewArray: victims.every((ch) => rulePoolOf(ch).length > 0 && rulePoolOf(ch).every((it) => it.nxDisplay === 1)) });

  // 3. Replaced again on every try: it gives up after three and writes nothing.
  cutBack();
  const cut = snap();
  attempts = 0;
  EN.attach = (...a) => { attempts++; const r = attach.apply(EN, a); queueMicrotask(() => { allItemsCache = allItemsCache.map((it) => ({ ...it })); }); return r; };
  const r4 = await refilterChannelsWithEnrichment();
  Object.assign(out, { r4, attempts4: attempts, unwrittenAfterGiveUp: cut === snap() });
  EN.attach = attach;

  // 4. A new library (the extras generation moves) while step one works: it stops for good and writes nothing.
  const fifth = refilterChannelsWithEnrichment();
  libraryExtrasGeneration++;
  allItemsCache = allItemsCache.slice();
  const r5 = await fifth;
  Object.assign(out, { r5, unwrittenAfterNewLibrary: cut === snap() });

  // 5. Settle the pools again, then sign out while step two is giving the page back between schedules. Its first
  //    schedule takes long enough to use up the slice, and the sign-out lands in the microtask after the give-back
  //    begins, before the refilter resumes. It must not build the next schedule or put the franchises back.
  cutBack();
  await refilterChannelsWithEnrichment();
  out.restored5 = restored();
  cutBack();
  const build = buildChannelSchedule, dyn = refreshDynamicChannels, apply = applyBundleFilter;
  // signOut() rebuilds schedules itself, and the page's own once-a-second tick rebuilds them while step one runs, so
  // the trap is armed by step two itself (it calls applyBundleFilter just before its schedule loop) and the builds
  // made inside signOut() are left out of the count.
  let armed = false, trapped = false, signedOut = false, inSignOut = false, buildsAfter = 0, dynAfter = 0;
  applyBundleFilter = function (...a) { if (!trapped) armed = true; return apply.apply(this, a); };
  buildChannelSchedule = function (...a) {
    if (signedOut && !inSignOut) buildsAfter++;
    if (armed && !trapped) {
      trapped = true;
      const t = performance.now(); while (performance.now() - t < 20) { /* use the slice up */ }
      queueMicrotask(() => { signedOut = true; inSignOut = true; try { signOut(); } finally { inSignOut = false; } });
    }
    return build.apply(this, a);
  };
  refreshDynamicChannels = function (...a) { if (signedOut) dynAfter++; return dyn.apply(this, a); };
  const r6 = await refilterChannelsWithEnrichment();
  buildChannelSchedule = build; refreshDynamicChannels = dyn; applyBundleFilter = apply;
  Object.assign(out, { r6, trapped, buildsAfter, dynAfter, signedOut, franchisesAfter: foundFranchises.length });
  return out;
});
if (conc) {
  console.log(`MEASURE interrupts: ${JSON.stringify(conc)}`);
  check("the interrupt cases start from channels with real work (5 pools cut back) and franchises found", conc.victims === 5 && conc.franchisesBefore > 0, JSON.stringify({ victims: conc.victims, franchises: conc.franchisesBefore }));
  check("a refilter overtaken by a newer one stops without writing", conc.r1 === null && typeof conc.r2 === "number", JSON.stringify({ r1: conc.r1, r2: conc.r2 }));
  check("two overlapping refilters over unchanged data leave every pool as it was", conc.unchangedByTwo);
  check("the library's array replaced by a copy (MusicBrainz display metadata): it runs again and answers", typeof conc.r3 === "number" && conc.attempts3 === 2, JSON.stringify({ r3: conc.r3, attempts: conc.attempts3 }));
  check("and the pools come back with the same members, from the rows of the new array", conc.restored3 && conc.rowsFromNewArray, JSON.stringify({ restored: conc.restored3, rows: conc.rowsFromNewArray }));
  check("replaced on every try: it gives up after three tries and writes nothing", conc.r4 === null && conc.attempts4 === 3 && conc.unwrittenAfterGiveUp, JSON.stringify({ r4: conc.r4, attempts: conc.attempts4, unwritten: conc.unwrittenAfterGiveUp }));
  check("and says so in the console", logs.some((l) => /Refilter gave up/.test(l)), logs.join(" | ").slice(0, 200));
  check("a new library while step one works stops it for good and writes nothing", conc.r5 === null && conc.unwrittenAfterNewLibrary, JSON.stringify({ r5: conc.r5 }));
  check("a refilter settles pools that were cut back (the sign-out case's starting point)", conc.restored5);
  check("a sign-out after step two's first give-back stops it: null, no schedule built after, no franchise pass after, no franchises put back", conc.trapped && conc.signedOut && conc.r6 === null && conc.buildsAfter === 0 && conc.dynAfter === 0 && conc.franchisesAfter === 0, JSON.stringify({ r6: conc.r6, trapped: conc.trapped, buildsAfter: conc.buildsAfter, dynAfter: conc.dynAfter, franchises: conc.franchisesAfter }));
  check("no page errors after those", errors.length === 0, errors.join(" | "));
}

await browser.close();
api.close();
files.close();
if (failures.length) {
  console.error(`refilter browser: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`refilter browser: ${passed} checks passed (${N} titles)`);
process.exit(0);
