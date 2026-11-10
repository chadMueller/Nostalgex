#!/usr/bin/env node
/**
 * The Docker tuner's shared lineup (I-080), in a browser, headless: the real selfhost build
 * (`vite build --mode selfhost`, the same output the Docker image serves) against a stand-in for
 * the container's one file, nostalgex-settings.json, which answers GET and PUT the way
 * docker/40-config.sh's nginx location does (and 404/405/500 the ways it can fail). The hosted
 * page (the repo's plex-tuner.html, no selfhost marker) runs against the same stand-in.
 *
 *   - A fresh browser starts from the container's lineup: the packages that are on, before the
 *     page's own script reads them. Display preferences and the login stay the browser's own.
 *   - Opening the page writes nothing. After a tap and a change, one PUT carries the shared keys
 *     and nothing else: no login, no token, no display preference. A third browser then has it.
 *   - Nothing saved yet: the browser's own lineup is used, and its first change saves it.
 *   - An image without the feature (404 with no mark), a read that failed (500), a newer file, a
 *     missing or read-only volume (PUT refused): the page works as it did and no browser writes
 *     over what it could not read; a refused write is tried three times and then left alone.
 *   - Hosted: no request to the file at all, nothing changed in the browser.
 *
 * Not run here: nginx. docker-smoke (.github/workflows/ci.yml, on a pull request) runs the real
 * image and does the same GET and PUT with curl.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:shared-lineup`. Headless only.
 */
import http from "node:http";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

// The selfhost build, into a folder of its own.
const dist = mkdtempSync(join(tmpdir(), "nx-selfhost-"));
execFileSync(join(root, "node_modules/.bin/vite"), ["build", "--mode", "selfhost", "--outDir", dist], { cwd: root, stdio: "pipe" });

const TOKEN = "TOKEN-secret-1234567890";
const SHARED = {
  nostalgex_enabled_bundles: JSON.stringify(["nostalgex", "sports"]),
  nostalgex_enabled_franchises: JSON.stringify(["bond"]),
};
const FILE = "/nostalgex-settings.json";

