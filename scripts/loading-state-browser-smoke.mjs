#!/usr/bin/env node
/**
 * THE LOADING PATTERN (the same on the Apple TV, Roku, Android and the web; the words are Android's LoadNotice.kt), on the real page,
 * headless, against a Jellyfin-shaped server whose library pages can be held and released.
 *
 *   1. The very first load keeps the full-screen build screen (its own words, no guide block). When it ends whole, GUIDE READY: 450
 *      TITLES in yellow in the top bar, between the wordmark and SETTINGS, for about 4 seconds.
 *   2. A server or library switch with the guide on screen: the guide's empty area says CHANNEL GUIDE IS CHANGING (yellow, Press Start
 *      2P), then "READ 200 TITLES" and "MOVIES: 200 OF 450" (VT323) and a cyan animated bar; the build screen does not come up; the
 *      guide's rows are hidden; Settings carries the same words. Then GUIDE READY in the top bar.
 *   3. RESCAN LIBRARY: the same block, titled LOADING YOUR LIBRARY.
 *   4. A refresh behind a guide that stays up: UPDATING LIBRARY: 200 TITLES READ in the top bar (cyan), nothing in the guide's area,
 *      then GUIDE READY. On a phone the notice is in the phone's top bar.
 *   5. A read cut short (a library that failed) or one that failed says nothing.
 *   6. A sign-out during an in-guide load, and a server change during one: the old read saves nothing, builds nothing and says nothing.
 *      Negative control: the same page with the guard taken out saves the old library after the sign-out.
 *   7. The words, as pure functions: OF only with a total, TITLE for one, no em dash.
 * Negative control for the words: the loader with the pattern's titles taken out.
 *
 * SHOTS=/dir saves 1920x1080 screenshots of each state.
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:loading-state`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));
const SHOTS = process.env.SHOTS || "";
if (SHOTS) mkdirSync(SHOTS, { recursive: true });

// ---- the server ----
const film = (i) => ({
  Id: `m${i}`, Name: `Movie ${i}`, Type: "Movie", ProductionYear: 1980 + (i % 20), Genres: ["Action", "Comedy"][i % 2] ? [["Action", "Comedy"][i % 2]] : ["Action"], OfficialRating: "PG-13",
  RunTimeTicks: 54000000000, ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z",
  MediaSources: [{ Id: `m${i}`, Container: "mp4", RunTimeTicks: 54000000000, Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }] }],
});
const LIBS = {
  movies: { id: "libM", name: "Movies", items: Array.from({ length: 450 }, (_, i) => film(i)) },
  classics: { id: "libC", name: "Classics", items: Array.from({ length: 450 }, (_, i) => film(1000 + i)) },
};
let plan = { libs: ["movies"], gate: null, viewsFail: false, failLib: null };   // gate: a promise the pages after the first wait for
const sockets = new Set();
const jellyfin = http.createServer(async (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  const json = (b) => { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(b)); };
  if (url.pathname.startsWith("/System/Info/Public")) return json({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" });
  if (url.pathname.startsWith("/UserViews")) {
    if (plan.viewsFail) { res.writeHead(500); return res.end(); }
    return json({ Items: plan.libs.map((k) => ({ Id: LIBS[k].id, Name: LIBS[k].name, CollectionType: "movies" })), TotalRecordCount: plan.libs.length });
  }
  if (url.pathname === "/Items") {
    const lib = Object.values(LIBS).find((l) => l.id === url.searchParams.get("ParentId"));
    if (!lib) return json({ Items: [], TotalRecordCount: 0 });
    if (plan.failLib === lib.id) { res.writeHead(500); return res.end(); }
    const start = Number(url.searchParams.get("StartIndex") || 0);
    const limit = Number(url.searchParams.get("Limit") || 200);
    if (plan.gate && start >= 200) await plan.gate.promise;
    return json({ Items: lib.items.slice(start, start + limit), TotalRecordCount: lib.items.length });
  }
  json({ Items: [], TotalRecordCount: 0 });
});
jellyfin.on("connection", (s) => { sockets.add(s); s.on("close", () => sockets.delete(s)); });
const makeGate = () => { let release; const promise = new Promise((r) => { release = r; }); return { promise, release }; };

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
let oldLoader = false;   // the negative control: the loader without the pattern
let noGuard = false;     // the negative control: the page without the overtaken-read guard
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  if (oldLoader && p.endsWith("nostalgex-library-load.js")) {
    body = body.toString().replace("const loadTitle = (afterSwitch) => (afterSwitch ? TITLE_CHANGING : TITLE_LOADING);", "const loadTitle = () => 'SCANNING YOUR LIBRARY';");
  }
  if (noGuard && p.endsWith("plex-tuner.html")) {
    const before = body.toString();
    body = before.replace("const isCurrent = () => gen === libraryLoadGen;", "const isCurrent = () => true;");
    if (body === before) { res.writeHead(500); return res.end("guard not found"); }
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => jellyfin.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const jfApi = `http://127.0.0.1:${jellyfin.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(page, fn, timeout = 15000, arg) { return page.waitForFunction(fn, arg, { timeout, polling: 50 }).then(() => true, () => false); }

const browser = await chromium.launch({ headless: true });
const HD = { viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 };

async function open(viewport = HD) {
  const ctx = await browser.newContext(viewport);
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  await ctx.addInitScript(([a]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify(a));
    }
  }, [{ token: "t", serverUrl: jfApi, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  return { ctx, page, errors };
}
const shot = async (page, name) => { if (SHOTS) await page.screenshot({ path: join(SHOTS, `${name}.png`) }); };

/** What the loading shows right now, read from the page. */
const read = (page) => page.evaluate(() => {
  const vis = (el) => !!el && getComputedStyle(el).display !== "none" && !el.hidden && el.getBoundingClientRect().width > 0;
  const txt = (id) => (document.getElementById(id) || {}).textContent || "";
  const style = (id, prop) => { const el = document.getElementById(id); return el ? getComputedStyle(el)[prop] : ""; };
  const bar = (root) => { const b = root && root.querySelector(".gl-bar"); if (!b) return { present: false }; const a = getComputedStyle(b, "::after"); return { present: true, visible: b.getBoundingClientRect().width > 0, animated: a.animationName !== "none" && a.animationName !== "", cyan: a.backgroundColor }; };
  const panel = document.getElementById("loading-library");
  const guideBlock = document.getElementById("guide-loading");
  const noticeEl = [document.getElementById("top-notice"), document.getElementById("m-top-notice")].find((el) => vis(el)) || document.getElementById("top-notice");
  const cfg = document.getElementById("cfg-load-status");
  const body = document.getElementById("grid-body");
  return {
    panel: { shown: getComputedStyle(panel).display !== "none", title: txt("loading-library-headline"),
      stallInside: panel.contains(document.getElementById("loading-library-stall")) },
    guide: { shown: vis(guideBlock), title: txt("guide-loading-title"), titleColor: style("guide-loading-title", "color"), read: txt("guide-loading-read"), lib: txt("guide-loading-lib"), bar: bar(guideBlock),
      rowsHidden: getComputedStyle(body).visibility === "hidden",
      fonts: { title: style("guide-loading-title", "fontFamily"), read: style("guide-loading-read", "fontFamily"), lib: style("guide-loading-lib", "fontFamily") },
      box: guideBlock ? (() => { const r = guideBlock.getBoundingClientRect(), b = body.getBoundingClientRect(); return { cx: (r.left + r.right) / 2, bx: (b.left + b.right) / 2 }; })() : null },
    notice: { shown: vis(noticeEl), text: noticeEl ? noticeEl.textContent : "", kind: noticeEl ? noticeEl.dataset.kind : "", color: noticeEl ? getComputedStyle(noticeEl).color : "" },
    cfg: { shown: vis(cfg), title: txt("cfg-load-status-title"), line: txt("cfg-load-status-line"), kind: cfg ? cfg.dataset.kind : "", bar: bar(cfg) },
    mode: NostalgexLibraryLoad.loadingMode(),
  };
});
// ---- reading the page ----
const GEO = (page) => page.evaluate(() => {
  const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { l: b.left, r: b.right, t: b.top, b: b.bottom }; };
  return { notice: r(document.querySelector("#top-notice:not([hidden])")), mnotice: r(document.querySelector("#m-top-notice:not([hidden])")), logo: r(document.querySelector(".player-logo img")), rail: r(document.getElementById("v-toolbar")), mlogo: r(document.querySelector(".m-topbar-logo")), menu: r(document.getElementById("m-menu-btn")) };
});
const hits = (a, b) => a && b && a.l < b.r && a.r > b.l && a.t < b.b && a.b > b.t;
const YELLOW = /rgb\(255, 229, 0\)/;
const CYAN = /rgb\(0, 196, 255\)/;
const sleep2 = (ms) => new Promise((r) => setTimeout(r, ms));

