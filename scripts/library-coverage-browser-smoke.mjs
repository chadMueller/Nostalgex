#!/usr/bin/env node
/**
 * The library line in Settings, in the real plex-tuner.html (headless), against a Plex-shaped stub
 * with a synthetic library: movies from section pages, episodes from per-show lists, and a few
 * titles with no runtime. It checks:
 *   - the SERVER tab of Settings shows the line, in the Apple TV's wording, once the count is done
 *     (and not before there is a library);
 *   - the numbers are those of a plain loop over the same channels with the same filter, run in
 *     the page over the library the page holds;
 *   - the skipped count is exactly the titles the stub gave no runtime (each counted once);
 *   - the count and the skipped count are still there after a reload, from the saved library;
 *   - a COVERAGE line is in the console with the titles on no channel;
 *   - signing out takes the line away.
 * N=<titles> sets the size (default 3000). MEASURE=1 prints what the count cost the page: the longest
 * stretch the main thread was busy while it ran (a long task), how many, the time it took, and the
 * JS heap before and after, for the size asked. The equality check is left out above 20,000 titles,
 * because the plain loop is itself the freeze this count avoids.
 * Negative control: TUNER_ROOT=/path runs another checkout (origin/main), which has no line.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:library-coverage:browser`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = process.env.TUNER_ROOT ? resolve(process.env.TUNER_ROOT) : fileURLToPath(new URL("../", import.meta.url));
const N = Number(process.env.N || 3000);
const MEASURE = !!process.env.MEASURE;
const WAIT_MS = Number(process.env.WAIT_MS || 600000);   // how long to wait for the library and for the count

// ── The stub's library: 3 titles in 4 are films in one section, 1 in 4 episodes of 25-episode shows. ──
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
const skippedTitles = Array.from({ length: FILMS }, (_, i) => i).filter(noRuntime).length
  + Array.from({ length: N - FILMS }, (_, k) => FILMS + k).filter(noRuntime).length;
const sections = [{ key: "1", title: "Movies", type: "movie" }, { key: "2", title: "TV Shows", type: "show" }];

const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  res.setHeader("Content-Type", "application/json");
  if (url.pathname === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
  if (url.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: sections } }));
  const page = (total, make) => {
    const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0);
    const size = Number(url.searchParams.get("X-Plex-Container-Size") || total);
    const rows = [];
    for (let i = start; i < Math.min(total, start + size); i++) rows.push(make(i));
    return JSON.stringify({ MediaContainer: { size: rows.length, totalSize: total, Metadata: rows } });
  };
  if (url.pathname === "/library/sections/1/all") return res.end(page(FILMS, film));
  if (url.pathname === "/library/sections/2/all") return res.end(page(SHOWS, show));
  const leaves = url.pathname.match(/^\/library\/metadata\/(\d+)\/allLeaves$/);
  if (leaves) { const eps = episodes(Number(leaves[1]) - 900000); return res.end(JSON.stringify({ MediaContainer: { size: eps.length, totalSize: eps.length, Metadata: eps } })); }
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => plex.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${plex.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true, args: ["--js-flags=--max-old-space-size=6000"] });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
await ctx.addInitScript(([url]) => {
  if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
    sessionStorage.setItem("nx-seeded", "1");
    localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "plex", userToken: "t" }));
  }
  window.__long = [];
  try { new PerformanceObserver((l) => window.__long.push(...l.getEntries().map((e) => ({ at: e.startTime, ms: e.duration })))).observe({ entryTypes: ["longtask"] }); } catch (e) {}
}, [api]);
const page = await ctx.newPage();
const cdp = await ctx.newCDPSession(page);
await cdp.send("Performance.enable");
const heapMB = async () => { const m = (await cdp.send("Performance.getMetrics")).metrics.find((x) => x.name === "JSHeapUsedSize"); return m ? m.value / 1048576 : -1; };
const consoleLines = [];
page.on("console", (m) => { if (/COVERAGE:/.test(m.text())) consoleLines.push(m.text()); });
const errors = [];
page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));

let peakHeap = 0;
const sampler = setInterval(async () => { try { peakHeap = Math.max(peakHeap, await heapMB()); } catch (e) {} }, 1000);
const t0 = Date.now();
await page.goto(`${base}/plex-tuner.html`);
await page.waitForFunction((n) => typeof allItemsCache !== "undefined" && allItemsCache.length >= n, N - skippedTitles, { timeout: WAIT_MS }).catch(() => {});
const loadedMs = Date.now() - t0;
// The count starts a moment after the library is built; wait for the line.
await page.waitForFunction(() => typeof libraryCoverage !== "undefined" && libraryCoverage !== null, null, { timeout: WAIT_MS }).catch(() => {});
const countedMs = Date.now() - t0;
clearInterval(sampler);

const state = await page.evaluate(() => ({
  items: allItemsCache.length,
  line: document.getElementById("cfg-library-coverage") ? document.getElementById("cfg-library-coverage").textContent : null,
  shown: document.getElementById("cfg-library-coverage-wrap") ? document.getElementById("cfg-library-coverage-wrap").style.display !== "none" : null,
  skipped: librarySkippedNoRuntime,
  coverage: libraryCoverage ? { loaded: libraryCoverage.loaded, onChannels: libraryCoverage.onChannels } : null,
}));
check("the library loads without the zero-runtime titles", state.items === N - skippedTitles, `${state.items} of ${N - skippedTitles}`);
check("the skipped count is the titles with no runtime, once each", state.skipped === skippedTitles, `${state.skipped} vs ${skippedTitles}`);
check("the Settings line is there, in the Apple TV's wording", !!state.line && /^[\d,]+ OF [\d,]+ ON CHANNELS/.test(state.line) && state.line.includes(`${skippedTitles.toLocaleString("en-US")} SKIPPED (NO RUNTIME)`), JSON.stringify(state.line));
check("the line is shown in Settings", state.shown === true);
check("a COVERAGE line is in the console", consoleLines.some((l) => /COVERAGE: \d+ of \d+ on a channel/.test(l) && /Not on any channel/.test(l)), consoleLines.join(" | ").slice(0, 200));

if (N <= 20000 && state.coverage) {
  const plain = await page.evaluate(() => {
    const CF = channelFilter();
    const nowSec = Math.floor(Date.now() / 1000);
    const covered = new Set();
    for (const ch of allChannelsUnfiltered) {
      if (!ch.rules || isRuntimeChannel(ch)) continue;
      const channel = { id: ch.id, rules: ch.rules, category: ch.category };
      const pool = allItemsCache.filter((it) => CF.itemPasses(it, channel, { manifest: channelMembershipManifest, exclusiveRules, backend: mediaBackend, nowSec }) !== false);
      if (pool.length >= (ch.minItems || 50)) for (const it of pool) covered.add(poolMemberKey(it));
    }
    for (const ch of allChannelsUnfiltered) if (isRuntimeChannel(ch)) for (const it of (ch.itemPool || [])) covered.add(poolMemberKey(it));
    const onChannels = {}, loaded = {};
    for (const it of allItemsCache) {
      const k = globalThis.NostalgexLibraryCoverage.kindOf(it);
      loaded[k] = (loaded[k] || 0) + 1;
      if (covered.has(poolMemberKey(it))) onChannels[k] = (onChannels[k] || 0) + 1;
    }
    return { loaded, onChannels };
  });
  check("the numbers are those of a plain loop over the library the page holds", JSON.stringify(plain.loaded) === JSON.stringify(state.coverage.loaded) && JSON.stringify(plain.onChannels) === JSON.stringify(state.coverage.onChannels), JSON.stringify({ plain, page: state.coverage }));
}

// What the count costs the page: run it again with nothing else going on.
let cost = null;
if (MEASURE) {
  await page.evaluate(() => { window.__long.length = 0; });
  const heapBefore = await heapMB();
  cost = await page.evaluate(async () => {
    let maxGap = 0, last = performance.now(), beats = 0;
    const beat = setInterval(() => { const t = performance.now(); maxGap = Math.max(maxGap, t - last); last = t; beats += 1; }, 10);
    const started = performance.now();
    libraryCoverage = null;
    await runLibraryCoverage();
    const elapsed = performance.now() - started;
    clearInterval(beat);
    return { elapsedMs: Math.round(elapsed), maxGapMs: Math.round(maxGap), beats, longTasks: window.__long.map((l) => Math.round(l.ms)) };
  });
  cost.heapBeforeMB = Math.round(heapBefore);
  cost.heapAfterMB = Math.round(await heapMB());
}

// Reload: the line comes back from the saved library.
await page.reload();
await page.waitForFunction(() => typeof libraryCoverage !== "undefined" && libraryCoverage !== null, null, { timeout: WAIT_MS }).catch(() => {});
const reloaded = await page.evaluate(() => ({ line: document.getElementById("cfg-library-coverage").textContent, skipped: librarySkippedNoRuntime }));
check("after a reload the skipped count is still there", reloaded.skipped === skippedTitles, String(reloaded.skipped));
check("after a reload the line is back", reloaded.line === state.line, JSON.stringify([reloaded.line, state.line]));

// A library saved by an older scan (no scanRevision) is restored and read again; a current one is not stale.
const staleness = await page.evaluate(async () => {
  const saved = await NostalgexStorage.libraryCache.load();
  const items = saved.items;
  const url = saved.url;
  const current = { v: saved.v, ts: Date.now(), url, items, skippedNoRuntime: 0, scanRevision: saved.scanRevision };
  const older = { v: saved.v, ts: Date.now(), url, items, skippedNoRuntime: 0 };
  await NostalgexStorage.libraryCache.save(current);
  const a = await loadLibraryCache(true);
  await NostalgexStorage.libraryCache.save(older);
  const b = await loadLibraryCache(true);
  const c = await loadLibraryCache(false);
  return { currentRevision: saved.scanRevision, currentStale: a && a.stale, olderStale: b && b.stale, olderKeptWithoutAllowStale: c };
});
check("a library saved by this scan is current", staleness.currentRevision >= 1 && staleness.currentStale === false, JSON.stringify(staleness));
check("a library saved by an older scan is restored, then read again", staleness.olderStale === true && staleness.olderKeptWithoutAllowStale === null, JSON.stringify(staleness));

// Sign out: the line goes.
const afterSignOut = await page.evaluate(() => { signOut(); return { line: document.getElementById("cfg-library-coverage").textContent, shown: document.getElementById("cfg-library-coverage-wrap").style.display !== "none", cov: libraryCoverage }; });
check("signing out takes the line away", afterSignOut.line === "" && afterSignOut.shown === false && afterSignOut.cov === null, JSON.stringify(afterSignOut));
check("no page errors", errors.length === 0, errors.join(" | "));

await browser.close();
plex.close();
files.close();
if (MEASURE) {
  console.log(`MEASURE N=${N}: library built in ${(loadedMs / 1000).toFixed(1)} s, line shown at ${(countedMs / 1000).toFixed(1)} s; peak JS heap while loading ${Math.round(peakHeap)} MB`);
  console.log(`MEASURE count again: ${JSON.stringify(cost)}`);
  console.log(`MEASURE line: ${state.line}`);
}
if (failures.length) {
  console.error(`library coverage browser: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`library coverage browser: ${passed} checks passed (${N} titles)`);
process.exit(0);