// ---- the stand-in container ----
let dropModule = false;
const box = { mode: "on", file: null, gets: 0, puts: [], other: [] };
const reset = (mode, file = null) => { Object.assign(box, { mode, file, gets: 0, puts: [], other: [] }); };
const container = http.createServer((req, res) => {
  const url = req.url.split("?")[0];
  if (url !== FILE) { box.other.push(`${req.method} ${url}`); res.writeHead(404); return res.end(); }
  const mark = box.mode === "plain404" ? {} : { "X-Nostalgex-Settings": "on" };
  const send = (status, body = "", type = "application/json") => { res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-cache", ...mark }); res.end(body); };
  if (req.method === "GET") {
    box.gets += 1;
    if (box.mode === "plain404") return send(404);
    if (box.mode === "broken") return send(500);
    if (box.mode === "newer") return send(200, JSON.stringify({ v: 9, keys: {} }));
    return box.file === null ? send(404) : send(200, box.file);
  }
  if (req.method === "PUT") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      box.puts.push(body);
      if (box.mode === "readonly" || box.mode === "broken" || box.mode === "plain404" || box.mode === "newer") return send(box.mode === "plain404" ? 405 : 500);
      box.file = body;
      send(204);
    });
    return;
  }
  send(405);
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
// The page's files with the container's file in the same origin, as nginx serves them.
const site = (dir) => http.createServer((req, res) => {
  if (req.url.split("?")[0] === FILE) return container.emit("request", req, res);
  let p = normalize(join(dir, decodeURIComponent(req.url.split("?")[0])));
  if (!extname(p) && existsSync(p + ".html")) p += ".html";
  if (!p.startsWith(dir) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (dropModule && p.endsWith("nostalgex-server-settings.js")) body = Buffer.from("");   // the negative control
  if (p.endsWith("plex-tuner.html")) body = Buffer.from(body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>").replace(/<script src="vendor\/hls[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>"));
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
const selfhostSite = site(dist);
const hostedSite = site(root);
await new Promise((r) => selfhostSite.listen(0, "127.0.0.1", r));
await new Promise((r) => hostedSite.listen(0, "127.0.0.1", r));
const selfhost = `http://127.0.0.1:${selfhostSite.address().port}`;
const hosted = `http://127.0.0.1:${hostedSite.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms) { const end = Date.now() + ms; while (Date.now() < end) { if (fn()) return true; await wait(100); } return fn(); }

const browser = await chromium.launch({ headless: true });
const TV = { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 };
const PHONE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true };

/** A new browser (empty storage unless `seed`), on `base`. Returns once the page has loaded. */
async function open(base, viewport, seed = {}) {
  const ctx = await browser.newContext(viewport);
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  await ctx.addInitScript(([s]) => {
    if (!sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      for (const [k, v] of Object.entries(s.local)) localStorage.setItem(k, v);
      for (const [k, v] of Object.entries(s.session)) sessionStorage.setItem(k, v);
    }
  }, [{ local: seed.local || {}, session: seed.session || {} }]);
  const page = await ctx.newPage();
  const errors = [];
  const warnings = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  page.on("console", (m) => { if (m.type() === "warning") warnings.push(m.text()); });
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForTimeout(800);
  return { ctx, page, errors, warnings };
}
const bundles = (page) => page.evaluate(() => [...enabledBundleIDs].sort());
const status = (page) => page.evaluate(() => (window.NostalgexServerSettings ? window.NostalgexServerSettings.state.status : "missing"));
const change = async (page, id) => {
  await page.mouse.click(10, 10);   // the first tap of the visit
  await page.evaluate((x) => { enabledBundleIDs.add(x); saveBundlePreferences(); }, id);
};
const keysOf = (body) => Object.keys(JSON.parse(body).keys);

// 1. A fresh browser starts from the container's lineup.
for (const [name, viewport] of [["TV 960x540", TV], ["phone 390x844", PHONE]]) {
  reset("on", JSON.stringify({ v: 1, updatedAt: "2026-11-10T00:00:00Z", keys: SHARED }));
  const { ctx, page, errors } = await open(selfhost, viewport, { local: { plex90_guide_layout: "bottom", plex90_retro_mode: "false" } });
  check(`${name}: the page read the container's file once`, box.gets === 1, String(box.gets));
  check(`${name}: the module is on`, (await status(page)) === "applied");
  check(`${name}: the packages are the container's, in the page's own state`, JSON.stringify(await bundles(page)) === JSON.stringify(["nostalgex", "sports"]), JSON.stringify(await bundles(page)));
  check(`${name}: a franchise switch came with it`, (await page.evaluate(() => localStorage.getItem("nostalgex_enabled_franchises"))) === SHARED.nostalgex_enabled_franchises);
  check(`${name}: display preferences are the browser's own`, (await page.evaluate(() => [localStorage.getItem("plex90_guide_layout"), localStorage.getItem("plex90_retro_mode")].join())) === "bottom,false");
  await page.waitForTimeout(3500);
  check(`${name}: opening the page and leaving it alone writes nothing`, box.puts.length === 0, String(box.puts.length));
  check(`${name}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 2. A change is sent once, as the shared keys only; the next browser has it.
{
  reset("on", JSON.stringify({ v: 1, keys: SHARED }));
  const login = JSON.stringify({ backend: "jellyfin", token: TOKEN, serverUrl: "http://127.0.0.1:9", serverName: "x", jellyfinUserId: "u" });
  const a = await open(selfhost, TV, {
    local: { plex90_saved_auth: login, plex90_guide_layout: "bottom", plex90_client_id: "install-id-xyz" },
    session: { plex90_token: TOKEN, plex90_backend: "jellyfin", plex90_server_url: "http://127.0.0.1:9", plex90_jellyfin_user_id: "u" },
  });
  await change(a.page, "kids");
  check("a change reaches the container (one PUT)", await until(() => box.puts.length >= 1, 5000));
  await wait(1200);
  check("exactly one PUT for it", box.puts.length === 1, String(box.puts.length));
  const body = box.puts[0] || "{}";
  check("it carries the new package", JSON.parse(JSON.parse(body).keys.nostalgex_enabled_bundles || "[]").includes("kids"));
  check("it carries only shared keys", keysOf(body).every((k) => ["nostalgex_enabled_bundles", "plex90_channel_config", "plex90_config_version", "nostalgex_enabled_collections", "nostalgex_enabled_franchises", "nostalgex_disabled_franchises"].includes(k)), keysOf(body).join());
  check("it holds no token, login or install id", !body.includes(TOKEN) && !body.includes("saved_auth") && !body.includes("install-id-xyz") && !body.includes("bottom"));
  check("nothing else was requested from the container's side", box.other.every((r) => !/nostalgex-settings/.test(r)));
  check("no page errors", a.errors.length === 0, a.errors.join(" | "));
  await a.ctx.close();
  const b = await open(selfhost, TV);
  check("a third browser starts with that package on", (await bundles(b.page)).includes("kids"));
  check("and its own login is empty, not the other's", (await b.page.evaluate(() => localStorage.getItem("plex90_saved_auth"))) === null);
  await b.ctx.close();
}

// 3. Nothing saved yet: the browser's own lineup, and its first change saves it.
{
  reset("on", null);
  const { ctx, page, errors } = await open(selfhost, TV);
  check("nothing saved: the module knows", (await status(page)) === "absent");
  check("nothing saved: the page starts from its own defaults", JSON.stringify(await bundles(page)) === JSON.stringify(["nostalgex"]), JSON.stringify(await bundles(page)));
  await page.waitForTimeout(2500);
  check("nothing saved: opening writes nothing", box.puts.length === 0);
  await change(page, "kids");
  check("nothing saved: the first change saves the lineup", await until(() => box.puts.length === 1, 5000));
  check("no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 4. An image without the feature, a failed read, a newer file: the page works, nobody writes.
for (const [mode, file, expect] of [["plain404", null, "off"], ["broken", null, "failed"], ["newer", null, "newer"]]) {
  reset(mode, file);
  const { ctx, page, errors } = await open(selfhost, TV, { local: { nostalgex_enabled_bundles: JSON.stringify(["nostalgex", "mine"]) } });
  check(`${mode}: the module reads it as ${expect}`, (await status(page)) === expect, await status(page));
  check(`${mode}: the page keeps the browser's own lineup`, JSON.stringify(await bundles(page)) === JSON.stringify(["mine", "nostalgex"]));
  await change(page, "kids");
  await page.waitForTimeout(2500);
  check(`${mode}: a change is not sent`, box.puts.length === 0, String(box.puts.length));
  check(`${mode}: the change is kept in this browser`, (await bundles(page)).includes("kids"));
  check(`${mode}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 5. No volume, or a read-only one: the PUT is refused. Three tries, one warning, the page unharmed.
{
  reset("readonly", null);
  const { ctx, page, errors, warnings } = await open(selfhost, TV);
  await page.mouse.click(10, 10);
  for (const id of ["a", "b", "c", "d", "e"]) {
    await page.evaluate((x) => { enabledBundleIDs.add(x); saveBundlePreferences(); }, id);
    await page.waitForTimeout(1900);
  }
  check("refused writes: three tries, then it leaves it", box.puts.length === 3, String(box.puts.length));
  check("refused writes: one warning says settings stay in this browser", warnings.filter((w) => /shared lineup could not be saved/.test(w)).length === 1, JSON.stringify(warnings));
  check("refused writes: all five changes are in this browser", (await bundles(page)).length === 6);
  check("refused writes: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 6. Hosted (no selfhost marker): the file is never asked for, never written, nothing changed.
{
  reset("on", JSON.stringify({ v: 1, keys: SHARED }));
  const { ctx, page, errors } = await open(hosted, TV, { local: { plex90_guide_layout: "bottom" } });
  check("hosted: the module did nothing", (await status(page)) === "off");
  check("hosted: the file was never asked for", box.gets === 0, String(box.gets));
  check("hosted: the packages are the browser's own defaults, not the container's", JSON.stringify(await bundles(page)) === JSON.stringify(["nostalgex"]), JSON.stringify(await bundles(page)));
  await change(page, "kids");
  await page.waitForTimeout(2500);
  check("hosted: a change is never sent", box.puts.length === 0 && box.gets === 0);
  check("hosted: the change stays in the browser as always", (await bundles(page)).includes("kids"));
  check("hosted: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 7. Negative control: the same page with the module taken out starts from its own defaults and
// asks for nothing, so the checks above are about the module and not about the stand-in.
{
  dropModule = true;
  reset("on", JSON.stringify({ v: 1, keys: SHARED }));
  const { ctx, page } = await open(selfhost, TV);
  check("negative control: without the module the page ignores the container's lineup", JSON.stringify(await bundles(page)) === JSON.stringify(["nostalgex"]));
  await change(page, "kids");
  await page.waitForTimeout(2500);
  check("negative control: and sends nothing", box.gets === 0 && box.puts.length === 0);
  await ctx.close();
  dropModule = false;
}

await browser.close();
selfhostSite.close();
hostedSite.close();
if (failures.length) {
  console.error(`shared lineup (browser): ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`shared lineup (browser): ${passed} passed (selfhost build against a stand-in container: read, write, nothing saved, no feature, failed read, refused writes; hosted unchanged)`);