async function openGuide(page) {
  await page.evaluate(() => { if (!CHANNELS.some((c) => c.enabled) && CHANNELS[0]) CHANNELS[0].enabled = true; if (!guideVisible) showGuide(); });
  await sleep2(300);
}
const cacheCount = (page) => page.evaluate(async () => { const c = await NostalgexStorage.libraryCache.load().catch(() => null); return c && c.items ? c.items.length : (c ? -1 : 0); });

// ---- 1. A first load: the build screen as it was ----
plan = { libs: ["movies"], gate: makeGate() };
const a = await open();
await a.page.goto(`${base}/plex-tuner.html`);
check("first load: the build screen comes up", await waitFor(a.page, () => document.getElementById("loading-library").style.display === "flex"));
check("first load: the first page is read", await waitFor(a.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000));
await sleep(300);
let s = await read(a.page);
check("first load: the build screen keeps its own words (no CHANGING, no LOADING YOUR LIBRARY title)", s.panel.shown && !/CHANNEL GUIDE IS CHANGING|LOADING YOUR LIBRARY/.test(s.panel.title) && /^SCANNING/.test(s.panel.title), s.panel.title);
check("first load: the guide's block and the top bar stay quiet", !s.guide.shown && !s.notice.shown && s.mode === "panel", JSON.stringify([s.guide.shown, s.notice, s.mode]));
check("first load: the still-loading notice lives inside the build screen", s.panel.stallInside);
await shot(a.page, "1-first-load");
plan.gate.release();
check("first load: the build screen goes", await waitFor(a.page, () => getComputedStyle(document.getElementById("loading-library")).display === "none", 20000));
await sleep(400);
s = await read(a.page);
check("first load: GUIDE READY: 450 TITLES in the top bar, yellow", s.notice.shown && s.notice.text === "GUIDE READY: 450 TITLES" && s.notice.kind === "ready" && YELLOW.test(s.notice.color), JSON.stringify(s.notice));
let g = await GEO(a.page);
check("first load: ...between the wordmark and the rail's SETTINGS", g.notice && g.logo && g.rail && g.notice.l >= g.logo.r && g.notice.r <= g.rail.l && !hits(g.notice, g.logo) && !hits(g.notice, g.rail), JSON.stringify(g));
await shot(a.page, "5-guide-ready");
await sleep(4300);
s = await read(a.page);
check("first load: and it is gone after about 4 seconds", !s.notice.shown, JSON.stringify(s.notice));
check("first load: no page errors", a.errors.length === 0, a.errors.join(" | "));

