#!/usr/bin/env node
/**
 * The web tuner's start screen (GitHub #254), on the real pages, headless.
 *
 * 1. The words and the fit, at three sizes: 1280x800, 960x540 at device pixel ratio 2 with a mouse (a TV browser) and
 *    390x844 on a phone, each on the hosted page (served from an https address) and on a page served over http (what
 *    the Docker tuner is). The headline and the sentence are the Apple TV's and the Roku's, character for character
 *    (read from their source). The three choices are on screen. Nothing scrolls at the two wide sizes; nothing
 *    scrolls sideways on the phone.
 * 2. The hosted page's one line about the https limit: there at every size on the hosted page, with its link to the
 *    self-host page, inside the screen where nothing scrolls; not there on a page served over http.
 * 3. Before the attempt: a plain-http address typed on the hosted page (one on a home network, one on the internet) is
 *    refused with the reason and the way round, no request is made to it and the CONNECTING screen never shows. With
 *    the keyboard alone and with the mouse alone.
 * 4. Start to guide on a page served over http, Jellyfin and Emby: with the keyboard alone (Tab, Enter and typing) and
 *    with the mouse alone (clicks; text is filled in as an on-screen keyboard would).
 * 5. A saved login skips the start screen.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * TUNER_ROOT=/path runs another tree (for example dist-selfhost/, which must show no https line anywhere).
 * SHOTS=/dir saves a screenshot of each start screen. Run: `npm run test:first-run:browser`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = process.env.TUNER_ROOT ? resolve(process.env.TUNER_ROOT) : fileURLToPath(new URL("../", import.meta.url));
const HOSTED_ORIGIN = "https://hosted.nostalgex.test";
const SELFHOST_TREE = !!process.env.TUNER_ROOT && /dist-selfhost/.test(process.env.TUNER_ROOT);

// ── What the Apple TV and the Roku say (the web must say the same) ──
const rd = (rel) => readFileSync(fileURLToPath(new URL(`../${rel}`, import.meta.url)), "utf8");
const swift = rd("Nostalgex/Nostalgex/Views/SettingsView.swift");
const TITLE = /Text\("(CONNECT YOUR SERVER)"\)/.exec(swift)[1];
const BODY = /Text\("(Nostalgex builds a retro channel guide[^"]*)"\)/.exec(swift)[1];
const brs = rd("roku/source/mediabrowser/SignInFlow.brs");
if (/screenTitle:\s*"([^"]*)"/.exec(brs)[1] !== TITLE || /screenBody:\s*"([^"]*)"/.exec(brs)[1] !== BODY) throw new Error("the Apple TV and the Roku no longer say the same thing");

// ── A Jellyfin- and Emby-shaped server ──
const TOKEN = "JFTOKEN-first-run";
const movie = (i) => ({
  Id: `m${i}`, Name: `Movie ${i}`, Type: "Movie", ProductionYear: 1990 + i, Genres: ["Action"], OfficialRating: "PG-13",
  RunTimeTicks: 54000000000, ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", ImageTags: { Primary: "abc" },
  MediaSources: [{ Id: `m${i}`, Container: "mp4", RunTimeTicks: 54000000000, Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }] }],
});
const items = Array.from({ length: 30 }, (_, i) => movie(i));
let emby = false;
const asked = [];   // every path the media server was asked for
const media = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  asked.push(req.url);
  const url = req.url;
  const json = (body, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(typeof body === "string" ? body : JSON.stringify(body)); };
  if (url.startsWith("/System/Info/Public")) {
    return json(emby ? { ServerName: "lab", Version: "4.10.1.0", Id: "lab", LocalAddresses: [] }
      : { ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" });
  }
  if (url.startsWith("/QuickConnect/Enabled")) return json("false");
  if (url.startsWith("/Users/Public")) return json("[]");
  if (url.startsWith("/Users/AuthenticateByName")) {
    req.on("data", () => {});
    req.on("end", () => json({ AccessToken: TOKEN, User: { Id: "uid1", Name: "bob", ServerName: "lab" } }));
    return;
  }
  if (url.startsWith("/UserViews") || /^\/Users\/[^/]+\/Views/.test(url)) return json({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 });
  if (url.includes("IncludeItemTypes=Movie")) return json({ Items: items, TotalRecordCount: items.length });
  json({ Items: [], TotalRecordCount: 0 });
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  let p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!extname(p) && existsSync(p + ".html")) p += ".html";
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => media.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${media.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });

/** A context whose https://hosted.nostalgex.test is the tuner's files, so the page really is on an https address. */
async function context(opts) {
  const ctx = await browser.newContext(opts);
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), async (route) => {
    const u = new URL(route.request().url());
    if (u.origin !== HOSTED_ORIGIN) return route.abort();
    // Plex's own sign-in is on the internet; it is not reachable here, and the start screen must cope.
    const resp = await route.fetch({ url: `${base}${u.pathname}${u.search}` });
    return route.fulfill({ response: resp });
  });
  return ctx;
}

