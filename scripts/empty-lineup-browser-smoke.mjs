#!/usr/bin/env node
/**
 * A first lineup that comes out empty falls back to every package with content (issue #124).
 *
 * The Apple TV does this (AppState+Channels.swift `autoEnableBundlesWithContent`) and Roku 1.0.6
 * does too. The web tuner did not: a small library, or one that fits no NOSTALGEX channel,
 * opened on a blank screen. This loads the real plex-tuner.html, headless, against a
 * Jellyfin-shaped server holding a library of a given shape:
 *   - 20 documentary films (the lab "docs" user): no NOSTALGEX channel fills, ESSENTIALS has one;
 *   - 2 documentary films (the lab "nofit" user): the same, with only just enough;
 *   - 6 films from 1985 to 1995: VHS VAULT fills on its own, so nothing else is switched on;
 *   - one film nothing matches: no package has content, so nothing is switched on.
 * Negative control: the same page with the fallback call taken out, which must leave the 20-film
 * library with no channel. Seasonal packages are never switched on (unit-tested in
 * nostalgex-library-load-smoke.mjs).
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:empty-lineup`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

// PREMIERES wants films added in the last 14 days, so the default is "now", not a fixed date.
const film = (n, name, year, genres, rating, added = new Date().toISOString()) => ({
  Id: `film${n}`, Name: name, Type: "Movie", ProductionYear: year, Genres: genres, OfficialRating: rating || null,
  RunTimeTicks: 900000000, ProviderIds: {}, Studios: [], DateCreated: added,
  MediaSources: [{ Id: `film${n}`, Container: "mp4", RunTimeTicks: 900000000, Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 640, Height: 360, Index: 0, IsDefault: true }] }],
});
const libraries = {
  twenty: Array.from({ length: 20 }, (_, i) => film(i, `Case File ${i + 1}`, 1991 + (i % 20), ["Documentary", "Crime"], "TV-14")),
  two: [film(1, "Lonely Reel", 2001, ["Documentary"]), film(2, "Second Reel", 2001, ["Documentary"])],
  vhs: Array.from({ length: 6 }, (_, i) => film(i, `Tape ${i + 1}`, 1985 + i * 2, ["Action"], "R")),
  nothing: [film(1, "Odd One", 2023, ["Western"], null, "2020-01-01T00:00:00.0000000Z")],
};

let current = libraries.twenty;
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  const url = req.url;
  if (url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
  if (url.startsWith("/UserViews")) return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.includes("IncludeItemTypes=Movie")) return res.end(JSON.stringify({ Items: current, TotalRecordCount: current.length }));
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  // hls.js is stubbed (nothing plays here), so the page has no reason to reach the CDN.
  if (p.endsWith("plex-tuner.html")) body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  // ?nofix: the page with the fallback call taken out, for the negative control.
  if (req.url.includes("nofix")) {
    const text = body.toString();
    const stripped = text.replace("if (buildAll) autoEnableBundlesWithContent();", "");
    if (stripped === text) { res.writeHead(500); return res.end("fallback call not found"); }
    body = stripped;
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => jellyfin.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${jellyfin.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });
async function load(library, query = "") {
  current = library;
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  // Only the two local servers are reachable: no CDN, no metadata lookups.
  // Only the two local servers are reachable: no CDN, no metadata lookups.
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
    }
  }, [api]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  if (process.env.LOGS) page.on("console", (m) => console.log("  [console]", m.text().slice(0, 200)));
  await page.goto(`${base}/plex-tuner.html${query}`);
  // The library is read once the page has restored its login; give the build time to settle.
  await page.waitForFunction(() => typeof appState !== "undefined" && localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  const state = await page.evaluate(() => ({
    app: appState,
    withContent: CHANNELS.filter((c) => c.enabled).length,
    bundlesOn: [...enabledBundleIDs],
    saved: localStorage.getItem("nostalgex_enabled_bundles"),
  }));
  await ctx.close();
  return { state, errors };
}

const twenty = await load(libraries.twenty);
check("20 films: a channel is built", twenty.state.withContent >= 1, JSON.stringify(twenty.state));
check("20 films: ESSENTIALS is switched on and kept", twenty.state.bundlesOn.includes("essentials") && /essentials/.test(twenty.state.saved || ""), JSON.stringify(twenty.state));
check("20 films: only packages with content were added", twenty.state.bundlesOn.every((id) => ["nostalgex", "essentials", "truecrime"].includes(id)), JSON.stringify(twenty.state.bundlesOn));
check("20 films: no seasonal package is switched on", !twenty.state.bundlesOn.some((id) => ["seasonal", "tis-the-season"].includes(id)), JSON.stringify(twenty.state.bundlesOn));
check("20 films: no page errors", twenty.errors.length === 0, twenty.errors.join(" | "));

const two = await load(libraries.two);
check("2 films: a channel is built", two.state.withContent >= 1, JSON.stringify(two.state));
check("2 films: ESSENTIALS is switched on", two.state.bundlesOn.includes("essentials"), JSON.stringify(two.state));

const vhs = await load(libraries.vhs);
check("6 films that fill VHS VAULT: a channel is built", vhs.state.withContent >= 1, JSON.stringify(vhs.state));
check("6 films that fill VHS VAULT: nothing else is switched on", vhs.state.bundlesOn.length === 1 && vhs.state.bundlesOn[0] === "nostalgex" && vhs.state.saved === null, JSON.stringify(vhs.state));

const nothing = await load(libraries.nothing);
check("a film nothing matches: no package is switched on and none is saved", nothing.state.bundlesOn.length === 1 && nothing.state.saved === null, JSON.stringify(nothing.state));

const control = await load(libraries.twenty, "?nofix");
check("negative control: without the fallback the 20-film library has no channel", control.state.withContent === 0 && control.state.bundlesOn.length === 1, JSON.stringify(control.state));

await browser.close();
jellyfin.close();
files.close();
if (failures.length) {
  console.error(`empty-lineup smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`empty-lineup smoke: ${passed} checks passed (20, 2 and 6 film libraries, one nothing matches, and the negative control)`);
