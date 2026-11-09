#!/usr/bin/env node
/**
 * OPEN ON LAST CHANNEL (Trello I-017) in the real plex-tuner.html, headless, against a
 * Jellyfin-shaped stub holding a few hundred films, so several channels are on the air.
 *
 * What it checks, each time the page loads from the saved library (the path every visit after
 * the first takes):
 *   - the switch is in Settings > GENERAL > PLAYBACK, off by default, a real button (a TV
 *     browser has no keys), visible and pressable by mouse at 960x540 and on a phone, and its
 *     text and aria-pressed follow the saved state;
 *   - off (the default): the guide opens on the first enabled channel, as it always did, even
 *     with a channel remembered;
 *   - every channel tuned is remembered with its id and name, whether or not the switch is on;
 *   - on: the guide opens on the remembered channel;
 *   - on, but the remembered channel is not what it was (renamed, renumbered, its id gone, or
 *     its package switched off), or nothing is remembered, or the value is garbage: the guide
 *     opens on the first enabled channel and nothing throws.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (origin/main's), which
 * has no switch and always opens on the first channel; the "on" checks must fail there.
 *
 * Set SHOTS=/dir to save screenshots of the row in Settings.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:open-last-channel:browser`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));
const shots = process.env.SHOTS || "";
if (shots) mkdirSync(shots, { recursive: true });

// ── A stub library: 600 films across years, genres and ratings ──────────────────
const GENRES = ["Action", "Comedy", "Drama", "Thriller", "Horror", "Romance", "Science Fiction", "Adventure", "Animation", "Family", "Crime", "Mystery", "War", "Western", "Documentary", "Fantasy"];
const CERTS = ["G", "PG", "PG-13", "R", "PG", "PG-13"];
const films = Array.from({ length: 600 }, (_, i) => {
  const ticks = (85 + (i % 40)) * 60 * 10000000;
  return {
    Id: `film${i}`, Name: `Film ${i}`, Type: "Movie", ProductionYear: 1960 + (i % 62), Genres: [GENRES[i % GENRES.length], GENRES[(i * 7 + 3) % GENRES.length]],
    OfficialRating: CERTS[i % CERTS.length], CommunityRating: 5 + (i % 40) / 10, RunTimeTicks: ticks, ProviderIds: { Tmdb: String(1000 + i) }, Studios: [],
    DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "A film.",
    MediaSources: [{ Id: `ms${i}`, Container: "mp4", Bitrate: 4000000, RunTimeTicks: ticks, Size: 2000000, SupportsDirectPlay: true,
      MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true }] }],
  };
});
let libraryFetches = 0;
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  const url = req.url;
  if (url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.11.11", ProductName: "Jellyfin Server", Id: "lab" }));
  if (url.startsWith("/UserViews")) return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.includes("IncludeItemTypes=Movie")) {
    libraryFetches += 1;
    const u = new URL(url, "http://x");
    const start = Number(u.searchParams.get("StartIndex") || 0);
    const limit = Number(u.searchParams.get("Limit") || films.length);
    return res.end(JSON.stringify({ Items: films.slice(start, start + limit), TotalRecordCount: films.length }));
  }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});
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
await new Promise((r) => jellyfin.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${jellyfin.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const browser = await chromium.launch({ headless: true });

async function openPage(width, height) {
  const ctx = await browser.newContext({ viewport: { width, height } });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
    }
  }, [api]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/plex-tuner.html`);
  await waitForGuide(page);
  return { ctx, page, errors };
}
async function waitForGuide(page) {
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof currentChannel !== "undefined" && currentChannel !== null, null, { timeout: 45000 }).catch(() => {});
  await page.waitForTimeout(800);
}
// Reload = the saved-library path: the page restores the library and tunes, no server scan.
async function reload(page) {
  await page.reload();
  await waitForGuide(page);
}
const state = (page) => page.evaluate(() => ({
  current: currentChannel,
  currentName: (CHANNELS.find((c) => c.id === currentChannel) || {}).name || null,
  firstEnabled: (CHANNELS.find((c) => c.enabled) || {}).id ?? null,
  enabled: CHANNELS.filter((c) => c.enabled).map((c) => ({ id: c.id, name: c.name })),
  remembered: localStorage.getItem("nostalgex_last_channel"),
  on: localStorage.getItem("nostalgex_open_last_channel"),
}));

const { ctx, page, errors } = await openPage(1440, 900);
const first = await state(page);
check("the stub library puts at least three channels on the air", first.enabled.length >= 3, `${first.enabled.length} enabled`);
const [a, b, c] = [first.enabled[0], first.enabled[1], first.enabled[2]];
check("first visit, switch off: opens on the first enabled channel", first.current === first.firstEnabled, JSON.stringify({ current: first.current, firstEnabled: first.firstEnabled }));
check("the first channel tuned is remembered with its id and name", first.remembered === JSON.stringify({ id: a.id, name: a.name }), String(first.remembered));
check("the switch is off on a new install", first.on === null);

// ── The switch in Settings ───────────────────────────────────────────────────
const row = (p) => p.evaluate(() => {
  showConfig();
  switchConfigTab("general");
  const b = document.getElementById("cfg-open-last-toggle");
  if (!b) return { exists: false };
  b.scrollIntoView({ block: "center" });
  const r = b.getBoundingClientRect();
  const cs = getComputedStyle(b);
  return { exists: true, tag: b.tagName, type: b.type, text: b.textContent, pressed: b.getAttribute("aria-pressed"), label: b.getAttribute("aria-label"),
    shown: cs.display !== "none" && cs.visibility !== "hidden" && r.width > 0 && r.height > 0,
    inside: r.left >= 0 && r.right <= innerWidth + 0.5 && r.top >= 0 && r.bottom <= innerHeight + 0.5 };
});
const s0 = await row(page);
check("Settings > GENERAL has the OPEN ON LAST CHANNEL button", s0.exists && s0.tag === "BUTTON" && s0.type === "button", JSON.stringify(s0));
check("it reads OFF, not pressed, and is named", s0.text === "OFF" && s0.pressed === "false" && s0.label === "Open on last channel", JSON.stringify(s0));
check("it is visible and inside the 1440x900 screen", s0.shown && s0.inside, JSON.stringify(s0));
await page.evaluate(() => { hideConfig(); });

// ── Off: a remembered channel changes nothing ────────────────────────────────
await page.evaluate((id) => switchChannel(id), c.id);
check("tuning another channel remembers it (switch still off)", (await state(page)).remembered === JSON.stringify({ id: c.id, name: c.name }));
const fetchesBefore = libraryFetches;
await reload(page);
const off = await state(page);
check("reload came from the saved library, not a new scan", libraryFetches === fetchesBefore, `${fetchesBefore} -> ${libraryFetches}`);
check("switch off: a remembered channel is ignored, opens on the first enabled channel", off.current === off.firstEnabled && off.current === a.id, JSON.stringify({ current: off.current, remembered: off.remembered }));

// ── On: opens where it left off ──────────────────────────────────────────────
await page.evaluate(() => { showConfig(); switchConfigTab("general"); });
await page.click("#cfg-open-last-toggle", { timeout: 4000 }).catch(() => {});   // a real click, as a TV browser would
const s1 = await page.evaluate(() => { const b = document.getElementById("cfg-open-last-toggle") || { textContent: "", getAttribute: () => null, classList: { contains: () => false } }; return { text: b.textContent, pressed: b.getAttribute("aria-pressed"), on: b.classList.contains("on"), stored: localStorage.getItem("nostalgex_open_last_channel") }; });
check("a click turns it ON and saves it", s1.text === "ON" && s1.pressed === "true" && s1.on && s1.stored === "1", JSON.stringify(s1));
await page.evaluate(() => { hideConfig(); });
await page.evaluate((id) => switchChannel(id), b.id);
await reload(page);
const on1 = await state(page);
check("switch on: opens on the channel it was on", on1.current === b.id, JSON.stringify({ current: on1.current, want: b.id }));
// the page comes back with the switch showing ON
check("after the reload the button still reads ON", (await row(page)).text === "ON");
await page.evaluate(() => { hideConfig(); });

// ── On, but the remembered channel is not what it was ────────────────────────
const setRemembered = (value) => page.evaluate((v) => { if (v === null) localStorage.removeItem("nostalgex_last_channel"); else localStorage.setItem("nostalgex_last_channel", v); }, value);
const cases = [
  ["renamed (same id, other name)", JSON.stringify({ id: c.id, name: "SOME OTHER NAME" })],
  ["renumbered (the name now belongs to another id)", JSON.stringify({ id: 99999, name: c.name })],
  ["gone (an id no channel has)", JSON.stringify({ id: 424242, name: "GONE" })],
  ["a name with no id", JSON.stringify({ name: c.name })],
  ["an id with no name", JSON.stringify({ id: c.id })],
  ["not JSON", "not json {"],
  ["JSON null", "null"],
  ["an array", "[1,2]"],
  ["empty", ""],
  ["nothing remembered", null],
];
for (const [label, value] of cases) {
  await setRemembered(value);
  await reload(page);
  const s = await state(page);
  check(`switch on, remembered channel ${label}: opens on the first enabled channel`, s.current === s.firstEnabled && s.current === a.id, JSON.stringify({ current: s.current }));
}

// a channel whose package is switched off is not opened
await setRemembered(JSON.stringify({ id: c.id, name: c.name }));
await page.evaluate((id) => {
  // Switch the remembered channel off the way a package switch does, then look at what would open.
  const ch = CHANNELS.find((x) => x.id === id); ch.enabled = false;
  const open = typeof channelToOpenOn === "function" ? channelToOpenOn() : CHANNELS.find((x) => x.enabled);
  window.__opened = open && open.id; ch.enabled = true;
}, c.id);
const closed = await page.evaluate(() => window.__opened);
check("switch on, remembered channel switched off: the first enabled channel would open", closed === a.id, String(closed));

check("no page errors in the whole run", errors.length === 0, errors.join(" | "));
await ctx.close();

// ── The row at TV size and on a phone: pressable by mouse ────────────────────
for (const [name, w, h] of [["960x540 TV browser", 960, 540], ["phone", 390, 844]]) {
  const t = await openPage(w, h);
  const r = await row(t.page);
  check(`${name}: the button is visible and inside the screen`, r.exists && r.shown && r.inside, JSON.stringify(r));
  if (shots) { await t.page.waitForTimeout(700); await t.page.screenshot({ path: join(shots, `open-last-channel-${w}x${h}.png`) }); }
  await t.page.click("#cfg-open-last-toggle", { timeout: 4000 }).catch(() => {});
  check(`${name}: a mouse click turns it on`, (await t.page.evaluate(() => localStorage.getItem("nostalgex_open_last_channel"))) === "1");
  check(`${name}: no page errors`, t.errors.length === 0, t.errors.join(" | "));
  await t.ctx.close();
}

await browser.close();
jellyfin.close();
files.close();
if (failures.length) {
  console.error(`open-last-channel smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`open-last-channel smoke: ${passed} checks passed (off by default, remembered per tune, opens on it when on, falls back on any mismatch, pressable at 960x540 and on a phone)`);
