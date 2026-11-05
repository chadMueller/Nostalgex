#!/usr/bin/env node
/**
 * The real plex-tuner.html loads a library from a Plex that refuses a list request with no
 * X-Plex-Container-Size, and reads the long lists whole (Trello N-038).
 *
 * The fake server answers HTTP 400 to any list request without a size, and returns only the
 * window asked for. The library holds 5 films, a long show (750 episodes), a short one and a
 * collection of 650 films. The page has to scan the sections, page every show's episodes and
 * read the collection, with no request refused and nothing cut at the first window.
 * scripts/nostalgex-plex-paging-smoke.mjs checks the same fetchers without a browser; this is
 * the page itself, getters and all.
 *
 * TUNER_ROOT=/path/to/checkout runs it against another checkout (origin/main, to see it fail).
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:plex-container-size`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = process.env.TUNER_ROOT ? resolve(process.env.TUNER_ROOT) : fileURLToPath(new URL("../", import.meta.url));

const media = (n) => [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${n}/file.mp4` }] }];
const movies = Array.from({ length: 5 }, (_, i) => ({
  ratingKey: String(100 + i), title: `Film ${i + 1}`, summary: "", year: 1985 + i, duration: 5400000, type: "movie",
  addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Action" }], Media: media(i),
}));
const shows = [
  { ratingKey: "500", title: "Long Show", type: "show", year: 1990, Genre: [{ tag: "Comedy" }] },
  { ratingKey: "501", title: "Short Show", type: "show", year: 1995, Genre: [{ tag: "Drama" }] },
];
const episodesOf = (count, prefix) => Array.from({ length: count }, (_, i) => ({
  ratingKey: `${prefix}${i + 1}`, title: `Episode ${i + 1}`, duration: 1320000, parentIndex: 1 + Math.floor(i / 25), index: (i % 25) + 1,
  type: "episode", Media: media(i),
}));
const episodes = { "500": episodesOf(750, "ep"), "501": episodesOf(3, "sm") };
const sections = [{ key: "1", title: "Movies", type: "movie" }, { key: "2", title: "TV Shows", type: "show" }];
const bigCollection = Array.from({ length: 650 }, (_, i) => ({ ratingKey: `c${i + 1}` }));

const log = [];
const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  const path = url.pathname;
  res.setHeader("Content-Type", "application/json");
  if (path === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));

  const list =
    path === "/library/sections" ? { key: "Directory", all: sections }
    : path === "/library/sections/1/all" ? { key: "Metadata", all: movies }
    : path === "/library/sections/2/all" ? { key: "Metadata", all: shows }
    : path === "/library/sections/1/collections" ? { key: "Metadata", all: [{ ratingKey: "900", title: "Big Set" }] }
    : path === "/library/sections/2/collections" ? { key: "Metadata", all: [] }
    : path === "/library/collections/900/children" ? { key: "Metadata", all: bigCollection }
    : path.match(/^\/library\/metadata\/(\d+)\/allLeaves$/) ? { key: "Metadata", all: episodes[path.split("/")[3]] || [] }
    : null;
  if (!list) return res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));

  const sizeText = url.searchParams.get("X-Plex-Container-Size") ?? req.headers["x-plex-container-size"];
  const start = Number(url.searchParams.get("X-Plex-Container-Start") ?? req.headers["x-plex-container-start"] ?? 0);
  const entry = { path, start, size: sizeText == null ? null : Number(sizeText) };
  log.push(entry);
  if (sizeText == null || sizeText === "") {
    entry.refused = true;
    res.writeHead(400);
    return res.end(JSON.stringify({ error: "Missing X-Plex-Container-Size header" }));
  }
  const window = list.all.slice(start, start + Number(sizeText));
  res.end(JSON.stringify({ MediaContainer: { size: window.length, offset: start, totalSize: list.all.length, [list.key]: window } }));
});

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  // hls.js is stubbed (nothing plays here), so the page has no reason to reach the CDN.
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

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
await ctx.addInitScript(([url]) => {
  if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
    sessionStorage.setItem("nx-seeded", "1");
    localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "plex", userToken: "t" }));
  }
}, [api]);
const page = await ctx.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
await page.goto(`${base}/plex-tuner.html`);
const wanted = movies.length + episodes["500"].length + episodes["501"].length;
await page.waitForFunction((n) => typeof allItemsCache !== "undefined" && allItemsCache.length >= n, wanted, { timeout: 30000 }).catch(() => {});
await page.waitForFunction(() => typeof rawCollections !== "undefined" && rawCollections && rawCollections.length > 0, null, { timeout: 15000 }).catch(() => {});
await page.waitForTimeout(500);
const state = await page.evaluate(() => ({
  items: allItemsCache.length,
  longShowEpisodes: allItemsCache.filter((i) => i.showKey === "500").length,
  shortShowEpisodes: allItemsCache.filter((i) => i.showKey === "501").length,
  errorShown: document.getElementById("plex-error-label") ? document.getElementById("plex-error-label").style.display === "block" : false,
  collections: (typeof rawCollections !== "undefined" && rawCollections || []).map((c) => ({ title: c.title, keys: c.childKeys.length })),
}));
await browser.close();
plex.close();
files.close();

const refused = log.filter((l) => l.refused);
check("no list request went without a size", refused.length === 0, `${refused.length} of ${log.length} refused: ${[...new Set(refused.map((l) => l.path))].join(", ")}`);
check("the library loads, no error screen", state.errorShown === false);
check("all 758 items are in the guide (5 films, 750 + 3 episodes)", state.items === wanted, `${state.items} of ${wanted}`);
check("the 750-episode show is read whole", state.longShowEpisodes === 750, String(state.longShowEpisodes));
check("the short show is read", state.shortShowEpisodes === 3, String(state.shortShowEpisodes));
check("the 650-film collection is read whole", JSON.stringify(state.collections) === JSON.stringify([{ title: "Big Set", keys: 650 }]), JSON.stringify(state.collections));
check("the long show took three windows", log.filter((l) => l.path === "/library/metadata/500/allLeaves").map((l) => l.start).join() === "0,300,600",
  log.filter((l) => l.path === "/library/metadata/500/allLeaves").map((l) => l.start).join());
check("no page errors", errors.length === 0, errors.join(" | "));

if (failures.length) {
  console.error(`plex-container-size smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`plex-container-size smoke: ${passed} checks passed (${log.length} list requests, none without a size)`);
