#!/usr/bin/env node
/**
 * STOP WAITING on the loading screen during a slow first library scan (parity with the Apple TV,
 * Roku and Android). The real plex-tuner.html, headless, against Jellyfin-shaped and Plex-shaped
 * servers that stop answering partway.
 *
 * The page's two numbers are 60 s of silence to offer the button and 210 s to give up alone
 * (scripts/nostalgex-load-stall.js). This smoke serves that file with 3 s and 9 s, after checking
 * the shipped values are 60 s and 210 s, so a run takes about a minute.
 *
 *   Jellyfin, a library whose second page never comes:
 *     - the block ("Still waiting on your server...", STOP WAITING) appears after the quiet spell,
 *       on screen and on top at 960x540 and on a phone (no keys reach a TV browser);
 *     - pressing it ends the load: the loading screen goes, the guide is built from the first
 *       library and the pages already read of the second, nothing is saved as the library, and the
 *       load does not count as the first one;
 *     - left alone it ends itself, with the same result.
 *   Jellyfin, slow but working (a page every 1.8 s for longer than the give-up time): the block
 *     never shows, the whole library loads and is saved.
 *   Jellyfin, nothing ever read: the error line says it stopped waiting; nothing is saved.
 *   Plex, a section whose second page never comes: pressing it keeps the finished section.
 * Negative control: origin/main's plex-tuner.html (no block, still loading when the new page has
 * long finished).
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:stop-waiting`. Headless only.
 */
import http from "node:http";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

const WARN = 3000;
const STALL = 9000;
const stallSrc = readFileSync(join(root, "scripts/nostalgex-load-stall.js"), "utf8");
const SHIPPED = { warn: /const WARN_AFTER_MS = 60000;/, stall: /const STALL_AFTER_MS = 210000;/ };
const fast = stallSrc.replace(SHIPPED.warn, `const WARN_AFTER_MS = ${WARN};`).replace(SHIPPED.stall, `const STALL_AFTER_MS = ${STALL};`);

// ---- servers ----
const film = (i) => ({
  Id: `m${i}`, Name: `Movie ${i}`, Type: "Movie", ProductionYear: 1980 + (i % 20), Genres: ["Action"], OfficialRating: "PG-13",
  RunTimeTicks: 54000000000, ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z",
  MediaSources: [{ Id: `m${i}`, Container: "mp4", RunTimeTicks: 54000000000, Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }] }],
});
const jfLibs = {
  A: { id: "libA", name: "Movies", items: Array.from({ length: 30 }, (_, i) => film(i)) },
  B: { id: "libB", name: "Classics", items: Array.from({ length: 400 }, (_, i) => film(1000 + i)) },
  C: { id: "libC", name: "Marathon", items: Array.from({ length: 1400 }, (_, i) => film(5000 + i)) },
};
let jfPlan = {};   // which library pages stall: { libB: { hangFrom: 200 }, libC: { delayMs: 1800 } }
const sockets = new Set();
const track = (srv) => srv.on("connection", (s) => { sockets.add(s); s.on("close", () => sockets.delete(s)); });
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  const json = (b) => { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(b)); };
  if (url.pathname.startsWith("/System/Info/Public")) return json({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" });
  if (url.pathname.startsWith("/UserViews")) {
    return json({ Items: jfPlan.libs.map((k) => ({ Id: jfLibs[k].id, Name: jfLibs[k].name, CollectionType: "movies" })), TotalRecordCount: jfPlan.libs.length });
  }
  if (url.pathname === "/Items") {
    const lib = Object.values(jfLibs).find((l) => l.id === url.searchParams.get("ParentId"));
    if (!lib) return json({ Items: [], TotalRecordCount: 0 });
    const start = Number(url.searchParams.get("StartIndex") || 0);
    const limit = Number(url.searchParams.get("Limit") || 200);
    const plan = jfPlan[lib.id] || {};
    if (plan.hangFrom !== undefined && start >= plan.hangFrom) return;   // never answers
    const send = () => json({ Items: lib.items.slice(start, start + limit), TotalRecordCount: lib.items.length });
    if (plan.delayMs) return void setTimeout(send, plan.delayMs);
    return send();
  }
  json({ Items: [], TotalRecordCount: 0 });
});
track(jellyfin);

