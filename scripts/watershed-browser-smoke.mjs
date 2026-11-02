#!/usr/bin/env node
/**
 * WATERSHED in the real page: the Settings switch, the guide row and the 9 PM card.
 *
 * scripts/nostalgex-watershed-smoke.mjs holds the engine to the Apple TV's golden file. This
 * loads the real plex-tuner.html, headless, against a Jellyfin-shaped server, with the clock
 * pinned to 2 PM, and drives what a viewer does:
 *
 *   - the switch is in Settings > GENERAL, says the Apple TV's words, is OFF on a new install
 *     and writes `nostalgex_watershed` ('1' on), which the engine reads;
 *   - on, a channel that is nothing but R-rated titles shows BROADCASTS RESUME AT 9 PM in the
 *     guide and the card when tuned; a mixed channel keeps airing without its R titles;
 *     VHS VAULT, which holds R on its own, is untouched;
 *   - a programme already playing finishes (the Apple TV does the same); the card goes up when
 *     it ends;
 *   - OPEN SETTINGS on the card reaches the switch; switching off, or the clock passing 9 PM,
 *     clears the card and tunes the channel; midnight closes the gate again;
 *   - the words match the Swift source, and the card and the switch work by click alone at
 *     phone, tablet, desktop and 960x540 (a TV browser has no keys), never in browser full
 *     screen.
 *
 * Set SHOTS=/dir to save the 960x540 and phone screenshots. TUNER_ROOT=/path/to/dist (or
 * dist-selfhost) runs the same checks on a build, so hosted and Docker are both covered. NX_TUNER_HTML=/path serves
 * another copy of the page (origin/main's, for the negative control) in place of
 * plex-tuner.html; it must fail.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:watershed:browser`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const repo = fileURLToPath(new URL("../", import.meta.url));
// TUNER_ROOT serves another build of the tuner (dist, dist-selfhost) instead of this checkout.
const root = process.env.TUNER_ROOT ? process.env.TUNER_ROOT.replace(/\/?$/, "/") : repo;
const shots = process.env.SHOTS || "";
if (shots) mkdirSync(shots, { recursive: true });

// The Apple TV's words: WatershedCard.swift, ChannelGuideView.swift, SettingsChannelsView.swift.
const CARD_TITLE = "BROADCASTS WILL RESUME AT 9 PM";
const CARD_DETAIL = "This channel's 18 and R-rated titles wait for 9 PM, like broadcast TV. Everything in its pool right now falls in that window.";
const CARD_HINT = "Turn off Watershed in Settings to watch now.";
const GUIDE_LABEL = "BROADCASTS RESUME AT 9 PM";
const ROW_DESC = "18 and R-rated titles wait until 9 PM";

// ── The server: Jellyfin-shaped. 14 horror films (all R), 14 comedies (every other one R),
// 14 family comedies (PG). With the SCREAM package on, FRIGHT NIGHT (CH 181) and NOSTALGEX
// HORROR (CH 183) hold only R titles; NOSTALGEX LOL (CH 3) is mixed; VHS VAULT (CH 7) is the
// channel that already holds R until 9 PM on its own. ──
const TICKS = (min) => min * 60 * 10000000;
const items = [];
function add(name, year, genres, rating) {
  const i = items.length;
  items.push({
    Id: `m${i}`, Name: name, Type: "Movie", ProductionYear: year, Genres: genres, OfficialRating: rating,
    RunTimeTicks: TICKS(95), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", CommunityRating: 7.2,
    MediaSources: [{ Id: `ms${i}`, Container: "mp4", RunTimeTicks: TICKS(95), Size: 2000000, SupportsDirectPlay: true,
      MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Channels: 2, Index: 1 }] }],
  });
}
for (let i = 0; i < 14; i++) add(`Night Terror ${i}`, 1984 + i, ["Horror"], "R");
for (let i = 0; i < 14; i++) add(`Funny Business ${i}`, 1985 + i, ["Comedy"], i % 2 ? "PG-13" : "R");
for (let i = 0; i < 14; i++) add(`Family Day ${i}`, 1986 + i, ["Family", "Comedy"], "PG");
const ratingOf = new Map(items.map((m) => [m.Name, m.OfficialRating]));
const idOfTitle = new Map(items.map((m) => [m.Name, m.Id]));
const isAdultTitle = (t) => ["R", "NC-17", "TV-MA"].includes(ratingOf.get(t));
const isAdultId = (id) => { const m = items.find((x) => x.Id === id); return !!m && ["R", "NC-17", "TV-MA"].includes(m.OfficialRating); };

const open = new Set();
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = req.url;
  // The picture never arrives. A video left loading has no error to recover from, so what
  // is "playing" stays put for the checks below.
  if (url.startsWith("/Videos/")) { open.add(res); res.on("close", () => open.delete(res)); return; }
  res.writeHead(200, { "Content-Type": "application/json" });
  if (url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
  if (url.startsWith("/UserViews")) return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.includes("IncludeItemTypes=Movie")) {
    const q = new URL(url, "http://x").searchParams;
    const start = Number(q.get("StartIndex") || 0);
    const limit = Number(q.get("Limit") || 200);
    return res.end(JSON.stringify({ Items: items.slice(start, start + limit), TotalRecordCount: items.length }));
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
    body = Buffer.from(body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>"));
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

const FRIGHT = 141;   // CH 181, all R
const HORROR = 408;   // CH 183, all R
const LOL = 3;        // CH 3, mixed
const VAULT = 7;      // CH 7, holds R on its own

const browser = await chromium.launch({ headless: true });
const viewports = {
  desktop: { viewport: { width: 1440, height: 900 } },
  tablet: { viewport: { width: 820, height: 1180 } },
  phone: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 3 },
  tv960: { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 },
};

async function launch(name, { watershed = false } = {}) {
  const ctx = await browser.newContext({ ...viewports[name], timezoneId: "America/New_York" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url, on]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      // The SCREAM package is out of season in November; the horror channels need it on.
      localStorage.setItem("nostalgex_enabled_bundles", JSON.stringify(["nostalgex", "seasonal"]));
      if (on) localStorage.setItem("nostalgex_watershed", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
    }
  }, [api, watershed]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  // 2 PM on a Monday, EST: the Watershed window is open until 9 PM.
  await page.clock.install({ time: new Date("2026-11-02T14:00:00-05:00") });
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  return { ctx, page, errors };
}

const settle = (page, ms = 500) => page.waitForTimeout(ms);

/** One snapshot of everything the checks read. */
const read = (page) => page.evaluate(() => {
  const shown = (el) => { if (!el) return false; const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return !el.hidden && cs.display !== "none" && cs.visibility !== "hidden" && r.width > 0 && r.height > 0; };
  const rect = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return { l: r.left, t: r.top, rt: r.right, b: r.bottom }; };
  const rows = {};
  for (const row of document.querySelectorAll("#grid-body .grid-row[data-channel-id]")) {
    const progs = [...row.querySelectorAll(".grid-program")];
    rows[row.dataset.channelId] = {
      held: progs.some((p) => p.classList.contains("grid-program--held")),
      heldText: (row.querySelector(".grid-program--held") || {}).textContent || "",
      titles: progs.filter((p) => !p.classList.contains("grid-program--held")).map((p) => p.textContent),
    };
  }
  const card = document.getElementById("watershed-card") || document.createElement("div");
  const toggle = document.getElementById("cfg-watershed-toggle");
  const video = document.getElementById("plex-video");
  return {
    rows,
    card: {
      shown: shown(card), rect: rect(card),
      title: (card.querySelector(".watershed-card-title") || {}).textContent || "",
      detail: (card.querySelector(".watershed-card-detail") || {}).textContent || "",
      hint: (card.querySelector(".watershed-card-hint") || {}).textContent || "",
      button: shown(document.getElementById("watershed-card-settings")), buttonRect: rect(document.getElementById("watershed-card-settings")),
      buttonText: (document.getElementById("watershed-card-settings") || {}).textContent || "",
    },
    toggle: toggle ? { text: toggle.textContent, pressed: toggle.getAttribute("aria-pressed"), label: toggle.getAttribute("aria-label"), rowTitle: (toggle.closest(".cfg-row")?.querySelector(".cfg-row-title") || {}).textContent || "", rowDesc: (toggle.closest(".cfg-row")?.querySelector(".cfg-row-desc") || {}).textContent || "" } : null,
    stored: localStorage.getItem("nostalgex_watershed"),
    hour: new Date().getHours(),
    current: typeof currentChannel === "undefined" ? null : currentChannel,
    src: video.getAttribute("src"),
    infoTag: (document.getElementById("info-channel-tag") || {}).textContent || "",
    infoTitle: (document.getElementById("info-title") || {}).textContent || "",
    npTitle: (document.getElementById("np-title") || {}).textContent || "",
    picture: rect(document.getElementById("video-container")),
    configOpen: document.getElementById("config-overlay").classList.contains("open"),
    generalShown: getComputedStyle(document.getElementById("config-tab-general")).display !== "none",
    fullscreen: !!document.fullscreenElement,
    vw: innerWidth, vh: innerHeight,
  };
});

