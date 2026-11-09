#!/usr/bin/env node
/**
 * OPEN ON LAST CHANNEL (Trello I-017) in the real plex-tuner.html, headless, against a
 * Jellyfin-shaped stub holding a few hundred films, so several channels are on the air.
 *
 * What it checks, each time the page loads from the saved library (the path every visit after
 * the first takes):
 *   - the switch is in Settings > GENERAL > PLAYBACK, ON by default (Chad's decision of 2026-11-09),
 *     with the Apple TV's one line under it, a real button (a TV browser has no keys), visible and
 *     pressable by mouse at 960x540 and on a phone, and its text and aria-pressed follow the saved state;
 *   - a viewer with nothing remembered still gets the first enabled channel, switch on or off;
 *   - a browser that never chose (nothing stored) opens on the remembered channel, and opening does not
 *     write the switch, so the default stays a default;
 *   - a browser that already chose keeps its own choice: a stored 0 (switched off on 1.0.15) stays off
 *     across loads, a stored 1 stays on, and only a browser that never chose takes the new default;
 *   - off: the guide opens on the first enabled channel, as it always did, even with a channel remembered;
 *   - a channel the VIEWER tunes (a pick in the guide, channel up or down, a number key) is remembered with its
 *     id and name, whether or not the switch is on; a tune the page makes itself (the first channel after a
 *     load) is not, so a saved channel that is not in the lineup yet is not replaced by the first channel;
 *   - signing out clears the remembered channel, and leaves the switch as it was (never chose stays never chose);
 *   - on, but the remembered channel is not what it was (renamed, renumbered, its id gone, or
 *     its package switched off), or nothing is remembered, or the value is garbage: the guide
 *     opens on the first enabled channel and nothing throws.
 * Negative control: NX_TUNER_HTML=/path and NX_LAST_CHANNEL_JS=/path serve another copy of the page and of
 * scripts/nostalgex-last-channel.js (origin/main's, 1.0.15, where the switch defaults to off); the
 * "default on" checks must fail there.
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
  if (p.endsWith("scripts/nostalgex-last-channel.js") && process.env.NX_LAST_CHANNEL_JS) body = readFileSync(process.env.NX_LAST_CHANNEL_JS);
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

// seed = extra localStorage items set before the first load only (what a browser that ran 1.0.15 would hold).
async function openPage(width, height, seed = {}) {
  const ctx = await browser.newContext({ viewport: { width, height } });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url, extra]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
      for (const [k, v] of Object.entries(extra)) localStorage.setItem(k, v);
    }
  }, [api, seed]);
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
check("first visit, switch on by default, nothing remembered: still opens on the first enabled channel", first.current === first.firstEnabled && first.current === a.id, JSON.stringify({ current: first.current, firstEnabled: first.firstEnabled }));
check("the channel the page tuned on its own after the load is not remembered", first.remembered === null, String(first.remembered));
check("a new install has never written the switch (the default is a default, not a stored choice)", first.on === null, String(first.on));

// ── The switch in Settings ───────────────────────────────────────────────────
const row = (p) => p.evaluate(() => {
  showConfig();
  switchConfigTab("general");
  const b = document.getElementById("cfg-open-last-toggle");
  if (!b) return { exists: false };
  b.scrollIntoView({ block: "center" });
  const r = b.getBoundingClientRect();
  const cs = getComputedStyle(b);
  return { exists: true, tag: b.tagName, type: b.type, text: b.textContent, pressed: b.getAttribute("aria-pressed"), on: b.classList.contains("on"), label: b.getAttribute("aria-label"),
    line: b.closest(".cfg-row")?.querySelector(".cfg-row-desc")?.textContent,
    shown: cs.display !== "none" && cs.visibility !== "hidden" && r.width > 0 && r.height > 0,
    inside: r.left >= 0 && r.right <= innerWidth + 0.5 && r.top >= 0 && r.bottom <= innerHeight + 0.5 };
});
const s0 = await row(page);
check("Settings > GENERAL has the OPEN ON LAST CHANNEL button", s0.exists && s0.tag === "BUTTON" && s0.type === "button", JSON.stringify(s0));
check("it reads ON by default, pressed, and is named", s0.text === "ON" && s0.pressed === "true" && s0.on === true && s0.label === "Open on last channel", JSON.stringify(s0));
check("the line under it is the Apple TV's one line, no second sentence", s0.line === "Start on the channel you were last watching", JSON.stringify(s0.line));
check("it is visible and inside the 1440x900 screen", s0.shown && s0.inside, JSON.stringify(s0));
await page.evaluate(() => { hideConfig(); });

// ── Who tuned: only the viewer's tunes are remembered ────────────────────────
const remembered = (p) => p.evaluate(() => localStorage.getItem("nostalgex_last_channel"));
const entry = (ch) => JSON.stringify({ id: ch.id, name: ch.name });
await page.evaluate((id) => tuneFromGuide(id), c.id);
check("a pick in the guide is remembered (switch still at its default)", (await remembered(page)) === entry(c), String(await remembered(page)));
await page.evaluate((id) => { switchChannel(id); }, a.id);   // the page's own tune: no byViewer
check("a tune the page makes itself changes the channel but not what is remembered", (await state(page)).current === a.id && (await remembered(page)) === entry(c), String(await remembered(page)));
await page.evaluate(() => nextChannel());
check("channel up is remembered", (await state(page)).current === b.id && (await remembered(page)) === entry(b), String(await remembered(page)));
await page.evaluate(() => prevChannel());
check("channel down is remembered", (await state(page)).current === a.id && (await remembered(page)) === entry(a), String(await remembered(page)));
const digit = first.enabled.find((ch) => ch.id >= 1 && ch.id <= 9 && ch.id !== a.id);
if (digit) {
  await page.keyboard.press(String(digit.id));
  await page.waitForTimeout(300);
  check(`the number key ${digit.id} is remembered`, (await state(page)).current === digit.id && (await remembered(page)) === entry(digit), JSON.stringify([await state(page).then((s) => s.current), await remembered(page)]));
}
await page.evaluate((id) => tuneFromGuide(id), c.id);
check("back to a pick in the guide: c is what is remembered", (await remembered(page)) === entry(c));
const fetchesBefore = libraryFetches;
await reload(page);
const dflt = await state(page);
check("reload came from the saved library, not a new scan", libraryFetches === fetchesBefore, `${fetchesBefore} -> ${libraryFetches}`);
check("switch at its default (on): the guide opens on the channel the viewer was last on", dflt.current === c.id, JSON.stringify({ current: dflt.current, want: c.id }));
check("opening on the remembered channel does not write the switch", dflt.on === null, String(dflt.on));
check("after the reload the button still reads ON", (await row(page)).text === "ON");
await page.evaluate(() => { hideConfig(); });

// ── Off: a click stores the choice, and a remembered channel changes nothing ─
const toggle = async () => {
  await page.evaluate(() => { showConfig(); switchConfigTab("general"); });
  await page.click("#cfg-open-last-toggle", { timeout: 4000 }).catch(() => {});   // a real click, as a TV browser would
  const s = await page.evaluate(() => { const b = document.getElementById("cfg-open-last-toggle") || { textContent: "", getAttribute: () => null, classList: { contains: () => false } }; return { text: b.textContent, pressed: b.getAttribute("aria-pressed"), on: b.classList.contains("on"), stored: localStorage.getItem("nostalgex_open_last_channel") }; });
  await page.evaluate(() => { hideConfig(); });
  return s;
};
const s1 = await toggle();
check("a click turns it OFF and saves the choice as 0", s1.text === "OFF" && s1.pressed === "false" && !s1.on && s1.stored === "0", JSON.stringify(s1));
await reload(page);
const off = await state(page);
check("switch off: a remembered channel is ignored, opens on the first enabled channel", off.current === off.firstEnabled && off.current === a.id, JSON.stringify({ current: off.current, remembered: off.remembered }));
check("a stored 0 stays 0 across a load, and the button still reads OFF", off.on === "0" && (await row(page)).text === "OFF", String(off.on));
await page.evaluate(() => { hideConfig(); });

// ── On again: a stored 1 opens where it left off ─────────────────────────────
const s2 = await toggle();
check("a second click turns it ON and saves it as 1", s2.text === "ON" && s2.pressed === "true" && s2.on && s2.stored === "1", JSON.stringify(s2));
await page.evaluate((id) => tuneFromGuide(id), b.id);
await reload(page);
const on1 = await state(page);
check("switch on: opens on the channel it was on", on1.current === b.id, JSON.stringify({ current: on1.current, want: b.id }));
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

// ── A saved channel that is not in the lineup yet is not replaced by the first channel ──
// (its package off, a collection channel not built yet). With the switch on, off, or never chosen, the load tunes
// the first channel by itself; that is not a tune the viewer made, so the saved channel stays.
const notThere = JSON.stringify({ id: 424242, name: "NOT BUILT YET" });
const setSwitch = (v) => page.evaluate((x) => { if (x === null) localStorage.removeItem("nostalgex_open_last_channel"); else localStorage.setItem("nostalgex_open_last_channel", x); }, v);
for (const [position, stored] of [["on", "1"], ["off", "0"], ["at its default", null]]) {
  await setSwitch(stored);
  await setRemembered(notThere);
  await reload(page);
  const s = await state(page);
  check(`switch ${position}, a saved channel that is not in the lineup: the first channel opens and the saved channel is kept`, s.current === a.id && s.remembered === notThere, JSON.stringify({ current: s.current, remembered: s.remembered }));
}

// a switch nobody has touched (default on) behaves the same on a mismatch
await setSwitch(null);
await setRemembered(JSON.stringify({ id: c.id, name: "SOME OTHER NAME" }));
await reload(page);
const dfltMismatch = await state(page);
check("switch at its default, remembered channel renamed: opens on the first enabled channel", dfltMismatch.current === a.id, JSON.stringify({ current: dfltMismatch.current }));

// ── Signing out clears the remembered channel, and leaves the switch as it was ──
for (const [label, stored] of [["a stored 0", "0"], ["a stored 1", "1"]]) {
  const t = await openPage(1440, 900, { nostalgex_open_last_channel: stored, nostalgex_last_channel: entry(c) });
  await t.page.evaluate(() => { signOut(); });
  const o = await state(t.page);
  check(`signing out clears the remembered channel (${label})`, o.remembered === null, String(o.remembered));
  check(`signing out leaves the switch alone (${label})`, o.on === stored, String(o.on));
  await t.ctx.close();
}
{
  const t = await openPage(1440, 900);
  await t.page.evaluate(() => { signOut(); });
  const o = await state(t.page);
  check("signing out leaves a switch that was never chosen never chosen", o.on === null, String(o.on));
  await t.ctx.close();
}

check("no page errors in the whole run", errors.length === 0, errors.join(" | "));
await ctx.close();

// ── Browsers that already hold a choice from 1.0.15 keep it; only a browser that never chose flips ──
// (1.0.15 remembered the channel whether the switch was on or off, so a never-chosen browser has one.)
{
  const off15 = await openPage(1440, 900, { nostalgex_open_last_channel: "0", nostalgex_last_channel: entry(c) });
  const so = await state(off15.page);
  check("a browser that switched it off on 1.0.15 (stored 0) stays off: opens on the first channel, not the remembered one", so.current === a.id && so.on === "0", JSON.stringify({ current: so.current, on: so.on }));
  check("... and its button reads OFF", (await row(off15.page)).text === "OFF");
  await off15.ctx.close();

  const on15 = await openPage(1440, 900, { nostalgex_open_last_channel: "1", nostalgex_last_channel: entry(c) });
  const sn = await state(on15.page);
  check("a browser that switched it on on 1.0.15 (stored 1) stays on: opens on the remembered channel", sn.current === c.id && sn.on === "1", JSON.stringify({ current: sn.current, on: sn.on }));
  await on15.ctx.close();

  const never15 = await openPage(1440, 900, { nostalgex_last_channel: entry(c) });
  const sv = await state(never15.page);
  check("a browser that never chose, holding a channel 1.0.15 remembered, now opens on it", sv.current === c.id && sv.on === null, JSON.stringify({ current: sv.current, on: sv.on }));
  check("... and its button reads ON", (await row(never15.page)).text === "ON");
  check("... with no page errors", never15.errors.length === 0, never15.errors.join(" | "));
  await never15.ctx.close();
}

// ── The row at TV size and on a phone: pressable by mouse ────────────────────
for (const [name, w, h] of [["960x540 TV browser", 960, 540], ["phone", 390, 844]]) {
  const t = await openPage(w, h);
  const r = await row(t.page);
  check(`${name}: the button is visible and inside the screen`, r.exists && r.shown && r.inside, JSON.stringify(r));
  if (shots) { await t.page.waitForTimeout(700); await t.page.screenshot({ path: join(shots, `open-last-channel-${w}x${h}.png`) }); }
  check(`${name}: it reads ON before the click`, r.text === "ON" && r.pressed === "true", JSON.stringify(r));
  await t.page.click("#cfg-open-last-toggle", { timeout: 4000 }).catch(() => {});
  const after = await t.page.evaluate(() => ({ stored: localStorage.getItem("nostalgex_open_last_channel"), text: document.getElementById("cfg-open-last-toggle").textContent }));
  check(`${name}: a mouse click turns it off, and a second click turns it back on`, after.stored === "0" && after.text === "OFF", JSON.stringify(after));
  await t.page.click("#cfg-open-last-toggle", { timeout: 4000 }).catch(() => {});
  const again = await t.page.evaluate(() => ({ stored: localStorage.getItem("nostalgex_open_last_channel"), text: document.getElementById("cfg-open-last-toggle").textContent }));
  check(`${name}: the second click saves 1 and reads ON`, again.stored === "1" && again.text === "ON", JSON.stringify(again));
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
console.log(`open-last-channel smoke: ${passed} checks passed (on by default, a stored choice is kept, remembered per tune, falls back on any mismatch and with nothing remembered, pressable at 960x540 and on a phone)`);