const plexFilm = (key) => ({
  ratingKey: String(key), title: `Film ${key}`, summary: "", year: 1985 + (key % 10), duration: 5400000, type: "movie",
  addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Action" }],
  Media: [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${key}/file.mp4` }] }],
});
const plexHeld = { "1": Array.from({ length: 6 }, (_, i) => plexFilm(100 + i)), "2": Array.from({ length: 700 }, (_, i) => plexFilm(2000 + i)) };
const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  res.setHeader("Content-Type", "application/json");
  if (url.pathname === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
  if (url.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }, { key: "2", title: "Classics", type: "movie" }] } }));
  const all = url.pathname.match(/^\/library\/sections\/(\d+)\/all$/);
  if (all) {
    const list = plexHeld[all[1]];
    const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0);
    const size = Number(url.searchParams.get("X-Plex-Container-Size") || list.length);
    if (all[1] === "2" && start >= 300) return;   // the second page never comes
    return res.end(JSON.stringify({ MediaContainer: { size: list.slice(start, start + size).length, totalSize: list.length, Metadata: list.slice(start, start + size) } }));
  }
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});
track(plex);

// ---- the tuner's files ----
let pageSource = null;   // a path to serve in place of plex-tuner.html (the negative control)
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    if (pageSource) body = readFileSync(pageSource);
    body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  }
  if (p.endsWith("nostalgex-load-stall.js")) body = fast;
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => jellyfin.listen(0, "127.0.0.1", r));
await new Promise((r) => plex.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const jfApi = `http://127.0.0.1:${jellyfin.address().port}`;
const plexApi = `http://127.0.0.1:${plex.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

check("the shipped warn time is 60 s", SHIPPED.warn.test(stallSrc));
check("the shipped give-up time is 210 s", SHIPPED.stall.test(stallSrc));
check("the test copy has the short times", fast.includes(`WARN_AFTER_MS = ${WARN};`) && fast.includes(`STALL_AFTER_MS = ${STALL};`));

const browser = await chromium.launch({ headless: true });
const TV = { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 };
const PHONE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true };

async function open(viewport, auth) {
  const ctx = await browser.newContext(viewport);
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  await ctx.addInitScript(([a]) => {
    if (location.pathname.endsWith("plex-tuner.html")) {
      if (!sessionStorage.getItem("nx-seeded")) { sessionStorage.setItem("nx-seeded", "1"); localStorage.setItem("plex90_saved_auth", JSON.stringify(a)); }
      // Whether the block ever showed, and the first time it did.
      window.__stall = { seen: false, at: 0 };
      const t0 = Date.now();
      const watch = () => {
        const el = document.getElementById("loading-library-stall");
        if (!el) return setTimeout(watch, 50);
        new MutationObserver(() => { if (el.classList.contains("on") && !window.__stall.seen) window.__stall = { seen: true, at: Date.now() - t0 }; }).observe(el, { attributes: true, attributeFilter: ["class"] });
      };
      watch();
    }
  }, [auth]);
  const page = await ctx.newPage();
  const errors = [];
  const logs = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  page.on("console", (m) => { if (m.type() === "warning") logs.push(m.text()); });
  return { ctx, page, errors, logs };
}
const jfAuth = { token: "t", serverUrl: jfApi, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" };
const plexAuth = { token: "t", serverUrl: plexApi, serverName: "lab", backend: "plex", userToken: "t" };

const overlayUp = (page) => page.evaluate(() => getComputedStyle(document.getElementById("loading-library")).display !== "none");
const blockShown = (page) => page.evaluate(() => document.getElementById("loading-library-stall").classList.contains("on"));
const outcome = (page) => page.evaluate(async () => ({
  items: typeof allItemsCache !== "undefined" ? allItemsCache.length : -1,
  overlay: getComputedStyle(document.getElementById("loading-library")).display !== "none",
  blockOn: document.getElementById("loading-library-stall").classList.contains("on"),
  errorText: document.getElementById("plex-error-label").style.display === "block" ? document.getElementById("plex-error-label").textContent : "",
  saved: !!(await NostalgexStorage.libraryCache.load().catch(() => null)),
  firstLoadDone: localStorage.getItem("nostalgex_completed_initial_load") === "1",
  stall: window.__stall,
}));
// The loading screen comes up, then goes. (It starts hidden, so "hidden" alone is true at once.)
async function loadEnds(page, timeout) {
  if (!(await waitFor(page, () => getComputedStyle(document.getElementById("loading-library")).display !== "none", 10000))) return false;
  return waitFor(page, () => getComputedStyle(document.getElementById("loading-library")).display === "none", timeout);
}
async function waitFor(page, fn, timeout) { return page.waitForFunction(fn, null, { timeout, polling: 100 }).then(() => true, () => false); }

// 1. Stuck partway, the viewer presses the button; at TV size and on a phone.
for (const [name, viewport] of [["TV 960x540", TV], ["phone 390x844", PHONE]]) {
  jfPlan = { libs: ["A", "B"], libB: { hangFrom: 200 } };
  const { ctx, page, errors, logs } = await open(viewport, jfAuth);
  const t0 = Date.now();
  await page.goto(`${base}/plex-tuner.html`);
  const shown = await waitFor(page, () => document.getElementById("loading-library-stall")?.classList.contains("on"), WARN + 8000);
  const shownAt = Date.now() - t0;
  check(`Jellyfin ${name}: the block appears after the quiet spell`, shown, `${shownAt} ms`);
  check(`Jellyfin ${name}: not before the quiet spell`, shownAt >= WARN, `${shownAt} ms`);
  const text = await page.evaluate(() => document.getElementById("loading-library-stall").innerText.replace(/\s+/g, " ").trim());
  check(`Jellyfin ${name}: the words match the Apple TV`, text.startsWith("Still waiting on your server. Nothing has come back for a while.") && text.includes("STOP WAITING"), text);
  const btn = page.locator("#loading-library-stop-waiting");
  const box = await btn.boundingBox();
  const vp = page.viewportSize();
  check(`Jellyfin ${name}: STOP WAITING fits the screen`, box && box.y >= 0 && box.y + box.height <= vp.height && box.x >= 0 && box.x + box.width <= vp.width, JSON.stringify(box));
  const onTop = await page.evaluate(() => { const b = document.getElementById("loading-library-stop-waiting"); const r = b.getBoundingClientRect(); const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return hit === b; });
  check(`Jellyfin ${name}: STOP WAITING is on top, so a click reaches it`, onTop);
  check(`Jellyfin ${name}: START OVER is still there`, await page.locator("#loading-library-start-over").isVisible());
  await btn.click();
  check(`Jellyfin ${name}: the loading screen goes`, await waitFor(page, () => getComputedStyle(document.getElementById("loading-library")).display === "none", 15000));
  await page.waitForTimeout(500);
  const o = await outcome(page);
  check(`Jellyfin ${name}: the guide is built from what was read (30 + the 200 pages read of the second library)`, o.items === 230, String(o.items));
  check(`Jellyfin ${name}: no error screen`, o.errorText === "", o.errorText);
  check(`Jellyfin ${name}: not saved as the library`, o.saved === false);
  check(`Jellyfin ${name}: not counted as the first load`, o.firstLoadDone === false);
  check(`Jellyfin ${name}: the block is gone`, o.blockOn === false);
  check(`Jellyfin ${name}: the press is logged`, logs.some((l) => /viewer stopped waiting/.test(l)));
  check(`Jellyfin ${name}: the loss is named`, logs.some((l) => /lost 1 library/.test(l) && /Classics/.test(l)), JSON.stringify(logs.slice(-3)));
  check(`Jellyfin ${name}: not in browser full screen`, !(await page.evaluate(() => !!document.fullscreenElement)));
  check(`Jellyfin ${name}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 2. Stuck, nobody presses: it gives up on its own.
{
  jfPlan = { libs: ["A", "B"], libB: { hangFrom: 200 } };
  const { ctx, page, errors, logs } = await open(TV, jfAuth);
  const t0 = Date.now();
  await page.goto(`${base}/plex-tuner.html`);
  const ended = await loadEnds(page, STALL + 12000);
  const endedAt = Date.now() - t0;
  check("Jellyfin alone: the scan gives up on its own", ended, `${endedAt} ms`);
  check("Jellyfin alone: not before the give-up time", endedAt >= STALL, `${endedAt} ms`);
  await page.waitForTimeout(500);
  const o = await outcome(page);
  check("Jellyfin alone: the button had been offered first", o.stall.seen === true, JSON.stringify(o.stall));
  check("Jellyfin alone: same result as the press (230 items, not saved, not the first load)", o.items === 230 && !o.saved && !o.firstLoadDone, JSON.stringify({ items: o.items, saved: o.saved, first: o.firstLoadDone }));
  check("Jellyfin alone: the stall is logged as silence, not a press", logs.some((l) => /no scan progress for/.test(l)) && !logs.some((l) => /viewer stopped waiting/.test(l)));
  check("Jellyfin alone: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 3. Slow but working: pages keep coming, for longer than the give-up time.
{
  jfPlan = { libs: ["C"], libC: { delayMs: 1800 } };
  const { ctx, page, errors } = await open(TV, jfAuth);
  const t0 = Date.now();
  await page.goto(`${base}/plex-tuner.html`);
  const ended = await loadEnds(page, STALL + 20000);
  const took = Date.now() - t0;
  const o = await outcome(page);
  check("slow but working: the load takes longer than the give-up time", took > STALL, `${took} ms`);
  check("slow but working: it finishes with the whole library", ended && o.items === 1400, String(o.items));
  check("slow but working: the block never showed", o.stall.seen === false, JSON.stringify(o.stall));
  check("slow but working: the library is saved", o.saved === true);
  check("slow but working: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 4. Nothing ever read.
{
  jfPlan = { libs: ["B"], libB: { hangFrom: 0 } };
  const { ctx, page, errors } = await open(TV, jfAuth);
  await page.goto(`${base}/plex-tuner.html`);
  check("nothing read: the block appears", await waitFor(page, () => document.getElementById("loading-library-stall")?.classList.contains("on"), WARN + 8000));
  await page.locator("#loading-library-stop-waiting").click();
  check("nothing read: the error line says it stopped waiting", await waitFor(page, () => /STOPPED WAITING BEFORE ANYTHING LOADED/.test(document.getElementById("plex-error-label")?.textContent || ""), 10000));
  const o = await outcome(page);
  check("nothing read: the loading screen is gone and nothing is saved", !o.overlay && !o.saved);
  check("nothing read: RECONNECT is on screen", await page.locator("#plex-reconnect-jf").isVisible());
  check("nothing read: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 5. Plex: the second section's second page never comes.
{
  const { ctx, page, errors, logs } = await open(TV, plexAuth);
  await page.goto(`${base}/plex-tuner.html`);
  check("Plex: the block appears", await waitFor(page, () => document.getElementById("loading-library-stall")?.classList.contains("on"), WARN + 8000));
  await page.locator("#loading-library-stop-waiting").click();
  check("Plex: the loading screen goes", await waitFor(page, () => getComputedStyle(document.getElementById("loading-library")).display === "none", 15000));
  await page.waitForTimeout(500);
  const o = await outcome(page);
  check("Plex: the finished section is kept (6 films); the one in flight is not", o.items === 6, String(o.items));
  check("Plex: no error screen", o.errorText === "", o.errorText);
  check("Plex: not saved as the library, not the first load", !o.saved && !o.firstLoadDone, JSON.stringify({ saved: o.saved, first: o.firstLoadDone }));
  check("Plex: the loss is named", logs.some((l) => /lost 1 section/.test(l) && /Classics/.test(l)), JSON.stringify(logs.slice(-3)));
  check("Plex: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 6. Negative control: origin/main's page has no block and is still loading when the new one is done.
{
  const old = execFileSync("git", ["show", "origin/main:plex-tuner.html"], { cwd: root, maxBuffer: 64 * 1024 * 1024 });
  const { writeFileSync, mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const dir = mkdtempSync(join(tmpdir(), "nx-old-"));
  const file = join(dir, "plex-tuner.html");
  writeFileSync(file, old);
  pageSource = file;
  jfPlan = { libs: ["A", "B"], libB: { hangFrom: 200 } };
  const { ctx, page } = await open(TV, jfAuth);
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForTimeout(STALL + 4000);
  check("negative control: the old page has no STOP WAITING block", (await page.locator("#loading-library-stop-waiting").count()) === 0);
  check("negative control: the old page is still on the loading screen after the give-up time", await overlayUp(page));
  await ctx.close();
  pageSource = null;
}

for (const s of sockets) s.destroy();
await browser.close();
jellyfin.close();
plex.close();
files.close();
if (failures.length) {
  console.error(`stop waiting (browser): ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`stop waiting (browser): ${passed} passed (Jellyfin pressed, alone, slow but working, nothing read; Plex; at 960x540 and on a phone; negative control)`);