// ---- 2. A server or library switch, guide on screen ----
await openGuide(a.page);
plan.gate = makeGate();
await a.page.evaluate(() => { showConfig(); switchConfigTab("server"); });
await sleep(300);
await a.page.evaluate(() => { window.__switch = fetchLibraryFromServer({ cause: "switch" }).catch((e) => console.warn(e)); });
check("switch: the first page is read", await waitFor(a.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000));
await sleep(300);
s = await read(a.page);
check("switch: Settings says CHANNEL GUIDE IS CHANGING with the read line and the library line", s.cfg.shown && s.cfg.title === "CHANNEL GUIDE IS CHANGING" && s.cfg.line === "READ 200 TITLES · MOVIES: 200 OF 450" && s.cfg.bar.animated && s.cfg.kind === "loading", JSON.stringify(s.cfg));
await shot(a.page, "2-server-switch-settings");
await a.page.evaluate(() => hideConfig());
await sleep(300);
s = await read(a.page);
check("switch: the build screen does not come up (the guide is on screen)", !s.panel.shown && s.mode === "guide", `${s.panel.shown} ${s.mode}`);
check("switch: the guide's empty area says CHANNEL GUIDE IS CHANGING, yellow", s.guide.shown && s.guide.title === "CHANNEL GUIDE IS CHANGING" && YELLOW.test(s.guide.titleColor), `${s.guide.title} ${s.guide.titleColor}`);
check("switch: READ 200 TITLES, then MOVIES: 200 OF 450", s.guide.read === "READ 200 TITLES" && s.guide.lib === "MOVIES: 200 OF 450", `${s.guide.read} | ${s.guide.lib}`);
check("switch: a cyan animated bar, centred in the empty area", s.guide.bar.animated && CYAN.test(s.guide.bar.cyan) && Math.abs(s.guide.box.cx - s.guide.box.bx) < 4, JSON.stringify([s.guide.bar, s.guide.box]));
check("switch: the guide's rows are hidden while it says so", s.guide.rowsHidden);
check("switch: in the guide's own faces (Press Start 2P title, VT323 lines)", /Press Start 2P/.test(s.guide.fonts.title) && /VT323/.test(s.guide.fonts.read) && /VT323/.test(s.guide.fonts.lib), JSON.stringify(s.guide.fonts));
check("switch: the top bar is quiet", !s.notice.shown);
await shot(a.page, "3-empty-guide-changing");
plan.gate.release();
await a.page.evaluate(() => window.__switch);
await sleep(400);
s = await read(a.page);
check("switch: then GUIDE READY: 450 TITLES in the top bar and the block goes", s.notice.shown && s.notice.text === "GUIDE READY: 450 TITLES" && !s.guide.shown && !s.guide.rowsHidden, JSON.stringify([s.notice, s.guide.shown, s.guide.rowsHidden]));
await sleep(4300);
const src = readFileSync(join(root, "plex-tuner.html"), "utf8");
check("switch: toggleServerInSettings reads with cause 'switch' and first stops the read that is running", /async function toggleServerInSettings[\s\S]*?supersedeLibraryLoads\(\);[\s\S]*?fetchLibraryFromServer\(\{ cause: 'switch' \}\)/.test(src));
check("switch: a library switch (toggleLibrarySection) and the hidden-libraries switch read with cause 'switch'", /function toggleLibrarySection[\s\S]*?rescanLibrary\(\{ cause: 'switch' \}\)/.test(src) && /cause: 'switch' \}\);\s*\} catch \(err\) \{\s*console\.warn\('\[Nostalgex\] Library rescan after the hidden libraries switch/.test(src));

// ---- 3. RESCAN LIBRARY ----
plan.gate = makeGate();
await a.page.evaluate(() => { window.__rescan = rescanLibrary(); });
check("rescan: the first page is read", await waitFor(a.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000));
await sleep(300);
s = await read(a.page);
check("rescan: the guide's empty area says LOADING YOUR LIBRARY, yellow", s.guide.shown && s.guide.title === "LOADING YOUR LIBRARY" && YELLOW.test(s.guide.titleColor) && !s.panel.shown, `${s.guide.title} ${s.guide.titleColor} ${s.panel.shown}`);
await shot(a.page, "3b-empty-guide-loading");
plan.gate.release();
await a.page.evaluate(() => window.__rescan);
await sleep(4600);

// ---- 4. A refresh behind a guide that stays up ----
plan.gate = makeGate();
await a.page.evaluate(() => { window.__refresh = fetchLibraryFromServer({ background: true, buildAllChannels: true }); });
check("refresh: the first page is read", await waitFor(a.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000));
await sleep(300);
s = await read(a.page);
check("refresh: UPDATING LIBRARY: 200 TITLES READ in the top bar, cyan", s.notice.shown && s.notice.text === "UPDATING LIBRARY: 200 TITLES READ" && s.notice.kind === "updating" && CYAN.test(s.notice.color), JSON.stringify(s.notice));
check("refresh: nothing else: the guide's rows stay, the build screen stays down", !s.guide.shown && !s.guide.rowsHidden && !s.panel.shown, JSON.stringify([s.guide.shown, s.guide.rowsHidden, s.panel.shown]));
await shot(a.page, "4-updating-library");
plan.gate.release();
await a.page.evaluate(() => window.__refresh);
await sleep(400);
s = await read(a.page);
check("refresh: then GUIDE READY: 450 TITLES, yellow", s.notice.shown && s.notice.text === "GUIDE READY: 450 TITLES" && YELLOW.test(s.notice.color), JSON.stringify(s.notice));
await sleep(4300);
s = await read(a.page);
check("refresh: and it is gone after about 4 seconds", !s.notice.shown, JSON.stringify(s.notice));

// ---- 5. Cut short, and failed ----
plan = { libs: ["movies", "classics"], gate: null, failLib: LIBS.classics.id };
await a.page.evaluate(() => { window.__cut = rescanLibrary(); });
await a.page.evaluate(() => window.__cut);
await sleep(500);
s = await read(a.page);
check("cut short: a library that failed says nothing (no GUIDE READY)", !s.notice.shown && !s.cfg.shown && s.mode === "none", JSON.stringify([s.notice, s.cfg.shown, s.mode]));
plan = { libs: ["movies"], gate: null, viewsFail: true };
await a.page.evaluate(async () => { try { await rescanLibrary(); } catch (e) {} });
await sleep(500);
s = await read(a.page);
check("failure: a read that fails says nothing and leaves nothing on screen", !s.notice.shown && !s.cfg.shown && !s.guide.shown && s.mode === "none", JSON.stringify([s.notice, s.cfg.shown, s.guide.shown, s.mode]));
plan = { libs: ["movies"], gate: null };
check("main flow: no page errors", a.errors.length === 0, a.errors.join(" | "));

// ---- 6a. A server change during an in-guide load ----
plan = { libs: ["movies"], gate: makeGate() };
await openGuide(a.page);
await a.page.evaluate(() => { window.__old = fetchLibraryFromServer({ cause: "switch" }).catch((e) => ({ err: String(e) })); });
check("server change: the old read has its first page", await waitFor(a.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000));
const oldGate = plan.gate;
plan = { libs: ["movies", "classics"], gate: null };   // the new server set: 900 titles
await a.page.evaluate(() => { supersedeLibraryLoads(); window.__new = fetchLibraryFromServer({ cause: "switch" }); });
await a.page.evaluate(() => window.__new);
await sleep(300);
oldGate.release();   // the old read's held pages come back, after the new read is done
await a.page.evaluate(() => window.__old);
await sleep(600);
const afterChange = await a.page.evaluate(async () => { const c = await NostalgexStorage.libraryCache.load().catch(() => null); return { saved: c && c.items ? c.items.length : 0, cache: allItemsCache.length }; });
check("server change: the library saved and built is the new server set's (900), not the old read's (450)", afterChange.saved === 900 && afterChange.cache === 900, JSON.stringify(afterChange));
s = await read(a.page);
check("server change: GUIDE READY says 900", s.notice.shown && s.notice.text === "GUIDE READY: 900 TITLES", JSON.stringify(s.notice));
await sleep(4300);

// ---- 6b. A sign-out during an in-guide load ----
plan = { libs: ["movies"], gate: makeGate() };
await a.page.evaluate(() => { window.__rescan = rescanLibrary({ cause: "switch" }); });
check("sign-out: the read has its first page", await waitFor(a.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000));
await a.page.evaluate(() => signOut());
const atSignOut = await a.page.evaluate(() => ({ items: allItemsCache.length, channel: currentChannel }));
plan.gate.release();
await a.page.evaluate(() => window.__rescan.catch(() => {}));
await sleep(800);
const afterSignOut = await a.page.evaluate(async () => { const c = await NostalgexStorage.libraryCache.load().catch(() => null); return { saved: c && c.items ? c.items.length : 0, items: allItemsCache.length, channel: currentChannel, error: document.getElementById("plex-error-label").style.display, mode: NostalgexLibraryLoad.loadingMode() }; });
s = await read(a.page);
check("sign-out: nothing is saved for the account that left", afterSignOut.saved === 0, JSON.stringify(afterSignOut));
check("sign-out: nothing is built or tuned (the library and channel are as the sign-out left them)", afterSignOut.items === atSignOut.items && afterSignOut.channel === atSignOut.channel, JSON.stringify([atSignOut, afterSignOut]));
check("sign-out: no error screen and nothing said (no GUIDE READY, nothing loading)", afterSignOut.error !== "block" && !s.notice.shown && !s.guide.shown && afterSignOut.mode === "none", JSON.stringify([afterSignOut, s.notice]));
await a.ctx.close();

// ---- 6c. Negative control: the same sign-out with the guard taken out ----
noGuard = true;
plan = { libs: ["movies"], gate: makeGate() };
const ng = await open();
await ng.page.goto(`${base}/plex-tuner.html`);
await waitFor(ng.page, () => typeof NostalgexLibraryLoad !== "undefined" && appState === "player" && allItemsCache.length > 0, 30000).catch(() => {});
plan.gate.release();
await waitFor(ng.page, () => appState === "player" && allItemsCache.length === 450, 30000);
plan.gate = makeGate();
await ng.page.evaluate(() => { window.__rescan = rescanLibrary({ cause: "switch" }); });
await waitFor(ng.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000);
await ng.page.evaluate(() => signOut());
plan.gate.release();
await ng.page.evaluate(() => window.__rescan.catch(() => {}));
await sleep(800);
const negSaved = await cacheCount(ng.page);
check("negative control: without the guard the old read saves its library after the sign-out", negSaved > 0, String(negSaved));
await ng.ctx.close();
noGuard = false;

// ---- 7. The top bar on a phone and on a TV browser ----
plan = { libs: ["movies"], gate: null };
for (const [name, vp] of [["phone 390x844", { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true }], ["TV 960x540", { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 }]]) {
  const t = await open(vp);
  await t.page.goto(`${base}/plex-tuner.html`);
  await waitFor(t.page, () => typeof appState !== "undefined" && appState === "player" && allItemsCache.length === 450, 40000);
  await sleep(500);
  plan.gate = makeGate();
  await t.page.evaluate(() => { window.__r = fetchLibraryFromServer({ background: true, buildAllChannels: true }); });
  await waitFor(t.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000);
  await sleep(300);
  g = await GEO(t.page);
  if (name.startsWith("phone")) {
    check(`${name}: the notice is in the phone's top bar, between the wordmark and MENU`, g.mnotice && g.mlogo && g.menu && g.mnotice.l >= g.mlogo.r && g.mnotice.r <= g.menu.l && !g.notice, JSON.stringify(g));
  } else {
    check(`${name}: the notice is between the wordmark and the rail`, g.notice && g.logo && g.rail && g.notice.l >= g.logo.r && g.notice.r <= g.rail.l && !hits(g.notice, g.logo) && !hits(g.notice, g.rail), JSON.stringify(g));
  }
  await t.page.screenshot({ path: SHOTS ? join(SHOTS, `7-${name.split(" ")[0]}-updating.png`) : undefined }).catch(() => {});
  plan.gate.release();
  await t.page.evaluate(() => window.__r);
  await t.ctx.close();
}

// ---- 8. The words, as pure functions ----
const b = await open();
await b.page.goto(`${base}/plex-tuner.html`);
await waitFor(b.page, () => typeof NostalgexLibraryLoad !== "undefined");
const words = await b.page.evaluate(() => { const L = NostalgexLibraryLoad; return {
  r1: L.readLine(4210), r2: L.readLine(40, 40), r3: L.readLine(1), r4: L.readLine(5, 3),
  l1: L.libraryLine("Movies", 40, 40), l2: L.libraryLine("Movies"), l3: L.libraryLine("tv shows", 12, 30), l4: L.libraryLine("Movies", 50, 40),
  u0: L.updatingLine(0), u: L.updatingLine(4210), u1: L.updatingLine(1), g: L.readyLine(4210), g1: L.readyLine(1),
  t1: L.loadTitle(true), t2: L.loadTitle(false) }; });
check("words: READ 4,210 TITLES, OF only with a total, TITLE for one", words.r1 === "READ 4,210 TITLES" && words.r2 === "READ 40 OF 40 TITLES" && words.r3 === "READ 1 TITLE" && words.r4 === "READ 5 TITLES", JSON.stringify(words));
check("words: the library line is MOVIES: 40 OF 40, with OF n only when the server gave a total", words.l1 === "MOVIES: 40 OF 40" && words.l2 === "MOVIES" && words.l3 === "TV SHOWS: 12 OF 30" && words.l4 === "MOVIES", JSON.stringify(words));
check("words: UPDATING LIBRARY: n TITLES READ and GUIDE READY: n TITLES", words.u0 === "UPDATING LIBRARY" && words.u === "UPDATING LIBRARY: 4,210 TITLES READ" && words.u1 === "UPDATING LIBRARY: 1 TITLE READ" && words.g === "GUIDE READY: 4,210 TITLES" && words.g1 === "GUIDE READY: 1 TITLE", JSON.stringify(words));
check("words: the two titles", words.t1 === "CHANNEL GUIDE IS CHANGING" && words.t2 === "LOADING YOUR LIBRARY", JSON.stringify(words));
const kt = (() => { try { return execFileSync("git", ["-C", root, "show", "0c5e9e01:android/app/src/main/kotlin/com/muellhaus/nostalgex/engine/LoadNotice.kt"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }); } catch { return ""; } })();
if (kt) {
  check("words: the titles, the ready and the updating lines are Android's LoadNotice.kt, character for character", kt.includes(`"${words.t1}"`) && kt.includes(`"${words.t2}"`) && kt.includes('"UPDATING LIBRARY: ${count(read)} ${titles(read)} READ"') && kt.includes('"GUIDE READY: ${count(n)} ${titles(n)}"'));
}
check("words: no em dash in the loader's words", !/—/.test(readFileSync(join(root, "scripts/nostalgex-library-load.js"), "utf8")));
await b.ctx.close();

// ---- Negative control: the loader without the pattern's titles ----
oldLoader = true;
plan = { libs: ["movies"], gate: makeGate() };
const n = await open();
await n.page.goto(`${base}/plex-tuner.html?old`);
await waitFor(n.page, () => typeof appState !== "undefined" && appState === "player", 40000).catch(() => {});
plan.gate.release();
await sleep(500);
plan = { libs: ["movies"], gate: makeGate() };
await n.page.evaluate(() => { window.__s = fetchLibraryFromServer({ cause: "switch" }); });
await waitFor(n.page, () => NostalgexLibraryLoad.state.scanItemsFound >= 200, 15000);
await sleep(300);
s = await read(n.page);
check("negative control: without the pattern's titles the block does not say CHANNEL GUIDE IS CHANGING", s.guide.title !== "CHANNEL GUIDE IS CHANGING", s.guide.title);
plan.gate.release();
await n.page.evaluate(() => window.__s);
await n.ctx.close();
oldLoader = false;

await browser.close();
for (const sck of sockets) sck.destroy();
jellyfin.close(); files.close();
if (failures.length) {
  console.error(`loading-state browser smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`loading-state browser smoke: ${passed} checks passed (first load, switch, rescan, refresh, cut short, sign-out and server change mid-load, phone and TV, the words, negative controls)`);