/** The item id a stream URL names (/Videos/<id>/stream.mp4), or null. */
const playingId = (src) => { const m = /\/Videos\/([^/]+)\//.exec(src || ""); return m ? m[1] : null; };

async function openSettingsGeneral(page, name) {
  // The rail on desktop, tablet and TV sizes; the MENU drawer on a phone. Clicks only.
  const rail = page.locator(".v-btn:has(.v-btn-label:text-is('SETTINGS'))");
  if (await rail.first().isVisible().catch(() => false)) await rail.first().click();
  else { await page.locator("#m-menu-btn").click(); await page.locator(".m-drawer-item:has-text('SETTINGS')").click(); }
  await settle(page, 300);
  await page.locator("#tab-general").click();
  await settle(page, 300);
}
const closeSettings = async (page) => { await page.locator(".config-close").click(); await settle(page, 400); };

// ── 0. The words are the Apple TV's, read from its source ──
{
  const read1 = (p) => readFileSync(join(repo, p), "utf8");
  const card = read1("Nostalgex/Nostalgex/Views/WatershedCard.swift");
  const guide = read1("Nostalgex/Nostalgex/Views/ChannelGuideView.swift");
  const settings = read1("Nostalgex/Nostalgex/Views/Settings/SettingsChannelsView.swift");
  check("source: card headline is the Apple TV's", card.includes(`"${CARD_TITLE}"`));
  check("source: card detail is the Apple TV's", card.includes(`"${CARD_DETAIL}"`));
  check("source: card hint is the Apple TV's", card.includes(`"${CARD_HINT}"`));
  check("source: guide row label is the Apple TV's", guide.includes(`"${GUIDE_LABEL}"`));
  check("source: Settings row words are the Apple TV's", settings.includes('title: "WATERSHED"') && settings.includes(`subtitle: "${ROW_DESC}"`));
  check("source: Apple TV default is off", /watershedEnabled: Bool = UserDefaults\.standard\.object\(forKey: Channel\.watershedDefaultsKey\) as\? Bool \?\? false/.test(read1("Nostalgex/Nostalgex/App/AppState.swift")));
}

// ── 1. Desktop: the whole flow ──
try {
  const { page, errors } = await launch("desktop");
  page.setDefaultTimeout(10000);
  let s = await read(page);

  check("new install: the switch is OFF and nothing is stored", s.stored === null);
  const c0 = s.rows[FRIGHT];
  check("off: the all-R channel airs (a schedule, not the hold label)", !!c0 && !c0.held && c0.titles.length > 0, JSON.stringify(c0));
  check("off: the card is not shown", !s.card.shown);

  await openSettingsGeneral(page, "desktop");
  s = await read(page);
  check("Settings > GENERAL has the Watershed row", s.toggle !== null);
  if (s.toggle === null) {
    // A page without the switch (the negative control) cannot go any further.
    await browser.close();
    for (const res of open) res.destroy();
    console.error(`watershed browser: ${failures.length} failed, ${passed} passed`);
    for (const f of failures) console.error(`  FAIL ${f}`);
    process.exit(1);
  }
  check("row title is Watershed", s.toggle && s.toggle.rowTitle === "Watershed", s.toggle && s.toggle.rowTitle);
  check("row says the Apple TV's words", s.toggle && s.toggle.rowDesc === ROW_DESC, s.toggle && s.toggle.rowDesc);
  check("switch is OFF and not pressed by default", s.toggle && s.toggle.text === "OFF" && s.toggle.pressed === "false", JSON.stringify(s.toggle));
  check("switch has an accessible name", s.toggle && s.toggle.label === "Watershed");
  const playingBefore = playingId(s.src);
  check("a programme is playing before the switch goes on", playingBefore !== null, String(s.src));

  await page.locator("#cfg-watershed-toggle").click();
  await settle(page);
  s = await read(page);
  check("click: switch reads ON and pressed", s.toggle.text === "ON" && s.toggle.pressed === "true", JSON.stringify(s.toggle));
  check("click: the engine's key is '1'", s.stored === "1", String(s.stored));
  check("click: the programme already playing is not interrupted", playingId(s.src) === playingBefore, `${playingBefore} -> ${playingId(s.src)}`);
  check("click: no card while that programme plays", !s.card.shown);

  await closeSettings(page);
  s = await read(page);
  check("on, 2 PM: the clock is before 9 PM", s.hour === 14, String(s.hour));
  for (const id of [FRIGHT, HORROR]) {
    const r = s.rows[id];
    check(`on: CH ${id === FRIGHT ? 181 : 183} says ${GUIDE_LABEL} and has no programme blocks`, !!r && r.held && r.heldText === GUIDE_LABEL && r.titles.length === 0, JSON.stringify(r));
  }
  const lol = s.rows[LOL];
  check("on: the mixed channel still airs", !!lol && !lol.held && lol.titles.length > 0, JSON.stringify(lol));
  check("on: the mixed channel airs no R title", lol && lol.titles.every((t) => !isAdultTitle(t)), JSON.stringify(lol && lol.titles.filter(isAdultTitle)));
  const vault = s.rows[VAULT];
  check("on: VHS VAULT still airs, with no R title before 9 PM", !!vault && !vault.held && vault.titles.length > 0 && vault.titles.every((t) => !isAdultTitle(t)), JSON.stringify(vault));
  check("on: the family channel is untouched", !!s.rows[8] && !s.rows[8].held && s.rows[8].titles.length > 0);

  // Tune the held channel by clicking its guide row.
  await page.locator(`#grid-body .grid-row[data-channel-id="${FRIGHT}"]`).click();
  await settle(page, 600);
  s = await read(page);
  check("tuning a held channel: current channel is it", s.current === FRIGHT, String(s.current));
  check("card is shown", s.card.shown);
  check("card headline matches the Apple TV", s.card.title === CARD_TITLE, s.card.title);
  check("card detail matches the Apple TV", s.card.detail === CARD_DETAIL, s.card.detail);
  check("card hint matches the Apple TV", s.card.hint === CARD_HINT, s.card.hint);
  check("card has an OPEN SETTINGS button", s.card.button && s.card.buttonText === "OPEN SETTINGS", s.card.buttonText);
  check("nothing is playing under the card", !s.src, String(s.src));
  check("the info panel names the held channel, not the last one", /FRIGHT NIGHT/.test(s.infoTag) && s.infoTitle === GUIDE_LABEL, `${s.infoTag} | ${s.infoTitle}`);
  check("the card fits the screen", s.card.rect && s.card.rect.l >= 0 && s.card.rect.rt <= s.vw + 0.5 && s.card.rect.t >= 0 && s.card.rect.b <= s.vh + 0.5, JSON.stringify(s.card.rect));
  check("not in browser full screen", s.fullscreen === false);

  // OPEN SETTINGS reaches the switch.
  await page.locator("#watershed-card-settings").click();
  await settle(page, 400);
  s = await read(page);
  check("OPEN SETTINGS: Settings opens on the GENERAL pane with the switch", s.configOpen && s.generalShown && s.toggle && s.toggle.text === "ON");

  // Switch off from there: the card clears and the channel tunes.
  await page.locator("#cfg-watershed-toggle").click();
  await settle(page, 700);
  s = await read(page);
  check("off again: stored '0'", s.stored === "0", String(s.stored));
  check("off again: the card is gone", !s.card.shown);
  check("off again: the channel plays an R title", isAdultId(playingId(s.src)), String(s.src));
  check("off again: the guide row airs", s.rows[FRIGHT] && !s.rows[FRIGHT].held && s.rows[FRIGHT].titles.length > 0);
  await closeSettings(page);

  // On while that R film plays: it is left to finish; the card goes up when it ends.
  await openSettingsGeneral(page, "desktop");
  await page.locator("#cfg-watershed-toggle").click();
  await settle(page, 700);
  await closeSettings(page);
  s = await read(page);
  const filmId = playingId(s.src);
  check("on during a film: the film keeps playing", isAdultId(filmId), String(s.src));
  check("on during a film: no card yet", !s.card.shown);
  check("on during a film: the guide row now holds", s.rows[FRIGHT] && s.rows[FRIGHT].held);
  await page.evaluate(() => { const ch = CHANNELS.find((c) => c.id === currentChannel); onItemEnded(ch, ch.itemPool[0], true); });
  await settle(page, 600);
  s = await read(page);
  check("when the film ends: the card goes up", s.card.shown && s.card.title === CARD_TITLE);
  check("when the film ends: nothing is left playing", !s.src, String(s.src));

  // 9 PM: the gate lifts with the card up, and the channel tunes by itself.
  await page.clock.fastForward("07:00:30");
  await settle(page, 2600);
  s = await read(page);
  check("9 PM: it is after 9 PM", s.hour === 21, String(s.hour));
  check("9 PM: the card clears", !s.card.shown);
  check("9 PM: the channel plays again", playingId(s.src) !== null, String(s.src));
  check("9 PM: the guide row airs again", s.rows[FRIGHT] && !s.rows[FRIGHT].held && s.rows[FRIGHT].titles.length > 0);

  // Midnight: the gate closes again for the next day, the film that is playing is left alone.
  await page.clock.fastForward("03:00:00");
  await settle(page, 2600);
  s = await read(page);
  check("midnight: it is after midnight", s.hour === 0, String(s.hour));
  check("midnight: the other all-R channel holds again", s.rows[HORROR] && s.rows[HORROR].held, JSON.stringify(s.rows[HORROR]));
  check("midnight: the film already playing is left alone", playingId(s.src) !== null && !s.card.shown, String(s.src));
  check("desktop: no page errors", errors.length === 0, errors.join(" | "));

  // A reload keeps the choice.
  await page.reload();
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await settle(page, 1500);
  s = await read(page);
  check("reload: the switch is still on", s.stored === "1");
  await page.context().close();
} catch (err) {
  failures.push(`desktop flow stopped: ${String(err.message || err).split("\n")[0]}`);
}

// ── 1b. 9 PM with Settings open: the channel tunes, and Settings keeps its keys ──
try {
  const { page, errors } = await launch("desktop", { watershed: true });
  page.setDefaultTimeout(10000);
  await page.locator(`#grid-body .grid-row[data-channel-id="${FRIGHT}"]`).click();
  await settle(page, 600);
  await page.locator("#watershed-card-settings").click();
  await settle(page, 400);
  let s = await read(page);
  check("9 PM with Settings open: the card is up and Settings is open", s.card.shown && s.configOpen);
  await page.clock.fastForward("07:00:30");
  await settle(page, 2600);
  s = await read(page);
  const keyState = await page.evaluate(() => ({ appState, configVisible }));
  check("9 PM with Settings open: the card clears and the channel tunes", !s.card.shown && playingId(s.src) !== null, `${s.card.shown} ${s.src}`);
  check("9 PM with Settings open: Settings stays open and keeps the keys (appState config)", s.configOpen && keyState.appState === "config" && keyState.configVisible === true, JSON.stringify(keyState));
  check("9 PM with Settings open: no page errors", errors.length === 0, errors.join(" | "));
  await page.context().close();
} catch (err) {
  failures.push(`9 PM with Settings open stopped: ${String(err.message || err).split("\n")[0]}`);
}

// ── 2. Every size: the card and the switch work by click alone ──
for (const name of Object.keys(viewports)) try {
  if (process.env.DEBUG_WS) console.log("viewport", name);
  const { page, errors } = await launch(name, { watershed: true });
  page.setDefaultTimeout(10000);
  let s = await read(page);
  check(`${name}: seeded on, the all-R rows hold`, s.rows[FRIGHT] && s.rows[FRIGHT].held && s.rows[HORROR] && s.rows[HORROR].held, JSON.stringify(s.rows[FRIGHT]));

  const row = page.locator(`#grid-body .grid-row[data-channel-id="${FRIGHT}"]`);
  await row.scrollIntoViewIfNeeded();
  await row.click();
  await settle(page, 700);
  s = await read(page);
  check(`${name}: tuning the held channel shows the card`, s.card.shown && s.card.title === CARD_TITLE, s.card.title);
  const r = s.card.rect;
  const pic = s.picture;
  check(`${name}: the card fits the ${s.vw}x${s.vh} screen`, r && r.l >= 0 && r.rt <= s.vw + 0.5 && r.t >= 0 && r.b <= s.vh + 0.5, JSON.stringify(r));
  check(`${name}: the card sits inside the picture`, r && pic && r.l >= pic.l - 0.5 && r.rt <= pic.rt + 0.5 && r.t >= pic.t - 0.5 && r.b <= pic.b + 0.5, `${JSON.stringify(r)} in ${JSON.stringify(pic)}`);
  const br = s.card.buttonRect;
  check(`${name}: OPEN SETTINGS is on screen`, s.card.button && br && br.l >= 0 && br.rt <= s.vw + 0.5 && br.t >= 0 && br.b <= s.vh + 0.5, JSON.stringify(br));
  check(`${name}: not in browser full screen`, s.fullscreen === false);
  if (shots && (name === "tv960" || name === "phone")) await page.screenshot({ path: join(shots, `watershed-card-${name}.png`) });

  await page.locator("#watershed-card-settings").click();
  await settle(page, 400);
  s = await read(page);
  check(`${name}: OPEN SETTINGS opens the GENERAL pane`, s.configOpen && s.generalShown);
  const toggle = page.locator("#cfg-watershed-toggle");
  await toggle.scrollIntoViewIfNeeded();
  const tb = await toggle.boundingBox();
  check(`${name}: the switch is on screen and big enough to click`, !!tb && tb.x >= 0 && tb.x + tb.width <= s.vw + 0.5 && tb.height >= 24, JSON.stringify(tb));
  if (shots && (name === "tv960" || name === "phone")) await page.screenshot({ path: join(shots, `watershed-switch-${name}.png`) });
  await toggle.click();
  await settle(page, 700);
  s = await read(page);
  check(`${name}: clicking the switch turns it off and clears the card`, s.stored === "0" && !s.card.shown && s.toggle.text === "OFF", `${s.stored} ${s.card.shown} ${s.toggle && s.toggle.text}`);
  check(`${name}: no page errors`, errors.length === 0, errors.join(" | "));
  await page.context().close();
} catch (err) {
  failures.push(`${name} flow stopped: ${String(err.message || err).split("\n")[0]}`);
}

await browser.close();
for (const res of open) res.destroy();
jellyfin.closeAllConnections?.();
files.closeAllConnections?.();
jellyfin.close();
files.close();

if (failures.length) {
  console.error(`watershed browser: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`watershed browser: ${passed} checks passed`);
process.exit(0);
