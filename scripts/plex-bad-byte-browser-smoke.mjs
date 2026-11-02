#!/usr/bin/env node
/**
 * A Plex title with a byte that is not UTF-8 keeps its accent (issue #125).
 *
 * Plex copies a file or folder name into its JSON byte for byte, so an unmatched item named
 * in Latin-1 puts a lone 0xE9 into the title. `Response.json()` decodes UTF-8 with
 * replacement characters, so the web tuner loaded the library but showed "Caf� Society".
 * The Apple TV repairs this (PlexResponseDecoding.swift, 1.0.27): every byte outside a
 * well-formed UTF-8 sequence is read as Windows-1252, a valid response is untouched.
 *
 * This loads the real plex-tuner.html, headless, against a Plex-shaped server whose library page
 * holds raw bad bytes, and reads the titles the tuner kept. Negative control: the same page
 * with the repair taken out, which must show the replacement character.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:plex-bad-byte`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

// Titles as raw bytes. "@E9@" style markers are swapped for the byte after JSON encoding.
const BAD = { "@E9@": 0xe9, "@93@": 0x93, "@94@": 0x94, "@E2@": 0xe2 };
const movie = (n, title, summary = "") => ({
  ratingKey: String(100 + n), title, summary, year: 1985 + n, duration: 5400000, type: "movie",
  addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Action" }],
  Media: [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${n}/file.mp4` }] }],
});
const metadata = [
  movie(1, "Caf@E9@ Society"),
  movie(2, "Say @93@Hello@94@", "A line with a lone @E9@ in the summary"),
  movie(3, "Amélie"),                 // valid UTF-8: must come through untouched
  movie(4, "Crème Br@E9@lée"),  // valid and bad bytes in one title
  movie(5, "Cut Off @E2@"),                // a truncated sequence at the end of the title
  movie(6, "Plain Title"),
];
const pageBytes = (() => {
  const json = JSON.stringify({ MediaContainer: { size: metadata.length, totalSize: metadata.length, Metadata: metadata } });
  const parts = [];
  let rest = Buffer.from(json, "utf8");
  for (;;) {
    let at = -1, marker = null;
    for (const m of Object.keys(BAD)) { const i = rest.indexOf(m); if (i >= 0 && (at < 0 || i < at)) { at = i; marker = m; } }
    if (at < 0) { parts.push(rest); break; }
    parts.push(rest.subarray(0, at), Buffer.from([BAD[marker]]));
    rest = rest.subarray(at + marker.length);
  }
  return Buffer.concat(parts);
})();

const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const path = req.url.split("?")[0];
  res.setHeader("Content-Type", "application/json");
  if (path === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
  if (path === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }] } }));
  if (path === "/library/sections/1/all") return res.end(pageBytes);
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  // hls.js is stubbed (nothing plays here), so the page has no reason to reach the CDN.
  if (p.endsWith("plex-tuner.html")) body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  // ?norepair: the page reading Plex pages the way it did before the repair, for the negative control.
  if (req.url.includes("norepair")) {
    const text = body.toString();
    const plain = text.replace(/<script src="scripts\/nostalgex-utf8-repair\.js"><\/script>/, "<script>window.NostalgexUTF8Repair = { json: (res) => res.json() };</script>");
    if (plain === text && !process.env.ALLOW_MISSING) { res.writeHead(500); return res.end("repair script tag not found"); }
    body = plain;
  }
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
async function load(query = "") {
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
  await page.goto(`${base}/plex-tuner.html${query}`);
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length > 0, null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1000);
  const state = await page.evaluate(() => ({
    count: allItemsCache.length,
    titles: allItemsCache.map((i) => i.title),
    summaries: allItemsCache.map((i) => i.summary),
    pageHasReplacement: document.body.innerText.includes("�"),
  }));
  await ctx.close();
  return { state, errors };
}

const fixed = await load();
const t = fixed.state.titles;
check("all six items load", fixed.state.count === 6, JSON.stringify(fixed.state));
check("a lone 0xE9 reads as e acute", t.includes("Café Society"), JSON.stringify(t));
check("0x93 and 0x94 read as curly quotes", t.includes("Say “Hello”"), JSON.stringify(t));
check("valid UTF-8 comes through untouched", t.includes("Amélie"), JSON.stringify(t));
check("valid and bad bytes in one title", t.includes("Crème Brélée"), JSON.stringify(t));
check("a truncated sequence is repaired, not dropped", t.includes("Cut Off â"), JSON.stringify(t));
check("a summary is repaired too", fixed.state.summaries.includes("A line with a lone é in the summary"), JSON.stringify(fixed.state.summaries));
check("no replacement character in any title or on the page", !t.join("").includes("�") && !fixed.state.pageHasReplacement);
check("no page errors", fixed.errors.length === 0, fixed.errors.join(" | "));

const control = await load("?norepair");
check("negative control: without the repair the title shows a replacement character", control.state.titles.some((x) => x.includes("�")), JSON.stringify(control.state.titles));

await browser.close();
plex.close();
files.close();
if (failures.length) {
  console.error(`plex-bad-byte smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`plex-bad-byte smoke: ${passed} checks passed (six titles, valid and bad bytes, and the negative control)`);
