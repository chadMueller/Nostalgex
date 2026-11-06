#!/usr/bin/env node
/**
 * A Plex section that fails no longer takes the guide with it, and a scan that reads nothing is
 * an error, not an empty guide (the Apple TV's 1.0.30 rule, N-039).
 *
 * The real plex-tuner.html, headless, against a Plex-shaped stub whose sections can fail. It
 * checks, each in a fresh browser:
 *   - one of two sections answers 500: the other's films load, there is no error screen, and the
 *     library is not saved as if it were whole (the next visit reads it again);
 *   - both answer 500: the page shows its error and not the "no content" screen;
 *   - a section answers 401: the scan ends with the error, as a lost sign-in should;
 *   - a healthy server loads both sections and the library is saved.
 * The Jellyfin and Emby side is scripts/nostalgex-scan-failures-smoke.mjs.
 * Negative control: TUNER_ROOT=/path runs another checkout (origin/main), which must fail.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:plex-section-failures`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = process.env.TUNER_ROOT ? resolve(process.env.TUNER_ROOT) : fileURLToPath(new URL("../", import.meta.url));

const film = (key, n) => ({
  ratingKey: String(key), title: `Film ${key}`, summary: "", year: 1985 + (n % 10), duration: 5400000, type: "movie",
  addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Action" }],
  Media: [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${key}/file.mp4` }] }],
});
const sections = [{ key: "1", title: "Movies", type: "movie" }, { key: "2", title: "Classics", type: "movie" }];
const held = { "1": Array.from({ length: 6 }, (_, i) => film(100 + i, i)), "2": Array.from({ length: 4 }, (_, i) => film(200 + i, i)) };

let plan = {};   // section key -> HTTP status for its pages
const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  res.setHeader("Content-Type", "application/json");
  if (url.pathname === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
  if (url.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: sections } }));
  const all = url.pathname.match(/^\/library\/sections\/(\d+)\/all$/);
  if (all) {
    const status = plan[all[1]] || 200;
    if (status !== 200) { res.writeHead(status); return res.end("{}"); }
    const list = held[all[1]];
    const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0);
    const size = Number(url.searchParams.get("X-Plex-Container-Size") || list.length);
    return res.end(JSON.stringify({ MediaContainer: { size: list.slice(start, start + size).length, totalSize: list.length, Metadata: list.slice(start, start + size) } }));
  }
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

const browser = await chromium.launch({ headless: true });
async function visit(failing) {
  plan = failing;
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "plex", userToken: "t" }));
    }
  }, [api]);
  const page = await ctx.newPage();
  const logs = [];
  page.on("console", (m) => { if (m.type() === "warning") logs.push(m.text()); });
  await page.goto(`${base}/plex-tuner.html`);
  // Done = items in the guide, or the error line, or the empty screen.
  await page.waitForFunction(() =>
    (typeof allItemsCache !== "undefined" && allItemsCache.length > 0)
    || document.getElementById("plex-error-label").style.display === "block"
    || document.getElementById("plex-empty").style.display === "flex", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  const state = await page.evaluate(async () => ({
    items: typeof allItemsCache !== "undefined" ? allItemsCache.length : -1,
    errorShown: document.getElementById("plex-error-label").style.display === "block",
    errorText: document.getElementById("plex-error-label").textContent,
    emptyShown: document.getElementById("plex-empty").style.display === "flex",
    saved: !!(await NostalgexStorage.libraryCache.load().catch(() => null)),
  }));
  await ctx.close();
  return { ...state, logs };
}

const healthy = await visit({});
check("healthy: both sections load (10 films)", healthy.items === 10, String(healthy.items));
check("healthy: no error, no empty screen", !healthy.errorShown && !healthy.emptyShown);
check("healthy: the library is saved", healthy.saved === true);

const oneLost = await visit({ "2": 500 });
check("one section lost: the other section's 6 films load", oneLost.items === 6, String(oneLost.items));
check("one section lost: no error screen", !oneLost.errorShown && !oneLost.emptyShown, oneLost.errorText);
check("one section lost: the library is not saved as whole", oneLost.saved === false);
check("one section lost: the loss is named in the console", oneLost.logs.some((l) => /lost 1 section/.test(l) && /Classics/.test(l)), JSON.stringify(oneLost.logs.slice(-3)));

const allLost = await visit({ "1": 500, "2": 500 });
check("every section lost: the error line shows", allLost.errorShown === true, JSON.stringify({ items: allLost.items, empty: allLost.emptyShown }));
check("every section lost: not the 'no content' screen", allLost.emptyShown === false);
check("every section lost: nothing is saved", allLost.saved === false);

const refused = await visit({ "1": 401, "2": 401 });
check("sign-in refused: the error line shows", refused.errorShown === true, JSON.stringify({ items: refused.items, empty: refused.emptyShown }));
check("sign-in refused: not the 'no content' screen", refused.emptyShown === false);

await browser.close();
plex.close();
files.close();
if (failures.length) {
  console.error(`plex section failures: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`plex section failures: ${passed} checks passed`);
process.exit(0);