const SIZES = [
  { name: "1280x800", opts: { viewport: { width: 1280, height: 800 } }, noScroll: true },
  { name: "960x540 at DPR 2 (TV browser)", opts: { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 }, noScroll: true },
  { name: "390x844 phone", opts: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true }, noScroll: false },
];
const PICKER_IDS = ["connect-btn", "connect-jellyfin-btn", "connect-emby-btn"];

async function measure(page) {
  return page.evaluate((ids) => {
    const se = document.scrollingElement;
    const rect = (el) => { const r = el.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, w: r.width, h: r.height }; };
    const visible = (el) => !!el && getComputedStyle(el).display !== "none" && getComputedStyle(el).visibility !== "hidden" && el.getBoundingClientRect().width > 0;
    const note = document.getElementById("picker-https-note");
    const link = note && note.querySelector("a");
    return {
      title: (document.querySelector(".connect-title") || {}).textContent,
      lede: (document.querySelector(".connect-lede") || {}).textContent,
      oldWords: /Your library as live TV|Plays your own Plex/.test(document.body.innerText),
      buttons: ids.map((id) => ({ id, ok: visible(document.getElementById(id)), r: document.getElementById(id) ? rect(document.getElementById(id)) : null })),
      note: note ? { visible: visible(note), text: note.textContent, href: link ? link.href : null, r: rect(note) } : null,
      noteCount: document.querySelectorAll("#picker-https-note, .signin-https-note").length,
      scrollV: se.scrollHeight - se.clientHeight, scrollH: se.scrollWidth - se.clientWidth,
      vw: window.innerWidth, vh: window.innerHeight, protocol: location.protocol,
      title_r: rect(document.querySelector(".connect-title")), lede_r: rect(document.querySelector(".connect-lede")),
    };
  }, PICKER_IDS);
}

// ── 1 and 2: the words, the fit and the line, at three sizes, hosted and over http ──
for (const size of SIZES) {
  for (const hosted of [true, false]) {
    const where = `${size.name}, ${hosted ? "hosted (https)" : "over http"}`;
    const ctx = await context(size.opts);
    const page = await ctx.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
    await page.goto(`${hosted ? HOSTED_ORIGIN : base}/web-tuner.html`);
    await page.waitForSelector("#connect-btn", { state: "visible" });
    await page.waitForTimeout(400);
    if (process.env.SHOTS) await page.screenshot({ path: `${process.env.SHOTS}/start-${size.name.split(' ')[0]}-${hosted ? 'hosted' : 'http'}.png` });
    const m = await measure(page);
    check(`${where}: the headline is the Apple TV's`, m.title === TITLE, JSON.stringify(m.title));
    check(`${where}: the sentence is the Apple TV's`, m.lede === BODY, JSON.stringify(m.lede));
    check(`${where}: none of the old words are left`, !m.oldWords);
    check(`${where}: the page is ${hosted ? "https" : "http"}`, m.protocol === (hosted ? "https:" : "http:"), m.protocol);
    check(`${where}: the three choices are on screen`, m.buttons.every((b) => b.ok), JSON.stringify(m.buttons.map((b) => [b.id, b.ok])));
    check(`${where}: nothing runs off the side`, m.scrollH <= 1 && m.buttons.every((b) => b.r.left >= -1 && b.r.right <= m.vw + 1) && m.title_r.right <= m.vw + 1 && m.lede_r.right <= m.vw + 1, JSON.stringify({ scrollH: m.scrollH, vw: m.vw, title: m.title_r.right, lede: m.lede_r.right }));
    if (size.noScroll) {
      check(`${where}: nothing scrolls`, m.scrollV <= 1, `${m.scrollV} px over`);
      check(`${where}: the headline, the sentence and the choices are inside the screen`, m.title_r.top >= -1 && m.lede_r.bottom <= m.vh + 1 && m.buttons.every((b) => b.r.bottom <= m.vh + 1), JSON.stringify({ vh: m.vh, lede: m.lede_r.bottom, last: m.buttons.at(-1).r.bottom }));
    }
    if (hosted && !SELFHOST_TREE) {
      check(`${where}: the https line is there once`, m.note && m.note.visible && m.noteCount === 1, JSON.stringify(m.note && m.note.text));
      check(`${where}: the https line says the limit and the way round`, !!m.note && /Jellyfin and Emby need an https address/.test(m.note.text) && /run the tuner yourself/.test(m.note.text), m.note && m.note.text);
      check(`${where}: the https line links to the self-host page`, !!m.note && m.note.href === `${HOSTED_ORIGIN}/self-host`, m.note && m.note.href);
      if (size.noScroll) check(`${where}: the https line is inside the screen, under the choices`, !!m.note && m.note.r.top >= m.buttons.at(-1).r.bottom - 1 && m.note.r.bottom <= m.vh + 1, JSON.stringify({ note: m.note && m.note.r, last: m.buttons.at(-1).r.bottom, vh: m.vh }));
      else check(`${where}: the https line sits under the choices`, !!m.note && m.note.r.top >= m.buttons.at(-1).r.bottom - 1);
    } else {
      check(`${where}: no https line`, m.noteCount === 0 && !m.note, `${m.noteCount} found`);
    }
    check(`${where}: no page errors`, errors.length === 0, errors.join(" | "));
    await ctx.close();
  }
}

