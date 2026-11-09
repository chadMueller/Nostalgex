#!/usr/bin/env node
/**
 * INCLUDE LIBRARIES HIDDEN ON JELLYFIN, in the real plex-tuner.html (headless), against a stub that
 * lists libraries the way a real Jellyfin 10.11.11 does (measured): /UserViews leaves out a library the
 * user hides from the home screen unless includeHidden=true, and never lists a library the user may not
 * open (asking it for items anyway is recorded and fails the run).
 *
 * What it checks:
 *   - the switch is in Settings > GENERAL > PLAYBACK under OPEN ON LAST CHANNEL, with the Apple TV era
 *     wording of the line under it, a real button (a TV browser has no keys), visible and pressable by
 *     mouse at 960x540 and on a phone;
 *   - never chosen, the first scan's request is exactly /UserViews?userId=u (what it always was) and no
 *     title from the hidden library is in the library; the button reads OFF;
 *   - pressing it saves '1', reads the library again ONCE with includeHidden=true, in the background, and the
 *     hidden library's films come in (and reach a channel's pool); the library without access is never asked
 *     for; the button reads ON. A viewer on a channel other than the first stays on it, Settings stays open,
 *     and nothing retunes (a foreground read ends by tuning the first channel); a second press while the read
 *     runs does nothing;
 *   - a reload restores the library from the saved copy (no new request) and the switch stays ON; with the
 *     saved copy cleared the next scan asks for hidden libraries;
 *   - pressing it again saves '0', reads once more, with no includeHidden, and the hidden films go;
 *   - flipping INCLUDE_HIDDEN_DEFAULT in scripts/nostalgex-jellyfin-urls.js (the one line) makes the never
 *     chosen position ON, and a saved '0' still wins;
 *   - on Emby the row is hidden and the request is /Users/u/Views, even with the key saved as '1'; on
 *     Plex the row is hidden.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (origin/main's), which has no
 * switch; the checks on the switch must fail there.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable
 * `playwright`. Run: `npm run test:include-hidden:browser`. Headless only. SHOTS=/dir saves screenshots.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));
const shots = process.env.SHOTS || "";
if (shots) mkdirSync(shots, { recursive: true });

const LINE = "Jellyfin lets you hide a library from your home screen. Off keeps those out of your channels.";
const TITLE = "Include libraries hidden on Jellyfin";

// ── The stub server ──────────────────────────────────────────────────────────
const GENRES = ["Action", "Comedy", "Drama", "Thriller", "Horror", "Romance", "Science Fiction", "Adventure", "Animation", "Family", "Crime", "Mystery", "War", "Western", "Documentary", "Fantasy"];
const CERTS = ["G", "PG", "PG-13", "R", "PG", "PG-13"];
const film = (id, name, i, year) => {
  const ticks = (85 + (i % 40)) * 60 * 10000000;
  return {
    Id: id, Name: name, Type: "Movie", ProductionYear: year, Genres: [GENRES[i % GENRES.length], GENRES[(i * 7 + 3) % GENRES.length]],
    OfficialRating: CERTS[i % CERTS.length], CommunityRating: 5 + (i % 40) / 10, RunTimeTicks: ticks, ProviderIds: { Tmdb: String(1000 + i) }, Studios: [],
    DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "A film.",
    MediaSources: [{ Id: `ms-${id}`, Container: "mp4", Bitrate: 4000000, RunTimeTicks: ticks, Size: 2000000, SupportsDirectPlay: true,
      MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true }] }],
  };
};
const LIBRARY = {
  lib1: Array.from({ length: 300 }, (_, i) => film(`film${i}`, `Film ${i}`, i, 1960 + (i % 62))),
  "lib-hidden": Array.from({ length: 20 }, (_, i) => film(`hidden${i}`, `Hidden Film ${i}`, i, 1985 + (i % 14))),
  "lib-private": Array.from({ length: 5 }, (_, i) => film(`private${i}`, `Private Film ${i}`, i, 1990)),
};
const VISIBLE = [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }];
const HIDDEN = [{ Id: "lib-hidden", Name: "Hidden Films", CollectionType: "movies" }];
let log = { views: [], itemParents: [], private: [] };
const mark = () => ({ views: log.views.length, itemParents: log.itemParents.length });
let embyServer = false;

const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  const url = req.url;
  const u = new URL(url, "http://x");
  if (url.startsWith("/System/Info/Public")) {
    return res.end(JSON.stringify(embyServer
      ? { ServerName: "lab", Version: "4.10.1.0", LocalAddresses: [], RemoteAddresses: [], Id: "fedcba9876543210fedcba9876543210" }
      : { ServerName: "lab", Version: "10.11.11", ProductName: "Jellyfin Server", Id: "lab" }));
  }
  if (u.pathname === "/UserViews" || /^\/Users\/[^/]+\/Views$/.test(u.pathname)) {
    log.views.push(url);
    // The real server: hidden libraries only with includeHidden=true; Emby has no such parameter and lists what the user may open.
    const include = u.pathname === "/UserViews" && u.searchParams.get("includeHidden") === "true";
    const items = embyServer ? [...VISIBLE, ...HIDDEN] : (include ? [...VISIBLE, ...HIDDEN] : VISIBLE);
    return res.end(JSON.stringify({ Items: items, TotalRecordCount: items.length }));
  }
  if (u.pathname === "/Items") {
    const parent = u.searchParams.get("ParentId");
    log.itemParents.push(parent);
    if (parent === "lib-private") { log.private.push(url); res.writeHead(401); return res.end("{}"); }
    const all = LIBRARY[parent];
    if (all && String(u.searchParams.get("IncludeItemTypes")).split(",").includes("Movie")) {
      const start = Number(u.searchParams.get("StartIndex") || 0);
      const limit = Number(u.searchParams.get("Limit") || all.length);
      return res.end(JSON.stringify({ Items: all.slice(start, start + limit), TotalRecordCount: all.length }));
    }
  }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});

// ── The page server; `flip` serves the urls module with its one default line turned over ─────────────
let flip = false;
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    if (process.env.NX_TUNER_HTML) body = readFileSync(process.env.NX_TUNER_HTML);
    body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  }
  if (flip && p.endsWith("nostalgex-jellyfin-urls.js")) {
    const text = body.toString();
    if (!text.includes("const INCLUDE_HIDDEN_DEFAULT = false;")) { res.writeHead(500); return res.end("default line not found"); }
    body = text.replace("const INCLUDE_HIDDEN_DEFAULT = false;", "const INCLUDE_HIDDEN_DEFAULT = true;");
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

async function openPage(width, height, { backend = "jellyfin", seed = {} } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height } });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url, kind, extra]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: kind, jellyfinUserId: "u" }));
      for (const [k, v] of Object.entries(extra)) localStorage.setItem(k, v);
    }
  }, [api, backend, seed]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  log = { views: [], itemParents: [], private: [] };
  await page.goto(`${base}/plex-tuner.html`);
  await settled(page);
  return { ctx, page, errors };
}
// The library loaded and the loading screen is gone.
async function settled(page) {
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof currentChannel !== "undefined" && currentChannel !== null
    && document.getElementById("loading-library").style.display === "none", null, { timeout: 45000 }).catch(() => {});
  await page.waitForTimeout(600);
}
const library = (page) => page.evaluate(() => {
  const titles = allItemsCache.map((i) => i.title);
  const all = typeof allChannelsUnfiltered !== "undefined" ? allChannelsUnfiltered : CHANNELS;
  const vhs = (all.find((c) => c.name === "VHS VAULT") || {}).itemPool || [];
  return { total: allItemsCache.length, hidden: titles.filter((t) => /^Hidden Film/.test(t)).length, priv: titles.filter((t) => /^Private Film/.test(t)).length,
    vhsHidden: vhs.filter((i) => /^Hidden Film/.test(i.title)).length };
});
const openRow = (page) => page.evaluate(() => {
  showConfig();
  switchConfigTab("general");
  const row = document.getElementById("cfg-include-hidden-row");
  const b = document.getElementById("cfg-include-hidden-toggle");
  if (!row || !b) return { exists: false };
  b.scrollIntoView({ block: "center" });
  const r = b.getBoundingClientRect();
  const cs = getComputedStyle(b);
  const rowCs = getComputedStyle(row);
  return {
    exists: true, tag: b.tagName, type: b.type, text: b.textContent, pressed: b.getAttribute("aria-pressed"), label: b.getAttribute("aria-label"),
    title: row.querySelector(".cfg-row-title")?.textContent, line: row.querySelector(".cfg-row-desc")?.textContent,
    rowShown: !row.hidden && rowCs.display !== "none",
    shown: cs.display !== "none" && cs.visibility !== "hidden" && r.width > 0 && r.height > 0,
    inside: r.left >= 0 && r.right <= innerWidth + 0.5 && r.top >= 0 && r.bottom <= innerHeight + 0.5,
    afterOpenLast: row.previousElementSibling && row.previousElementSibling.querySelector("#cfg-open-last-toggle") !== null,
  };
});
const stored = (page) => page.evaluate(() => localStorage.getItem("nostalgex_include_hidden_libraries"));
const pressSwitch = async (page) => {
  await page.evaluate(() => { showConfig(); switchConfigTab("general"); });
  await page.click("#cfg-include-hidden-toggle", { timeout: 4000 }).catch(() => {});
};
// The read after a press runs in the background: wait for its first request, then for the scan to finish.
const reread = async (page, m) => {
  const until = Date.now() + 30000;
  while (log.views.length <= m.views && Date.now() < until) await page.waitForTimeout(100);
  await page.waitForTimeout(2200);
};

// ═══ Jellyfin, at the size of a TV browser ═══════════════════════════════════
{
  embyServer = false; flip = false;
  const { ctx, page, errors } = await openPage(960, 540);
  const first = await library(page);
  check("never chosen: the first scan asks exactly /UserViews?userId=u (the request it always was)", log.views.length === 1 && log.views[0] === "/UserViews?userId=u", JSON.stringify(log.views));
  check("never chosen: none of the hidden library's films is in the library, the 300 are", first.hidden === 0 && first.total === 300 && first.priv === 0, JSON.stringify(first));
  check("never chosen: the hidden library is not asked for items", !log.itemParents.includes("lib-hidden"));

  const s0 = await openRow(page);
  check("Settings > GENERAL has the switch, a real button, named", s0.exists && s0.tag === "BUTTON" && s0.type === "button" && s0.label === TITLE, JSON.stringify(s0));
  check("the row says what it does in the one plain line", s0.title === TITLE && s0.line === LINE, JSON.stringify([s0.title, s0.line]));
  check("it sits under OPEN ON LAST CHANNEL, in the same style (a cfg-row)", s0.afterOpenLast === true);
  check("it reads OFF and not pressed", s0.text === "OFF" && s0.pressed === "false", JSON.stringify(s0));
  check("on Jellyfin the row is shown, and the button is visible and inside the 960x540 screen", s0.rowShown && s0.shown && s0.inside, JSON.stringify(s0));
  if (shots) { await page.waitForTimeout(700); await page.screenshot({ path: join(shots, "include-hidden-960x540.png") }); }
  await page.evaluate(() => { hideConfig(); });

  // ON: a real mouse click, from a channel other than the first, with Settings open
  const enabled = await page.evaluate(() => CHANNELS.filter((c) => c.enabled).map((c) => c.id));
  check("the stub library puts at least two channels on the air", enabled.length >= 2, String(enabled.length));
  const other = enabled[1];
  await page.evaluate((id) => { tuneFromGuide(id); window.__tunes = []; const original = switchChannel; window.switchChannel = (...args) => { window.__tunes.push(args[0]); return original(...args); }; }, other);
  check("setup: the viewer is on a channel other than the first", (await page.evaluate(() => currentChannel)) === other && other !== enabled[0]);
  let m = mark();
  await pressSwitch(page);
  await reread(page, m);
  const afterOn = await library(page);
  const viewsOn = log.views.slice(m.views);
  check("pressing it saves '1'", (await stored(page)) === "1");
  check("pressing it reads the library again once, asking /UserViews?userId=u&includeHidden=true", viewsOn.length === 1 && viewsOn[0] === "/UserViews?userId=u&includeHidden=true", JSON.stringify(viewsOn));
  check("switch on: the hidden library's 20 films come in (320 titles)", afterOn.hidden === 20 && afterOn.total === 320, JSON.stringify(afterOn));
  check("switch on: the hidden films reach a channel's pool (VHS VAULT)", afterOn.vhsHidden > 0, JSON.stringify(afterOn));
  check("switch on: the library the user has no access to is never listed or asked for items", log.private.length === 0 && afterOn.priv === 0 && !log.itemParents.includes("lib-private"), JSON.stringify(log.private));
  const stay = await page.evaluate(() => ({ current: currentChannel, appState, configOpen: document.getElementById("config-overlay").classList.contains("open"), tunes: window.__tunes.slice(), loading: document.getElementById("loading-library").style.display }));
  check("after the read the viewer is still on the channel they were on (not retuned to the first)", stay.current === other && stay.tunes.length === 0, JSON.stringify(stay));
  check("after the read Settings is still open, and the loading screen did not come up", stay.appState === "config" && stay.configOpen === true && stay.loading === "none", JSON.stringify(stay));
  const s1 = await openRow(page);
  check("the button reads ON and pressed", s1.text === "ON" && s1.pressed === "true", JSON.stringify(s1));
  await page.evaluate(() => { hideConfig(); });

  // A reload restores the saved library: no request, still ON
  m = mark();
  await page.reload();
  await settled(page);
  check("a reload restores the saved library, with the hidden films, and asks the server for nothing", log.views.length === m.views && (await library(page)).hidden === 20, JSON.stringify({ views: log.views.length - m.views }));
  check("the switch is still ON after the reload", (await openRow(page)).text === "ON");
  await page.evaluate(() => { hideConfig(); });
  // With the saved library gone, the next scan reads the choice
  m = mark();
  await page.evaluate(() => { clearLibraryCache(); });
  await page.reload();
  await settled(page);
  const fresh = log.views.slice(m.views);
  check("with the saved library cleared, the next visit scans and asks for hidden libraries", fresh.length === 1 && fresh[0] === "/UserViews?userId=u&includeHidden=true" && (await library(page)).hidden === 20, JSON.stringify(fresh));

  // OFF again, from the same channel; two presses in one tick read once
  const channelNow = await page.evaluate(() => currentChannel);
  m = mark();
  await page.evaluate(() => { showConfig(); switchConfigTab("general"); window.__tunes = []; toggleIncludeHiddenLibraries(); toggleIncludeHiddenLibraries(); });
  await reread(page, m);
  const afterOff = await library(page);
  const viewsOff = log.views.slice(m.views);
  check("pressing it again saves '0'", (await stored(page)) === "0");
  check("two presses in a row read once, without includeHidden", viewsOff.length === 1 && viewsOff[0] === "/UserViews?userId=u", JSON.stringify(viewsOff));
  check("switch off again: the hidden films are gone (300 titles)", afterOff.hidden === 0 && afterOff.total === 300 && afterOff.vhsHidden === 0, JSON.stringify(afterOff));
  const stayOff = await page.evaluate(() => ({ current: currentChannel, appState, tunes: window.__tunes.slice() }));
  check("and the viewer is still on the same channel, Settings open", stayOff.current === channelNow && stayOff.tunes.length === 0 && stayOff.appState === "config", JSON.stringify(stayOff));
  check("the button reads OFF again", (await openRow(page)).text === "OFF");
  check("no page errors on Jellyfin", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// ═══ The one line: flipping the default ══════════════════════════════════════
{
  embyServer = false; flip = true;
  const never = await openPage(960, 540);
  check("default flipped, never chosen: the first scan asks for hidden libraries", log.views.length === 1 && log.views[0] === "/UserViews?userId=u&includeHidden=true" && (await library(never.page)).hidden === 20, JSON.stringify(log.views));
  const sOn = await openRow(never.page);
  check("default flipped, never chosen: the button reads ON", sOn.text === "ON" && sOn.pressed === "true", JSON.stringify(sOn));
  await never.ctx.close();
  const chosen = await openPage(960, 540, { seed: { nostalgex_include_hidden_libraries: "0" } });
  check("default flipped, a saved '0' still wins: no includeHidden, no hidden films", log.views.length === 1 && log.views[0] === "/UserViews?userId=u" && (await library(chosen.page)).hidden === 0, JSON.stringify(log.views));
  check("default flipped, a saved '0': the button reads OFF", (await openRow(chosen.page)).text === "OFF");
  await chosen.ctx.close();
  flip = false;
}

// ═══ Emby and Plex: no row, no parameter ═════════════════════════════════════
{
  embyServer = true;
  const emby = await openPage(960, 540, { backend: "emby", seed: { nostalgex_include_hidden_libraries: "1" } });
  check("Emby, key saved as '1': the request is /Users/u/Views, no includeHidden, nothing on /UserViews", log.views.length >= 1 && log.views.every((v) => v === "/Users/u/Views"), JSON.stringify(log.views));
  const e = await openRow(emby.page);
  check("Emby: the row is hidden", e.exists && e.rowShown === false, JSON.stringify(e));
  const plexRow = await emby.page.evaluate(() => { mediaBackend = "plex"; showConfig(); switchConfigTab("general"); const r = document.getElementById("cfg-include-hidden-row"); return r ? { hidden: r.hidden, display: getComputedStyle(r).display } : { hidden: false, display: "missing" }; });
  check("Plex: the row is hidden", plexRow.hidden === true && plexRow.display === "none", JSON.stringify(plexRow));
  const back = await emby.page.evaluate(() => { mediaBackend = "jellyfin"; showConfig(); switchConfigTab("general"); const r = document.getElementById("cfg-include-hidden-row"); return { hidden: r ? r.hidden : true }; });
  check("and shown again for Jellyfin", back.hidden === false);
  // Pressing the hidden button on a non-Jellyfin backend does nothing
  const before = log.views.length;
  await emby.page.evaluate(async () => { mediaBackend = "emby"; if (typeof toggleIncludeHiddenLibraries === "function") await toggleIncludeHiddenLibraries(); });
  check("pressing it on Emby changes nothing and reads nothing", log.views.length === before && (await stored(emby.page)) === "1");
  check("no page errors on Emby", emby.errors.length === 0, emby.errors.join(" | "));
  await emby.ctx.close();
  embyServer = false;
}

// ═══ A phone ════════════════════════════════════════════════════════════════
{
  const t = await openPage(390, 844);
  const r = await openRow(t.page);
  check("phone: the button is visible and inside the screen", r.exists && r.rowShown && r.shown && r.inside, JSON.stringify(r));
  await t.page.click("#cfg-include-hidden-toggle", { timeout: 4000 }).catch(() => {});
  await t.page.waitForTimeout(2500);
  check("phone: a tap turns it on", (await stored(t.page)) === "1");
  if (shots) { await t.page.evaluate(() => { showConfig(); switchConfigTab("general"); (document.getElementById("cfg-include-hidden-toggle") || document.body).scrollIntoView({ block: "center" }); }); await t.page.waitForTimeout(700); await t.page.screenshot({ path: join(shots, "include-hidden-390x844.png") }); }
  check("phone: no page errors", t.errors.length === 0, t.errors.join(" | "));
  await t.ctx.close();
}

await browser.close();
jellyfin.close();
files.close();
if (failures.length) {
  console.error(`include-hidden smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`include-hidden smoke: ${passed} checks passed (off by default and the request unchanged, on adds includeHidden and reads once, hidden films in and out, default flips with one line, Emby and Plex untouched, pressable at 960x540 and on a phone)`);
