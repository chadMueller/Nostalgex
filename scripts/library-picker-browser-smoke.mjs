#!/usr/bin/env node
/**
 * The first-setup picker (CHOOSE YOUR LIBRARIES), the server picker and Settings > SERVERS & ACCOUNTS > LIBRARIES,
 * in the real plex-tuner.html (headless), against stubs. The rules are scripts/nostalgex-library-picker.js, pinned by
 * scripts/library-picker-golden.json (the node half is `npm run test:library-picker`); this is what a viewer sees.
 *
 * Plex (two stub servers, one owned and one shared, each with Movies, TV Shows, Music and Photos libraries):
 *   - the server picker starts with the viewer's own server INCLUDED and the shared one OFF; with none of their own,
 *     every server is INCLUDED;
 *   - CHOOSE YOUR LIBRARIES lists Movies and TV Shows of each chosen server and never Music or Photos, every row
 *     INCLUDED; a Music or Photo library is never asked for items, on either server, in the picker or after;
 *   - a library switched off in the picker is not read; Settings lists the same rows and switches one back on, which
 *     reads it.
 * Jellyfin (a stub that lists libraries the way a real 10.11 does: includeHidden=true adds the ones the user hides):
 *   - the picker lists each hidden library on its own row, marked HIDDEN ON JELLYFIN, OFF; Music and Playlists are not
 *     listed; CONTINUE with the defaults reads none of the hidden libraries;
 *   - there is no single switch any more; Settings switches one hidden library on and only it is read;
 *   - an install that had the old single switch ON keeps the same libraries on, and the old switch is gone;
 *   - Emby asks one list, never includeHidden.
 * Every action is a real button or row (a TV browser has no keys), checked with the mouse at 960x540 (DPR 2) and on a
 * phone, where the rows and CONTINUE fit the screen.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:library-picker:browser`. Headless only. SHOTS=/dir saves screenshots.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (origin/main's): the checks must fail.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));
const shots = process.env.SHOTS || "";
if (shots) mkdirSync(shots, { recursive: true });

// ── A Plex-shaped server ─────────────────────────────────────────────────────
const film = (key, title, n) => ({
  ratingKey: String(key), title, summary: "", year: 1985 + (n % 10), duration: 5400000, type: "movie",
  addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Action" }],
  Media: [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${key}/file.mp4` }] }],
});
const plexLog = {};   // server name -> every path asked
function plexServer(name, machine, films) {
  const sections = [
    { key: "1", title: "Movies", type: "movie" }, { key: "2", title: "TV Shows", type: "show" },
    { key: "3", title: "Music", type: "artist" }, { key: "4", title: "Photos", type: "photo" },
  ];
  plexLog[name] = [];
  return http.createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Headers", "*");
    if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
    const url = new URL(req.url, "http://x");
    res.setHeader("Content-Type", "application/json");
    plexLog[name].push(url.pathname);
    if (url.pathname === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: machine, version: "1.43.4" } }));
    if (url.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: sections } }));
    const all = url.pathname.match(/^\/library\/sections\/(\d+)\/all$/);
    if (all) {
      const list = all[1] === "1" ? films : [];
      const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0);
      const size = Number(url.searchParams.get("X-Plex-Container-Size") || list.length || 1);
      return res.end(JSON.stringify({ MediaContainer: { size: list.slice(start, start + size).length, totalSize: list.length, Metadata: list.slice(start, start + size) } }));
    }
    res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
  });
}
const den = plexServer("Den", "mach-den", Array.from({ length: 8 }, (_, i) => film(100 + i, `Den Film ${i}`, i)));
const garage = plexServer("Garage", "mach-garage", Array.from({ length: 5 }, (_, i) => film(200 + i, `Garage Film ${i}`, i)));

// ── A Jellyfin- and Emby-shaped server ───────────────────────────────────────
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
  "lib-hidden": Array.from({ length: 6 }, (_, i) => jfilm(`hidden${i}`, `Hidden Film ${i}`, i, 1985 + i)),
  "lib-docs": Array.from({ length: 4 }, (_, i) => jfilm(`docs${i}`, `Hidden Doc ${i}`, i, 1990 + i)),
};
const VISIBLE = [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }, { Id: "lib-music", Name: "Music", CollectionType: "music" }, { Id: "lib-lists", Name: "Playlists", CollectionType: "playlists" }];
const HIDDEN = [{ Id: "lib-hidden", Name: "Hidden Films", CollectionType: "movies" }, { Id: "lib-docs", Name: "Hidden Docs", CollectionType: "movies" }];
let jfLog = { views: [], parents: [] };
let embyServer = false;
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  const u = new URL(req.url, "http://x");
  if (req.url.startsWith("/System/Info/Public")) {
    return res.end(JSON.stringify(embyServer
      ? { ServerName: "lab", Version: "4.10.1.0", LocalAddresses: [], RemoteAddresses: [], Id: "fedcba9876543210fedcba9876543210" }
      : { ServerName: "lab", Version: "10.11.11", ProductName: "Jellyfin Server", Id: "lab" }));
  }
  if (u.pathname === "/UserViews" || /^\/Users\/[^/]+\/Views$/.test(u.pathname)) {
    jfLog.views.push(req.url);
    const include = u.pathname === "/UserViews" && u.searchParams.get("includeHidden") === "true";
    const items = embyServer ? [...VISIBLE, ...HIDDEN.slice(0, 0)] : (include ? [...VISIBLE, ...HIDDEN] : VISIBLE);
    return res.end(JSON.stringify({ Items: items, TotalRecordCount: items.length }));
  }
  if (u.pathname === "/Items") {
    const parent = u.searchParams.get("ParentId");
    jfLog.parents.push(parent);
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
for (const s of [den, garage, jellyfin, files]) await new Promise((r) => s.listen(0, "127.0.0.1", r));
const urlOf = (s) => `http://127.0.0.1:${s.address().port}`;
const base = urlOf(files);
const jf = urlOf(jellyfin);

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const browser = await chromium.launch({ headless: true });

const resource = (name, machine, server, owned) => ({
  provides: "server", name, clientIdentifier: machine, owned, presence: true, accessToken: `tok-${machine}`,
  connections: [{ uri: urlOf(server), protocol: "http", local: true, relay: false, address: "127.0.0.1", port: server.address().port }],
});

async function newPage(width, height, { dpr = 1, session = null, local = null, resources = null } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: dpr });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), async (route) => {
    const u = new URL(route.request().url());
    if (resources && u.hostname === "plex.tv" && u.pathname === "/api/v2/resources") {
      return route.fulfill({ status: 200, contentType: "application/json", headers: { "Access-Control-Allow-Origin": "*" }, body: JSON.stringify(resources) });
    }
    return route.abort();
  });
  await ctx.addInitScript(([sess, loc]) => {
    if (!location.pathname.endsWith("plex-tuner.html") || localStorage.getItem("nx-seeded")) return;
    localStorage.setItem("nx-seeded", "1");
    for (const [k, v] of Object.entries(sess || {})) sessionStorage.setItem(k, v);
    for (const [k, v] of Object.entries(loc || {})) localStorage.setItem(k, typeof v === "string" ? v : JSON.stringify(v));
  }, [session, local]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  return { ctx, page, errors };
}

const rowsOf = (page, sel) => page.evaluate((s) => [...document.querySelectorAll(s)].map((r) => {
  const b = r.getBoundingClientRect();
  return {
    title: (r.querySelector(".setup-row-title, .cfg-row-title") || {}).textContent,
    sub: (r.querySelector(".setup-row-sub, .cfg-row-desc") || {}).textContent,
    state: (r.querySelector(".setup-row-state, .cfg-row-state") || {}).textContent,
    left: b.left, right: b.right, role: r.getAttribute("role"), checked: r.getAttribute("aria-checked"),
  };
}), sel);
const fits = async (page) => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1);
const settledGuide = (page) => page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof allItemsCache !== "undefined" && allItemsCache.length > 0
  && document.getElementById("loading-library").style.display === "none", null, { timeout: 45000 }).then(() => page.waitForTimeout(500));
const titles = (page) => page.evaluate(() => allItemsCache.map((i) => i.title));
const lists = (page) => page.evaluate(() => ({
  off: JSON.parse(localStorage.getItem("nostalgex_deselected_library_sections") || "[]"),
  included: JSON.parse(localStorage.getItem("nostalgex_included_hidden_library_sections") || "[]"),
  legacy: localStorage.getItem("nostalgex_include_hidden_libraries"),
}));
const openSettings = async (page) => {
  await page.evaluate(() => { showConfig(); switchConfigTab("server"); });
  await page.waitForFunction(() => document.querySelectorAll("#cfg-library-rows .cfg-row").length > 0, null, { timeout: 15000 });
  await page.waitForTimeout(400);
};
const closeSettings = (page) => page.evaluate(() => { hideConfig(); });
const shot = async (page, name) => { if (shots) { await page.waitForTimeout(500); await page.screenshot({ path: join(shots, `${name}.png`) }); } };

// ═══ Plex ════════════════════════════════════════════════════════════════════
async function plexFlow(label, width, height, { dpr = 1, ownedDen = true, ownedGarage = false } = {}) {
  for (const k of Object.keys(plexLog)) plexLog[k].length = 0;
  const { ctx, page, errors } = await newPage(width, height, { dpr, resources: [resource("Den", "mach-den", den, ownedDen), resource("Garage", "mach-garage", garage, ownedGarage)] });
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => typeof discoverServers === "function");
  await page.evaluate(() => { plexToken = "t"; discoverServers(); });
  await page.waitForSelector("#server-picker.active .setup-row", { timeout: 15000 });
  const servers = await rowsOf(page, "#server-picker .setup-row");
  const states = servers.map((r) => `${r.title}:${r.state}`).join(",");
  const expect = (ownedDen || ownedGarage) ? `Den:${ownedDen ? "INCLUDED" : "OFF"},Garage:${ownedGarage ? "INCLUDED" : "OFF"}` : "Den:INCLUDED,Garage:INCLUDED";
  check(`${label}: the server picker starts with ${(ownedDen || ownedGarage) ? "the viewer's own servers INCLUDED and the rest OFF" : "every server INCLUDED (none is the viewer's own)"}`, states === expect, states);
  check(`${label}: the server rows are real, checkable rows that fit the screen`, servers.every((r) => r.role === "checkbox" && r.left >= 0 && r.right <= width + 0.5) && await fits(page));
  await shot(page, `${label}-servers`);
  // Both servers on, as a mouse would: a click on the one that is off.
  for (const [i, r] of servers.entries()) if (r.state === "OFF") await page.click(`#server-picker .setup-row[data-index="${i}"]`);
  const both = (await rowsOf(page, "#server-picker .setup-row")).map((r) => r.state).join();
  check(`${label}: a press on a server turns it on`, both === "INCLUDED,INCLUDED", both);
  await page.click("#server-picker .server-picker-connect");
  await page.waitForSelector("#library-picker.active .setup-row", { timeout: 20000 });
  const libs = await rowsOf(page, "#library-picker .setup-row");
  check(`${label}: CHOOSE YOUR LIBRARIES lists the Movies and TV Shows of each server, the server named, and no Music or Photos`,
    libs.map((r) => `${r.title}|${r.sub}`).join() === "Movies|Den · Movies,TV Shows|Den · TV Shows,Movies|Garage · Movies,TV Shows|Garage · TV Shows", JSON.stringify(libs.map((r) => `${r.title}|${r.sub}`)));
  check(`${label}: every library starts INCLUDED`, libs.every((r) => r.state === "INCLUDED" && r.checked === "true"), JSON.stringify(libs.map((r) => r.state)));
  check(`${label}: the rows fit the screen and CONTINUE can be pressed`, libs.every((r) => r.left >= 0 && r.right <= width + 0.5) && await fits(page) && await page.evaluate(() => {
    const b = document.querySelector("#library-picker .library-continue"); b.scrollIntoView({ block: "center" }); const r = b.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return !b.disabled && (hit === b || b.contains(hit));
  }));
  await shot(page, `${label}-libraries`);
  // Garage's Movies (the third row) off, then CONTINUE.
  await page.click("#library-picker .setup-row:nth-of-type(3)");
  const after = (await rowsOf(page, "#library-picker .setup-row")).map((r) => r.state).join();
  check(`${label}: a press on a library turns it off`, after === "INCLUDED,INCLUDED,OFF,INCLUDED", after);
  await page.click("#library-picker .library-continue");
  await settledGuide(page);
  const t = await titles(page);
  check(`${label}: the library switched off is not read, the others are`, t.some((x) => /^Den Film/.test(x)) && !t.some((x) => /^Garage Film/.test(x)), JSON.stringify([...new Set(t.map((x) => x.split(" ")[0]))]));
  check(`${label}: a Music or Photo library is never asked for items, on either server`, ![...plexLog.Den, ...plexLog.Garage].some((p) => /\/library\/sections\/[34]\//.test(p)), JSON.stringify([...plexLog.Den, ...plexLog.Garage].filter((p) => /\/sections\/[34]/.test(p))));
  check(`${label}: and Garage's Movies, off, is not asked for items`, !plexLog.Garage.includes("/library/sections/1/all"));
  await page.waitForTimeout(1500);
  const swept = [...plexLog.Den, ...plexLog.Garage];
  check(`${label}: a library switched off has no collections read either, one that is on does`, swept.includes("/library/sections/1/collections") && !plexLog.Garage.includes("/library/sections/1/collections"), JSON.stringify(swept.filter((p) => /collections/.test(p))));
  const saved = await lists(page);
  check(`${label}: only the one choice is saved (key <serverId>::<sectionKey>)`, JSON.stringify(saved.off) === JSON.stringify(["mach-garage::1"]) && saved.included.length === 0, JSON.stringify(saved));

  // Settings: the same rows, and one back on.
  await openSettings(page);
  const rows = await rowsOf(page, "#cfg-library-rows .cfg-row");
  check(`${label}: Settings lists the same four libraries`, rows.map((r) => `${r.title}|${r.state}`).join() === "Movies|INCLUDED,TV Shows|INCLUDED,Movies|OFF,TV Shows|INCLUDED", JSON.stringify(rows.map((r) => `${r.title}|${r.state}`)));
  check(`${label}: the Settings rows are real rows that fit the screen`, rows.every((r) => r.role === "checkbox" && r.left >= 0 && r.right <= width + 0.5) && await fits(page));
  await shot(page, `${label}-settings`);
  plexLog.Garage.length = 0;
  await page.click("#cfg-library-rows .cfg-row:nth-of-type(3)");
  await page.waitForFunction(() => /Garage Film/.test(allItemsCache.map((i) => i.title).join()), null, { timeout: 30000 });
  check(`${label}: switching it back on in Settings reads it`, plexLog.Garage.includes("/library/sections/1/all"));
  check(`${label}: and still never a Music or Photo library`, !plexLog.Garage.some((p) => /\/library\/sections\/[34]\//.test(p)));
  check(`${label}: nothing is left in the saved off list`, (await lists(page)).off.length === 0, JSON.stringify(await lists(page)));
  check(`${label}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}
await plexFlow("plex desktop 1440x900", 1440, 900);
await plexFlow("plex TV browser 960x540", 960, 540, { dpr: 2 });
await plexFlow("plex phone 390x844", 390, 844);
await plexFlow("plex no server of your own", 1440, 900, { ownedDen: false, ownedGarage: false });

// ═══ Jellyfin ════════════════════════════════════════════════════════════════
const jfSession = { plex90_token: "t", plex90_server_url: jf, plex90_server_name: "lab", plex90_backend: "jellyfin", plex90_jellyfin_user_id: "u" };
const sid = jf.toLowerCase();
async function jellyfinFlow(label, width, height, dpr = 1) {
  embyServer = false;
  jfLog = { views: [], parents: [] };
  const { ctx, page, errors } = await newPage(width, height, { dpr, session: jfSession });
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForSelector("#library-picker.active .setup-row", { timeout: 25000 });
  const libs = await rowsOf(page, "#library-picker .setup-row");
  check(`${label}: CHOOSE YOUR LIBRARIES lists Movies and each hidden library on its own row, and not Music or Playlists`,
    libs.map((r) => r.title).join() === "Hidden Films,Hidden Docs,Movies" || libs.map((r) => r.title).join() === "Movies,Hidden Films,Hidden Docs", JSON.stringify(libs.map((r) => r.title)));
  const hiddenRows = libs.filter((r) => /^Hidden/.test(r.title));
  check(`${label}: a hidden library is marked HIDDEN ON JELLYFIN and starts OFF; Movies starts INCLUDED`,
    hiddenRows.length === 2 && hiddenRows.every((r) => r.sub === "Movies · HIDDEN ON JELLYFIN" && r.state === "OFF" && r.checked === "false") && libs.find((r) => r.title === "Movies").state === "INCLUDED" && libs.find((r) => r.title === "Movies").sub === "Movies", JSON.stringify(libs));
  check(`${label}: the lists were asked as /UserViews?userId=u then the same with includeHidden=true`, jfLog.views.slice(0, 2).join() === "/UserViews?userId=u,/UserViews?userId=u&includeHidden=true", JSON.stringify(jfLog.views));
  check(`${label}: rows fit the screen, CONTINUE can be pressed`, libs.every((r) => r.left >= 0 && r.right <= width + 0.5) && await fits(page));
  await shot(page, `${label}-libraries`);
  await page.click("#library-picker .library-continue");
  await settledGuide(page);
  let t = await titles(page);
  check(`${label}: CONTINUE with the defaults reads Movies and none of the hidden libraries`, t.length === 12 && !t.some((x) => /^Hidden/.test(x)) && !jfLog.parents.some((p) => /^lib-(hidden|docs)$/.test(p)), `${t.length} titles; asked ${[...new Set(jfLog.parents)].join()}`);
  check(`${label}: the Music and Playlists views are never asked for items`, !jfLog.parents.some((p) => /^lib-(music|lists)$/.test(p)));
  await openSettings(page);
  const rows = await rowsOf(page, "#cfg-library-rows .cfg-row");
  check(`${label}: Settings has the same rows, one per library`, rows.length === 3 && rows.filter((r) => /HIDDEN ON JELLYFIN/.test(r.sub)).length === 2 && rows.every((r) => r.left >= 0 && r.right <= width + 0.5) && await fits(page), JSON.stringify(rows.map((r) => `${r.title}|${r.sub}|${r.state}`)));
  check(`${label}: there is no single switch for the hidden libraries any more`, (await page.evaluate(() => !document.getElementById("cfg-include-hidden-row") && !document.getElementById("cfg-include-hidden-toggle"))));
  await shot(page, `${label}-settings`);
  const hiddenIndex = rows.findIndex((r) => r.title === "Hidden Films") + 1;
  jfLog = { views: [], parents: [] };
  await page.click(`#cfg-library-rows .cfg-row:nth-of-type(${hiddenIndex})`);
  await page.waitForFunction(() => allItemsCache.some((i) => /^Hidden Film/.test(i.title)), null, { timeout: 30000 });
  await page.waitForTimeout(800);
  t = await titles(page);
  check(`${label}: switching Hidden Films on reads it, and only it (the other hidden library stays out)`, t.filter((x) => /^Hidden Film/.test(x)).length === 6 && !t.some((x) => /^Hidden Doc/.test(x)) && !jfLog.parents.includes("lib-docs"), `${t.length} titles`);
  const s = await lists(page);
  check(`${label}: it is saved in the included list, not the off list`, JSON.stringify(s.included) === JSON.stringify([`${sid}::lib-hidden`]) && s.off.length === 0, JSON.stringify(s));
  const after = await rowsOf(page, "#cfg-library-rows .cfg-row");
  check(`${label}: its row reads INCLUDED and keeps the HIDDEN mark`, after.find((r) => r.title === "Hidden Films").state === "INCLUDED" && /HIDDEN ON JELLYFIN/.test(after.find((r) => r.title === "Hidden Films").sub));
  check(`${label}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}
await jellyfinFlow("jellyfin desktop 1440x900", 1440, 900);
await jellyfinFlow("jellyfin TV browser 960x540", 960, 540, 2);
await jellyfinFlow("jellyfin phone 390x844", 390, 844);

// An install from before: the old single switch is ON, one hidden library was turned off by hand, and the library is
// read again on load. The same libraries stay on, and the old switch goes.
{
  embyServer = false;
  jfLog = { views: [], parents: [] };
  const { ctx, page, errors } = await newPage(1440, 900, {
    local: {
      plex90_saved_auth: { token: "t", serverUrl: jf, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" },
      nostalgex_completed_initial_load: "1", nostalgex_include_hidden_libraries: "1", nostalgex_deselected_library_sections: [`${sid}::lib-docs`],
      nostalgex_library_listing: [{ serverId: sid, serverName: "lab", key: "lib1", title: "Movies", type: "movie" }],
    },
  });
  await page.goto(`${base}/plex-tuner.html`);
  await settledGuide(page);
  const t = await titles(page);
  check("upgrade: an install with the old switch ON keeps Hidden Films on (its 6 films are read) and Hidden Docs, turned off by hand, stays off", t.filter((x) => /^Hidden Film/.test(x)).length === 6 && !t.some((x) => /^Hidden Doc/.test(x)), `${t.length} titles`);
  const s = await lists(page);
  check("upgrade: the old switch is gone; the hand-made choice is as it was; the carried choice is in the included list", s.legacy === null && JSON.stringify(s.off) === JSON.stringify([`${sid}::lib-docs`]) && JSON.stringify(s.included) === JSON.stringify([`${sid}::lib-hidden`]), JSON.stringify(s));
  check("upgrade: the first-setup picker does not appear for an existing install", await page.evaluate(() => !document.getElementById("library-picker").classList.contains("active")));
  await openSettings(page);
  const rows = await rowsOf(page, "#cfg-library-rows .cfg-row");
  check("upgrade: Settings shows Hidden Films INCLUDED and Hidden Docs OFF, both marked hidden", rows.find((r) => r.title === "Hidden Films").state === "INCLUDED" && rows.find((r) => r.title === "Hidden Docs").state === "OFF" && rows.filter((r) => /HIDDEN ON JELLYFIN/.test(r.sub)).length === 2, JSON.stringify(rows.map((r) => `${r.title}|${r.state}`)));
  check("upgrade: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// The old switch OFF (the default): hidden libraries stay off and are now listed.
{
  jfLog = { views: [], parents: [] };
  const { ctx, page, errors } = await newPage(1440, 900, {
    local: { plex90_saved_auth: { token: "t", serverUrl: jf, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }, nostalgex_completed_initial_load: "1", nostalgex_include_hidden_libraries: "0" },
  });
  await page.goto(`${base}/plex-tuner.html`);
  await settledGuide(page);
  const t = await titles(page);
  const s = await lists(page);
  check("upgrade: an install with the old switch OFF reads the same 12 titles, none hidden, and the old value is cleared", t.length === 12 && s.legacy === null && s.included.length === 0, JSON.stringify({ n: t.length, ...s }));
  await openSettings(page);
  const rows = await rowsOf(page, "#cfg-library-rows .cfg-row");
  check("upgrade: its hidden libraries are listed, marked, and OFF", rows.filter((r) => /HIDDEN ON JELLYFIN/.test(r.sub) && r.state === "OFF").length === 2, JSON.stringify(rows.map((r) => `${r.title}|${r.state}`)));
  check("upgrade: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// Emby: one list, never includeHidden, and no hidden libraries.
{
  embyServer = true;
  jfLog = { views: [], parents: [] };
  const { ctx, page, errors } = await newPage(1440, 900, {
    session: { ...jfSession, plex90_backend: "emby" }, local: { nostalgex_include_hidden_libraries: "1" },
  });
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForSelector("#library-picker.active .setup-row", { timeout: 25000 }).catch(() => {});
  const libs = await rowsOf(page, "#library-picker .setup-row");
  check("Emby: CHOOSE YOUR LIBRARIES lists Movies only, none hidden", libs.length === 1 && libs[0].title === "Movies" && libs[0].sub === "Movies", JSON.stringify(libs));
  check("Emby: only /Users/u/Views is asked, never includeHidden", jfLog.views.length >= 1 && jfLog.views.every((v) => v === "/Users/u/Views"), JSON.stringify(jfLog.views));
  check("Emby: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
  embyServer = false;
}

await browser.close();
for (const s of [den, garage, jellyfin, files]) s.close();
if (failures.length) {
  console.error(`library picker browser smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`library picker browser smoke: ${passed} checks passed (Plex: own servers on, Music and Photos never listed or read; Jellyfin: each hidden library its own row, off; old choices carried over; 960x540, phone and desktop)`);
process.exit(0);
