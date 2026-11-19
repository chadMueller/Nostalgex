#!/usr/bin/env node
/**
 * The library choice a sign-in still owes, in the real plex-tuner.html (headless), against a Jellyfin-shaped stub.
 * The Apple TV (LibrarySectionSelectionStore.pickOwed, #337), Roku (#331) and Android (#338) had the same gap: the
 * sign-in is saved before CHOOSE YOUR LIBRARIES is shown and the screen lives only in memory, so closing the app on
 * it relaunched straight into a scan of every library. On the web the saved sign-in is in localStorage
 * (plex90_saved_auth, written by the landing page) while the picker was only ever offered to a visit that came
 * straight from a sign-in, so a new browser session (a closed tab, a restarted browser, a TV browser relaunch, a
 * Docker page opened again) skipped it and read every library.
 *
 * The rule, the Apple TV's: from the moment a sign-in reaches the picker step the choice is owed
 * (localStorage nostalgex_library_pick_owed = "1"). CONTINUE, a sign-in with nothing to choose and a sign-out clear
 * it. A launch that finds it owed shows CHOOSE YOUR LIBRARIES again (the choices start again, as at a sign-in) before
 * any scan. A relaunch that cannot read the libraries keeps the choice owed for the next one.
 *
 * A relaunch here is a new browser context carrying the old localStorage and none of the old sessionStorage.
 * Run at desktop, 960x540 (DPR 2, a TV browser) and phone width.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:library-picker:owed`. Headless only.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (the one before the fix): the checks must fail.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

// ── A Jellyfin-shaped server with two libraries on the home screen ───────────
const GENRES = ["Action", "Comedy", "Drama", "Thriller", "Horror", "Romance", "Science Fiction", "Adventure"];
const jfilm = (id, name, i, year) => {
  const ticks = (85 + (i % 40)) * 60 * 10000000;
  return {
    Id: id, Name: name, Type: "Movie", ProductionYear: year, Genres: [GENRES[i % GENRES.length]], OfficialRating: "PG", CommunityRating: 6, RunTimeTicks: ticks,
    ProviderIds: { Tmdb: String(1000 + i) }, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "A film.",
    MediaSources: [{ Id: `ms-${id}`, Container: "mp4", Bitrate: 4000000, RunTimeTicks: ticks, Size: 2000000, SupportsDirectPlay: true,
      MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true }] }],
  };
};
const LIBRARY = {
  lib1: Array.from({ length: 12 }, (_, i) => jfilm(`film${i}`, `Film ${i}`, i, 1980 + i)),
  lib2: Array.from({ length: 6 }, (_, i) => jfilm(`doc${i}`, `Doc ${i}`, i, 1990 + i)),
};
const TWO = [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }, { Id: "lib2", Name: "Documentaries", CollectionType: "movies" }];
const ONE = [TWO[0]];
let views = TWO;       // what the stub lists
let hang = false;      // /UserViews never answers (an unreachable server on a relaunch)
let log = { views: 0, parents: [] };
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const u = new URL(req.url, "http://x");
  if (hang && /\/(UserViews|Views)$/.test(u.pathname)) { log.views += 1; return; }
  res.writeHead(200, { "Content-Type": "application/json" });
  if (req.url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.11.11", ProductName: "Jellyfin Server", Id: "lab" }));
  if (u.pathname === "/UserViews" || /^\/Users\/[^/]+\/Views$/.test(u.pathname)) {
    log.views += 1;
    return res.end(JSON.stringify({ Items: views, TotalRecordCount: views.length }));
  }
  if (u.pathname === "/Items") {
    const parent = u.searchParams.get("ParentId");
    log.parents.push(parent);
    const all = LIBRARY[parent];
    if (all && String(u.searchParams.get("IncludeItemTypes")).split(",").includes("Movie")) {
      const start = Number(u.searchParams.get("StartIndex") || 0);
      const limit = Number(u.searchParams.get("Limit") || all.length);
      return res.end(JSON.stringify({ Items: all.slice(start, start + limit), TotalRecordCount: all.length }));
    }
  }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});

// ── The page server ──────────────────────────────────────────────────────────
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    if (process.env.NX_TUNER_HTML) body = readFileSync(process.env.NX_TUNER_HTML);
    body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
for (const s of [jellyfin, files]) await new Promise((r) => s.listen(0, "127.0.0.1", r));
const urlOf = (s) => `http://127.0.0.1:${s.address().port}`;
const base = urlOf(files);
const jf = urlOf(jellyfin);

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const browser = await chromium.launch({ headless: true });

// What web-tuner.html leaves behind at a sign-in: the saved login in localStorage, and in this tab's sessionStorage the
// login and the one-time fresh-sign-in flag.
const session = { plex90_token: "t", plex90_server_url: jf, plex90_server_name: "lab", plex90_backend: "jellyfin", plex90_jellyfin_user_id: "u", plex90_fresh_signin: "1" };
const saved = { plex90_saved_auth: JSON.stringify({ token: "t", serverUrl: jf, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }) };

async function open({ width, height, dpr = 1, state = null, sess = null, local = null, initScript = null }) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: dpr, ...(state ? { storageState: state } : {}) });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  if (initScript) await ctx.addInitScript(initScript);
  await ctx.addInitScript(([s, l]) => {
    if (!location.pathname.endsWith("plex-tuner.html") || localStorage.getItem("nx-seeded")) return;
    localStorage.setItem("nx-seeded", "1");
    for (const [k, v] of Object.entries(s || {})) sessionStorage.setItem(k, v);
    for (const [k, v] of Object.entries(l || {})) localStorage.setItem(k, v);
  }, [sess, local]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/plex-tuner.html`);
  return { ctx, page, errors };
}
// A new browser session: this context's localStorage, none of its sessionStorage.
async function relaunch(first, opts) {
  const state = await first.ctx.storageState();
  await first.ctx.close();
  return open({ ...opts, state });
}
const rowsOf = (page) => page.evaluate(() => [...document.querySelectorAll("#library-picker .setup-row")].map((r) => ({
  title: r.querySelector(".setup-row-title").textContent, state: r.querySelector(".setup-row-state").textContent,
})));
const pickerUp = (page, timeout = 25000) => page.waitForSelector("#library-picker.active .setup-row", { timeout }).then(() => true, () => false);
const owed = (page) => page.evaluate(() => localStorage.getItem("nostalgex_library_pick_owed"));
const settledGuide = (page) => page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof allItemsCache !== "undefined" && allItemsCache.length > 0
  && document.getElementById("loading-library").style.display === "none", null, { timeout: 45000 }).then(() => page.waitForTimeout(500));
const titles = (page) => page.evaluate(() => allItemsCache.map((i) => i.title));

// ═══ Sign in, close on CHOOSE YOUR LIBRARIES, open again ═════════════════════
async function relaunchFlow(label, width, height, dpr = 1) {
  views = TWO; hang = false; log = { views: 0, parents: [] };
  const a = await open({ width, height, dpr, sess: session, local: saved });
  check(`${label}: a sign-in shows CHOOSE YOUR LIBRARIES`, await pickerUp(a.page));
  check(`${label}: from there the choice is owed (saved in localStorage)`, (await owed(a.page)) === "1", String(await owed(a.page)));
  check(`${label}: nothing is read while the choice is open`, log.parents.length === 0, log.parents.join());

  // The browser is closed on the picker and opened again (no sessionStorage). The saved login comes back.
  log = { views: 0, parents: [] };
  const b = await relaunch(a, { width, height, dpr });
  const offered = await pickerUp(b.page);
  check(`${label}: a relaunch shows CHOOSE YOUR LIBRARIES again, not a scan of every library`, offered, `the guide read ${[...new Set(log.parents)].join() || "nothing"}`);
  if (!offered) { await b.ctx.close(); return; }
  const rows = await rowsOf(b.page);
  check(`${label}: it lists both libraries, every one INCLUDED (the choices start again)`, rows.map((r) => `${r.title}:${r.state}`).join() === "Movies:INCLUDED,Documentaries:INCLUDED", JSON.stringify(rows));
  check(`${label}: no library is read while it is open`, log.parents.length === 0, log.parents.join());
  check(`${label}: still owed`, (await owed(b.page)) === "1");
  // Documentaries off, CONTINUE.
  await b.page.click("#library-picker .setup-row:nth-of-type(2)");
  await b.page.click("#library-picker .library-continue");
  await settledGuide(b.page);
  const t = await titles(b.page);
  check(`${label}: CONTINUE reads only the library that was left on`, t.length === 12 && !t.some((x) => /^Doc /.test(x)) && !log.parents.includes("lib2"), `${t.length} titles; asked ${[...new Set(log.parents)].join()}`);
  check(`${label}: CONTINUE clears the debt`, (await owed(b.page)) === null, String(await owed(b.page)));

  // Another relaunch: the choice was made, so there is no picker and no re-read of lib2.
  log = { views: 0, parents: [] };
  const c = await relaunch(b, { width, height, dpr });
  await settledGuide(c.page);
  check(`${label}: after CONTINUE a relaunch goes straight to the guide`, await c.page.evaluate(() => !document.getElementById("library-picker").classList.contains("active")) && !log.parents.includes("lib2"), [...new Set(log.parents)].join());
  check(`${label}: no page errors`, [...a.errors, ...b.errors, ...c.errors].length === 0, [...a.errors, ...b.errors, ...c.errors].join(" | "));
  await c.ctx.close();
}
await relaunchFlow("desktop 1440x900", 1440, 900);
await relaunchFlow("TV browser 960x540", 960, 540, 2);
await relaunchFlow("phone 390x844", 390, 844);

// ═══ A reload in the same tab (sessionStorage kept) still offers it ══════════
{
  views = TWO; hang = false; log = { views: 0, parents: [] };
  const a = await open({ width: 1440, height: 900, sess: session, local: saved });
  await pickerUp(a.page);
  await a.page.reload();
  check("same-tab reload on the picker: it is offered again", await pickerUp(a.page));
  check("same-tab reload on the picker: nothing was scanned", log.parents.length === 0, log.parents.join());
  await a.ctx.close();
}

// ═══ Nothing to choose: the debt is cleared, a relaunch scans ════════════════
{
  views = ONE; hang = false; log = { views: 0, parents: [] };
  const a = await open({ width: 1440, height: 900, sess: session, local: saved });
  await settledGuide(a.page);
  check("one library: the picker is not offered and the guide loads", await a.page.evaluate(() => !document.getElementById("library-picker").classList.contains("active")) && (await titles(a.page)).length === 12);
  check("one library: nothing to choose clears the debt", (await owed(a.page)) === null, String(await owed(a.page)));
  const b = await relaunch(a, { width: 1440, height: 900 });
  await settledGuide(b.page);
  check("one library: a relaunch loads the guide with no picker", await b.page.evaluate(() => !document.getElementById("library-picker").classList.contains("active")));
  await b.ctx.close();
  views = TWO;
}

// ═══ Sign-out clears it ══════════════════════════════════════════════════════
{
  views = TWO; hang = false; log = { views: 0, parents: [] };
  const a = await open({ width: 1440, height: 900, sess: session, local: saved });
  await pickerUp(a.page);
  check("sign-out: the debt is owed first", (await owed(a.page)) === "1");
  await a.page.evaluate(() => signOut());
  check("sign-out: it clears the debt", (await owed(a.page)) === null, String(await owed(a.page)));
  await a.ctx.close();
}

// ═══ A relaunch that cannot read the libraries keeps the debt and does not trap the viewer ═══
{
  views = TWO; hang = false; log = { views: 0, parents: [] };
  const a = await open({ width: 1440, height: 900, sess: session, local: saved });
  await pickerUp(a.page);
  hang = true;
  const b = await relaunch(a, { width: 1440, height: 900, initScript: () => { globalThis.NX_LIBRARY_RESUME_READ_MS = 1500; } });
  await b.page.waitForTimeout(500);
  check("unreachable relaunch: while the libraries are read, the page says so", await b.page.evaluate(() => /READING YOUR LIBRARIES/.test(document.getElementById("library-picker").textContent)));
  await b.page.waitForFunction(() => !document.getElementById("library-picker").classList.contains("active"), null, { timeout: 10000 }).catch(() => {});
  check("unreachable relaunch: it gives up waiting and hands over to the loading screen (which has START OVER), so the viewer is not left on a quiet line",
    await b.page.evaluate(() => !document.getElementById("library-picker").classList.contains("active") && document.getElementById("loading-library").style.display !== "none"));
  check("unreachable relaunch: the choice stays owed for the next launch", (await owed(b.page)) === "1", String(await owed(b.page)));
  await b.ctx.close();
  hang = false;
}

await browser.close();
for (const s of [jellyfin, files]) s.close();
if (failures.length) {
  console.error(`library pick owed browser smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`library pick owed browser smoke: ${passed} checks passed (a relaunch on CHOOSE YOUR LIBRARIES shows it again before any scan; CONTINUE, one library and sign-out clear it; an unreachable server does not trap the viewer; desktop, 960x540 and phone)`);
process.exit(0);
