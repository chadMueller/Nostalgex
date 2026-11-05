#!/usr/bin/env node
/**
 * The Deezer genre lookup runs under the site's Content-Security-Policy (Trello N-012).
 *
 * api.deezer.com has no CORS headers, so scripts/nostalgex-music-brainz.js asks it with JSONP:
 * it adds a <script src="https://api.deezer.com/...?callback=..."> and waits for the callback.
 * That load is governed by script-src, not connect-src. vercel.json's script-src once allowed
 * only 'self', 'unsafe-inline', cdn.jsdelivr.net and statsngraphs.lol, so on the hosted tuner
 * the browser refused the script (script-src-elem violation), the lookup threw "Deezer script
 * error", and the music video genres Deezer is meant to fill in never arrived.
 *
 * This serves the real plex-tuner.html with the Content-Security-Policy taken from vercel.json,
 * answers api.deezer.com with a JSONP reply of its own (so the test needs no network and does
 * not depend on Deezer), and calls NostalgexMusicBrainz.deezerResolve. The browser applies the
 * policy before any request is made, so a refused script never reaches the stub.
 * Negative control: the same header with api.deezer.com taken out must refuse the script.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:deezer-csp`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

const csp = JSON.parse(readFileSync(join(root, "vercel.json"), "utf8")).headers
  .flatMap((h) => h.headers).find((h) => h.key === "Content-Security-Policy").value;
const withoutDeezer = csp.replace(" https://api.deezer.com", "");

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const policies = { site: csp, nodeezer: withoutDeezer };
const files = http.createServer((req, res) => {
  const [, mode, ...rest] = decodeURIComponent(req.url.split("?")[0]).split("/");
  const p = normalize(join(root, rest.join("/")));
  if (!(mode in policies) || !p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  // hls.js is stubbed (nothing plays here), so the page has no reason to reach the CDN.
  if (p.endsWith("plex-tuner.html")) body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream", "Content-Security-Policy": policies[mode] });
  res.end(body);
});
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });

async function lookup(mode) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await ctx.addInitScript(() => {
    window.__violations = [];
    document.addEventListener("securitypolicyviolation", (e) => {
      window.__violations.push({ blocked: e.blockedURI.split("?")[0], directive: e.effectiveDirective });
    });
  });
  // Only the localhost page and Deezer's own host are let through; Deezer is answered here.
  const deezerRequests = [];
  await ctx.route((u) => u.hostname !== "127.0.0.1", async (route) => {
    const url = new URL(route.request().url());
    if (url.hostname !== "api.deezer.com") return route.abort();
    deezerRequests.push(url.pathname);
    const cb = url.searchParams.get("callback");
    const reply = url.pathname === "/search"
      ? { data: [{ id: 1, title: "Song", artist: { name: "Band" }, album: { id: 77 } }] }
      : { genres: { data: [{ name: "Rock" }] }, release_date: "1991-09-24" };
    await route.fulfill({ status: 200, contentType: "application/javascript", body: `${cb}(${JSON.stringify(reply)});` });
  });
  const page = await ctx.newPage();
  await page.goto(`${base}/${mode}/plex-tuner.html`);
  const result = await page.evaluate(async () => {
    try {
      const r = await window.NostalgexMusicBrainz.deezerResolve("Song", "Band");
      return { ok: true, genres: r && r.genres, year: r && r.releaseYear };
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) };
    }
  });
  const violations = (await page.evaluate(() => window.__violations)).filter((v) => /deezer/.test(v.blocked));
  await ctx.close();
  return { result, violations, deezerRequests };
}

const allowed = await lookup("site");
check("vercel.json CSP: the Deezer lookup resolves", allowed.result.ok === true, JSON.stringify(allowed.result));
check("vercel.json CSP: it read the album genre and year", JSON.stringify(allowed.result.genres) === '["Rock"]' && allowed.result.year === 1991, JSON.stringify(allowed.result));
check("vercel.json CSP: no script was refused", allowed.violations.length === 0, JSON.stringify(allowed.violations));

const refused = await lookup("nodeezer");
check("negative control, header without api.deezer.com: the script is refused", refused.violations.length > 0 && refused.violations[0].directive === "script-src-elem", JSON.stringify(refused.violations));
check("negative control: the lookup throws a script error", refused.result.ok === false && /Deezer script error/.test(refused.result.error), JSON.stringify(refused.result));
check("negative control: the browser never made the request", refused.deezerRequests.length === 0, JSON.stringify(refused.deezerRequests));

await browser.close();
files.close();
if (failures.length) {
  console.error(`deezer-csp smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`deezer-csp smoke: ${passed} checks passed (lookup resolves under the site CSP; refused without api.deezer.com)`);