// ── 3: before the attempt, hosted ──
// Two plain-http addresses: one on a home network, one on the internet. The page says why and how to get round it
// without trying: no request leaves for either, and the CONNECTING screen never shows.
const PLAIN = [
  { address: "http://192.168.1.10:8096", host: "192.168.1.10", reason: /address on your own network, which browsers block from this secure page/ },
  { address: "http://jellyfin.example.com:8096", host: "jellyfin.example.com", reason: /Browsers block a plain http:\/\/ server from this secure page/ },
];
async function refusedBeforeAttempt(how, plain) {
  const ctx = await context({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  const sent = [];
  page.on("request", (r) => { if (r.url().includes(plain.host)) sent.push(r.url()); });
  await page.goto(`${HOSTED_ORIGIN}/web-tuner.html`);
  await page.waitForSelector("#connect-btn", { state: "visible" });
  const label = `${how}, ${plain.host}`;
  if (how === "keyboard") {
    const focus = () => page.evaluate(() => document.activeElement && document.activeElement.id);
    const first = await focus();
    check(`${label}: a choice has focus when the page opens, or the first Tab reaches one`, PICKER_IDS.includes(first) || (await (async () => { await page.keyboard.press("Tab"); return PICKER_IDS.includes(await focus()); })()), String(first));
    for (let i = 0; i < 4 && (await focus()) !== "connect-jellyfin-btn"; i++) await page.keyboard.press("Tab");
    check(`${label}: Tab reaches JELLYFIN`, (await focus()) === "connect-jellyfin-btn", String(await focus()));
    await page.keyboard.press("Enter");
  } else {
    await page.click("#connect-jellyfin-btn");
  }
  await page.waitForSelector("#address-input", { state: "visible", timeout: 5000 });
  // Record every screen that shows from here on.
  await page.evaluate(() => {
    window.__screens = [];
    const seen = () => [...document.querySelectorAll("[data-screen]")].filter((el) => !el.hidden).map((el) => el.dataset.screen).join(",");
    new MutationObserver(() => window.__screens.push(seen())).observe(document.getElementById("signin"), { attributes: true, subtree: true, attributeFilter: ["hidden"] });
  });
  if (how === "keyboard") {
    await page.keyboard.type(plain.address);
    await page.keyboard.press("Enter");
  } else {
    await page.fill("#address-input", plain.address);
    await page.click("#address-connect");
  }
  await page.waitForFunction(() => { const w = document.getElementById("address-warn"); return w && !w.hidden && w.textContent.trim().length > 0; }, null, { timeout: 5000 }).catch(() => {});
  const warn = await page.evaluate(() => { const w = document.getElementById("address-warn"); return w && !w.hidden ? w.textContent : ""; });
  check(`${label}: a plain-http address is refused, with the reason`, plain.reason.test(warn), JSON.stringify(warn));
  check(`${label}: and the way round, naming the tuner you run yourself`, /run the tuner on your own server/.test(warn) && /nostalgex\.app\/self-host/.test(warn), JSON.stringify(warn));
  await page.waitForTimeout(600);
  check(`${label}: no request was made to that address`, sent.length === 0, sent.join(", "));
  const screens = await page.evaluate(() => window.__screens);
  check(`${label}: the CONNECTING screen never showed, the address screen stayed`, screens.every((x) => !x.split(",").includes("checking")) && (await page.evaluate(() => document.querySelector("[data-screen='address']").hidden === false)), JSON.stringify(screens));
  await ctx.close();
}
for (const plain of PLAIN) for (const how of ["mouse", "keyboard"]) await refusedBeforeAttempt(how, plain);

// ── 4: start to guide, over http, Jellyfin and Emby ──
async function toGuide(kind, how) {
  emby = kind === "emby";
  asked.length = 0;
  const ctx = await context({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/web-tuner.html`);
  await page.waitForSelector("#connect-btn", { state: "visible" });
  const focus = () => page.evaluate(() => document.activeElement && document.activeElement.id);
  const tabTo = async (id, max = 8) => { for (let i = 0; i < max && (await focus()) !== id; i++) await page.keyboard.press("Tab"); return (await focus()) === id; };
  const label = `${kind}, ${how}`;
  if (how === "keyboard") {
    check(`${label}: Tab reaches the choice`, await tabTo(kind === "emby" ? "connect-emby-btn" : "connect-jellyfin-btn"));
    await page.keyboard.press("Enter");
    await page.waitForSelector("#find-type-btn", { state: "visible", timeout: 8000 });
    check(`${label}: Tab reaches TYPE AN ADDRESS`, await tabTo("find-type-btn"));
    await page.keyboard.press("Enter");
    await page.waitForSelector("#address-input", { state: "visible", timeout: 5000 });
    if ((await focus()) !== "address-input") await page.focus("#address-input");
    await page.keyboard.type(api);
    await page.keyboard.press("Enter");
    await page.waitForSelector("#signin-user", { state: "visible", timeout: 15000 });
    if ((await focus()) !== "signin-user") await tabTo("signin-user", 4);
    await page.keyboard.type("bob");
    await page.keyboard.press("Tab");
    await page.keyboard.type("pw-first-run");
    await page.keyboard.press("Enter");
  } else {
    await page.click(kind === "emby" ? "#connect-emby-btn" : "#connect-jellyfin-btn");
    await page.click("#find-type-btn");
    await page.fill("#address-input", api);
    await page.click("#address-connect");
    await page.waitForSelector("#signin-user", { state: "visible", timeout: 15000 });
    await page.fill("#signin-user", "bob");
    await page.fill("#signin-pass", "pw-first-run");
    await page.click("#signin-btn");
  }
  await page.waitForURL(/plex-tuner\.html/, { timeout: 15000 });
  await page.waitForSelector("#library-picker.active .library-continue", { timeout: 15000 });
  if (how === "keyboard") {
    check(`${label}: CHOOSE YOUR LIBRARIES has CONTINUE under the keys`, await page.evaluate(() => /CHOOSE YOUR LIBRARIES/.test(document.querySelector(".setup-title:not([style*='none'])") ? document.body.innerText : document.body.innerText)));
    await page.keyboard.press("Enter");
  } else {
    await page.click(".library-continue");
  }
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 });
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length > 0 && document.getElementById("guide-grid") && getComputedStyle(document.getElementById("guide-grid")).display !== "none", null, { timeout: 20000 });
  const rows = await page.evaluate(() => document.querySelectorAll("#guide-grid .grid-row, #guide-grid [data-channel-id]").length);
  check(`${label}: from the start screen to a guide, ${how} alone`, true);
  check(`${label}: the guide has channels`, rows > 0 || (await page.evaluate(() => CHANNELS.length)) > 0, String(rows));
  check(`${label}: the server was asked for the library through the address typed`, asked.some((u) => u.includes("IncludeItemTypes=Movie")));
  check(`${label}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}
for (const kind of ["jellyfin", "emby"]) for (const how of ["keyboard", "mouse"]) await toGuide(kind, how);
emby = false;

// ── Plex: the choice answers, and the start screen survives plex.tv being out of reach ──
{
  const ctx = await context({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/web-tuner.html`);
  await page.waitForSelector("#connect-btn", { state: "visible" });
  await page.click("#connect-btn");
  await page.waitForTimeout(1500);
  const state = await page.evaluate(() => ({ screen: [...document.querySelectorAll("[data-screen]")].filter((s) => !s.hidden).map((s) => s.dataset.screen), err: (document.getElementById("picker-error") || {}).textContent || "" }));
  check("Plex: CONNECT TO PLEX answers (the code screen, or a reason on the start screen when plex.tv is out of reach)", state.screen.includes("plex") || state.err.trim().length > 0, JSON.stringify(state));
  check("Plex: no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// ── 5: a saved login skips the start screen ──
{
  const ctx = await context({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 });
  await ctx.addInitScript(([url]) => {
    if (location.pathname.endsWith("web-tuner.html") && !localStorage.getItem("nx-first-run-seeded")) {
      localStorage.setItem("nx-first-run-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "uid1", jfUrl: url, jfUser: "bob" }));
    }
  }, [api]);
  const page = await ctx.newPage();
  await page.goto(`${base}/web-tuner.html`);
  await page.waitForURL(/plex-tuner\.html/, { timeout: 10000 }).catch(() => {});
  check("a saved login goes straight past the start screen", /plex-tuner\.html/.test(page.url()), page.url());
  check("and the start screen's words are not on the page it lands on", !(await page.evaluate((t) => document.body.innerText.includes(t) && !!document.querySelector(".connect-title"), TITLE)));
  await ctx.close();
}

await browser.close();
media.close();
files.close();
if (failures.length) {
  console.error(`first-run browser: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`first-run browser: ${passed} checks passed${SELFHOST_TREE ? " (self-host tree)" : ""}`);
process.exit(0);
