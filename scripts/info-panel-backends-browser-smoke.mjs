#!/usr/bin/env node
/**
 * The guide's info panel is the same on Plex, Jellyfin and Emby (Chad 2026-11-15: "the user interface should be parity unless
 * absolute tech restrictions"), in the real plex-tuner.html (headless) against a Jellyfin-shaped stub that also answers image requests
 * the way each server does (and fails them on demand):
 *
 *   - the poster chain, first image that loads wins: a TV episode's season poster, then its series', then its own image; a film's own.
 *     Plex: /library/metadata/{season}/thumb, then {show}, then the item's thumb (through /photo/:/transcode). Jellyfin and Emby:
 *     /Items/{SeasonId}/Images/Primary, then {SeriesId}, then {ItemId}, each with ?maxWidth=300;
 *   - when every one fails the frame stays, empty, the same size and place: the text beside it never moves;
 *   - OPEN IN PLEX / JELLYFIN / EMBY is a link to the item in the server's own web app, in a new tab: Plex through app.plex.tv with
 *     the server's machine id, Jellyfin {server}/web/#/details?id=..&serverId=.., Emby {server}/web/index.html#!/item?id=..&serverId=..
 *     (the #! form: Emby 4.10.1.0's router, checked on a real server);
 *   - the help line under the details (what the focused rail control does) is gone: nothing says it, on hover or focus;
 *   - the panel's other fields (year, rating, star rating, description, episode title) come from the scan on every backend (the stub's
 *     Jellyfin and Emby films carry them).
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:info-panel-backends:browser`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

const TICKS = (min) => min * 60 * 10000000;
const films = Array.from({ length: 30 }, (_, i) => ({
  Id: `m${i}`, Name: `Family Day ${i}`, Type: "Movie", ProductionYear: 1986 + (i % 13), Genres: ["Family", "Comedy"], OfficialRating: "PG",
  Overview: `A story about day ${i}.`, RunTimeTicks: TICKS(95), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", CommunityRating: 7.2,
  MediaSources: [{ Id: `ms${i}`, Container: "mp4", RunTimeTicks: TICKS(95), Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Channels: 2, Index: 1 }] }],
}));
let okImages = new Set();      // ids whose picture the stub has
const asked = [];              // every image request, in order
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
let serverIdAnswers = 0;
const open = new Set();
const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  const image = (id) => { asked.push(req.url); if (okImages.has(id)) { res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "no-store" }); return res.end(PNG); } res.writeHead(404, { "Cache-Control": "no-store" }); return res.end(); };
  let m = /^\/Items\/([^/]+)\/Images\/Primary$/.exec(url.pathname);
  if (m) return image(decodeURIComponent(m[1]));
  if (url.pathname === "/photo/:/transcode") { const p = /^\/library\/metadata\/([^/]+)\/thumb/.exec(url.searchParams.get("url") || ""); return image(p ? p[1] : (url.searchParams.get("url") || "")); }
  if (url.pathname.startsWith("/Videos/")) { open.add(res); res.on("close", () => open.delete(res)); return; }
  res.writeHead(200, { "Content-Type": "application/json" });
  if (url.pathname === "/System/Info/Public") { serverIdAnswers++; return res.end(JSON.stringify({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "srv0123456789abcdef" })); }
  if (url.pathname === "/UserViews") return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.search.includes("IncludeItemTypes=Movie")) {
    const start = Number(url.searchParams.get("StartIndex") || 0), limit = Number(url.searchParams.get("Limit") || 200);
    return res.end(JSON.stringify({ Items: films.slice(start, start + limit), TotalRecordCount: films.length }));
  }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) body = Buffer.from(body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>"));
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
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
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
await ctx.addInitScript(([url]) => {
  if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
    sessionStorage.setItem("nx-seeded", "1");
    localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "TOK", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
  }
}, [api]);
const page = await ctx.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
await page.goto(`${base}/plex-tuner.html`);
await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
await page.waitForTimeout(1500);
await page.evaluate(() => { rebuildAllSchedules(); if (!guideVisible) { showGuide(); appState = "guide"; } renderGrid(); updateGuideFocus(); });
await page.waitForTimeout(300);
// From here the panel is driven by hand: the page's own timers must not put the live programme over a synthetic one.
await page.evaluate(() => { window.updateInfoPanel = () => {}; });

// What the poster element shows after `item` is handed to the panel on `backend`.
// The browser keeps a decoded image by its URL for the life of the document, so every call asks for ids of its own (a suffix).
let seq = 0;
async function poster(backend, plain, okPlain) {
  const tag = `_${++seq}`;
  const sfx = (k) => (k ? k + tag : k);
  const item = { ...plain, ratingKey: sfx(plain.ratingKey), showKey: sfx(plain.showKey), seasonKey: sfx(plain.seasonKey), thumb: plain.thumb ? plain.thumb.replace(/metadata\/([^/]+)\//, (m0, id) => `metadata/${id}${tag}/`) : plain.thumb };
  okImages = new Set(okPlain.map(sfx));
  asked.length = 0;
  await page.evaluate(([b, it, apiUrl]) => {
    mediaBackend = b; plexServerUrl = apiUrl; plexToken = "TOK"; if (b === "plex") selectedServers = [{ name: "lab", url: apiUrl, token: "TOK", machineIdentifier: "MACHINE1" }];
    const img = document.getElementById("info-poster");
    img.removeAttribute("data-key"); img.removeAttribute("src"); img.classList.remove("info-poster--empty");
    setInfoPoster(it);
  }, [backend, item, api]);
  await page.waitForFunction(() => { const img = document.getElementById("info-poster"); return img.classList.contains("info-poster--empty") || (img.getAttribute("src") && img.complete); }, null, { timeout: 5000 }).catch(() => {});
  await page.waitForTimeout(150);
  return page.evaluate(() => {
    const img = document.getElementById("info-poster"), text = document.querySelector(".info-text");
    const r = img.getBoundingClientRect();
    return { src: img.getAttribute("src"), empty: img.classList.contains("info-poster--empty"), w: r.width, h: r.height, textLeft: text.getBoundingClientRect().left, display: getComputedStyle(img).display, visibility: getComputedStyle(img).visibility, loaded: img.complete && img.naturalWidth > 0 };
  });
}
const episode = { ratingKey: "ep1", type: "episode", showKey: "sh1", seasonKey: "se1", thumb: "/library/metadata/ep1/thumb/99", title: "Show", serverUrl: undefined };
const film = { ratingKey: "film1", type: "movie", thumb: "/library/metadata/film1/thumb/77", title: "Film" };
const idOf = (src) => ((/\/Items\/([^/]+)\/Images/.exec(src || "") || /url=%2Flibrary%2Fmetadata%2F([^%]+)%2Fthumb/.exec(src || "") || [])[1] || "").replace(/_\d+$/, "");

let reservedW = null, reservedLeft = null;
for (const backend of ["jellyfin", "emby", "plex"]) {
  const label = backend;
  let r = await poster(backend, episode, ["se1", "sh1", "ep1"]);
  check(`${label}: an episode's poster is its season's first`, idOf(r.src) === "se1" && r.loaded, JSON.stringify(r));
  if (backend !== "plex") check(`${label}: asked for with ?maxWidth=300 and the sign-in`, /\?maxWidth=300&api_key=TOK$/.test(r.src), r.src);
  else check(`${label}: asked for through the transcoder at poster size with the token`, /photo\/:\/transcode\?width=300&height=450/.test(r.src) && /X-Plex-Token=TOK/.test(r.src), r.src);
  reservedW = reservedW ?? r.w; reservedLeft = reservedLeft ?? r.textLeft;
  r = await poster(backend, episode, ["sh1", "ep1"]);
  check(`${label}: no season picture: the series' is next`, idOf(r.src) === "sh1" && r.loaded, JSON.stringify(r));
  r = await poster(backend, episode, ["ep1"]);
  check(`${label}: neither: the episode's own image`, backend === "plex" ? /url=%2Flibrary%2Fmetadata%2Fep1_\d+%2Fthumb%2F99/.test(r.src || "") && r.loaded : idOf(r.src) === "ep1" && r.loaded, JSON.stringify(r));
  check(`${label}: the three were asked for in that order`, asked.length === 3 && idOf(asked[0]) === "se1" && idOf(asked[1]) === "sh1", asked.join(" | "));
  r = await poster(backend, episode, []);
  check(`${label}: every one failing leaves an empty frame, the same size and place`, r.empty && !r.src && r.display !== "none" && Math.abs(r.w - reservedW) < 0.5 && Math.abs(r.textLeft - reservedLeft) < 0.5, JSON.stringify({ ...r, reservedW, reservedLeft }));
  r = await poster(backend, film, ["film1", "se1", "sh1"]);
  check(`${label}: a film's own poster only`, (backend === "plex" ? /film1_\d+/.test(r.src || "") : idOf(r.src) === "film1") && asked.length === 1, JSON.stringify([r.src, asked.length]));
}

// OPEN IN: the link to the item in the server's own web app.
const link = async (backend, item) => {
  await page.evaluate(([b, it, apiUrl]) => {
    mediaBackend = b; plexServerUrl = apiUrl; plexToken = "TOK";
    selectedServers = [{ name: "lab", url: apiUrl, token: "TOK", machineIdentifier: "MACHINE1" }];
    updateOpenInLink(it);
  }, [backend, item, api]);
  await page.waitForTimeout(400);
  return page.evaluate(() => { const a = document.getElementById("info-open-in"); return { hidden: a.hidden, text: a.textContent, href: a.getAttribute("href"), target: a.target, rel: a.rel }; });
};
let l = await link("plex", episode);
check("plex: OPEN IN PLEX, the item in Plex Web for that server, in a new tab", !l.hidden && l.text === "OPEN IN PLEX" && l.href === "https://app.plex.tv/desktop/#!/server/MACHINE1/details?key=%2Flibrary%2Fmetadata%2Fep1" && l.target === "_blank" && /noopener/.test(l.rel), JSON.stringify(l));
l = await link("jellyfin", episode);
check("jellyfin: OPEN IN JELLYFIN, the item in the server's web app, with the server's id", !l.hidden && l.text === "OPEN IN JELLYFIN" && l.href === `${api}/web/#/details?id=ep1&serverId=srv0123456789abcdef` && l.target === "_blank", JSON.stringify(l));
l = await link("emby", episode);
check("emby: OPEN IN EMBY, the #! form Emby's router takes, with the server's id", !l.hidden && l.text === "OPEN IN EMBY" && l.href === `${api}/web/index.html#!/item?id=ep1&serverId=srv0123456789abcdef` && l.target === "_blank", JSON.stringify(l));
check("the server's id was asked for once (its public info), not per programme", serverIdAnswers <= 2, String(serverIdAnswers));
l = await page.evaluate(() => { mediaBackend = "plex"; selectedServers = []; updateOpenInLink({ ratingKey: "x", type: "movie" }); const a = document.getElementById("info-open-in"); return { hidden: a.hidden, href: a.getAttribute("href") }; });
check("plex: with no machine id for the server there is no link", l.hidden && l.href === null, JSON.stringify(l));
l = await page.evaluate(() => { mediaBackend = "jellyfin"; plexServerUrl = "not a url"; updateOpenInLink({ ratingKey: "x", type: "movie" }); return { hidden: document.getElementById("info-open-in").hidden }; });
check("jellyfin: an address that is not http(s) gets no link", l.hidden);

// The help line is gone: hovering or focusing the rail says nothing under the details.
await page.evaluate((u) => { mediaBackend = "jellyfin"; plexServerUrl = u; }, api);
const hint = await page.evaluate(async () => {
  const btn = document.querySelector("#v-toolbar .v-btn");
  const before = document.getElementById("info-hint");
  if (btn) { btn.dispatchEvent(new MouseEvent("mouseover", { bubbles: true })); btn.focus(); }
  await new Promise((r) => setTimeout(r, 200));
  return { element: !!before, other: [...document.querySelectorAll(".info-hint")].length, text: [...document.querySelectorAll(".info-panel *")].some((e) => /^(Bundles, servers, language and the rest|Show this channel without the guide|Turn the sound on or off)/.test(e.textContent || "")) };
});
check("the rail's help line under the details is gone", !hint.element && hint.other === 0 && !hint.text, JSON.stringify(hint));

// The fields the panel shows come from the scan on a non-Plex server too.
const fields = await page.evaluate(() => { mediaBackend = "jellyfin"; const it = allItemsCache.find((i) => i.type === "movie"); return { year: !!it.year, rating: !!it.contentRating, star: !!it.rating, summary: !!it.summary, thumb: it.thumb, exact: typeof it.exactDurationSeconds }; });
check("a Jellyfin film carries year, rating, star rating and description into the panel", fields.year && fields.rating && fields.star && fields.summary, JSON.stringify(fields));

check("no page errors", errors.length === 0, errors.join(" | "));
await ctx.close();
await browser.close();
server.close(); files.close();
if (failures.length) {
  console.error(`info panel on every backend (browser): ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`info panel on every backend (browser): ${passed} checks passed`);
process.exit(0);
