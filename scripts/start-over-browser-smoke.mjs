#!/usr/bin/env node
/**
 * The real page, headless, against a Jellyfin-shaped server whose library scan never answers:
 * START OVER shows on the loading screen, clicking it lands on web-tuner.html with the saved
 * login gone, and opening the tuner again starts no library load. Negative control: the same
 * page with the button taken out stays on the loading screen with nothing to click but the
 * coffee and the channel buttons.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:start-over:browser`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

// The stuck server: answers the sign-in check and the library list, never the items.
const scanRequests = [];
const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const path = req.url.split("?")[0];
  if (path.endsWith("/Items")) { scanRequests.push(path); return; }
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ Id: "u", Name: "u", ServerName: "stuck", Version: "10.11.0", ProductName: "Jellyfin Server",
    Items: [{ Id: "lib", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
});
// The tuner's files, as the Docker image serves them (plain http, so a local server is reachable).
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  // ?nobutton: the page with START OVER taken out, for the negative control. Served from here
  // rather than rewritten in the browser, which would change how Chromium treats its requests.
  let body = readFileSync(p);
  if (req.url.includes("nobutton")) body = body.toString().replace(/<button[^>]*id="loading-library-start-over"[\s\S]*?<\/button>/, "");
  res.end(body);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${server.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });
async function stuckPage(viewport, { withoutButton = false } = {}) {
  const ctx = await browser.newContext(viewport);
  await ctx.addInitScript(([url]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "stuck", backend: "jellyfin", jellyfinUserId: "u" }));
    }
  }, [api]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`${base}/plex-tuner.html${withoutButton ? "?nobutton" : ""}`);
  await page.waitForFunction(() => document.getElementById("loading-library")?.offsetParent !== null, null, { timeout: 15000 });
  await page.waitForTimeout(3000);
  return { ctx, page, errors };
}

for (const [name, viewport] of [["TV 960x540", { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 }],
  ["phone 390x844", { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true }]]) {
  const before = scanRequests.length;
  const { ctx, page, errors } = await stuckPage(viewport);
  check(`${name}: the scan is stuck`, scanRequests.length > before);
  const button = page.locator("#loading-library-start-over");
  check(`${name}: START OVER is on screen`, await button.isVisible());
  const box = await button.boundingBox();
  const vp = page.viewportSize();
  check(`${name}: START OVER fits the screen`, box && box.y >= 0 && box.y + box.height <= vp.height && box.x >= 0 && box.x + box.width <= vp.width, JSON.stringify(box));
  await button.click();
  await page.waitForURL(/web-tuner\.html/, { timeout: 10000 });
  check(`${name}: lands on the sign-in page`, /web-tuner\.html/.test(page.url()));
  check(`${name}: the saved login is gone`, (await page.evaluate(() => localStorage.getItem("plex90_saved_auth"))) === null);
  const afterOut = scanRequests.length;
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForTimeout(4000);
  check(`${name}: opening the tuner again starts no library load`, scanRequests.length === afterOut, `${scanRequests.length - afterOut} scan requests`);
  check(`${name}: no page errors`, errors.length === 0, errors.join("; "));
  await ctx.close();
}

// Negative control: no button, no way out.
{
  const neg = await stuckPage({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 }, { withoutButton: true });
  // What a click can actually reach: on screen and on top at its centre.
  const clickable = await neg.page.evaluate(() => [...document.querySelectorAll("button, a")].filter((e) => {
    const r = e.getBoundingClientRect();
    if (!r.width || !r.height || r.bottom < 0 || r.top > innerHeight) return false;
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return hit && (hit === e || e.contains(hit));
  }).map((e) => e.innerText.replace(/\s+/g, " ").trim()).filter(Boolean));
  check("negative control: the page without the button is the one served", (await neg.page.locator("#loading-library-start-over").count()) === 0);
  check("negative control: without the button the page stays on the loading screen with no way to sign in",
    (await neg.page.locator("#loading-library").isVisible()) && !clickable.some((t) => /START OVER|SIGN|DISCONNECT|CONNECT/i.test(t)), clickable.join(", "));
  await neg.ctx.close();
}

await browser.close();
server.close();
files.close();
if (failures.length) {
  console.error(`start over (browser): ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`start over (browser): ${passed} passed, at 960x540 and 390x844, with the negative control`);
