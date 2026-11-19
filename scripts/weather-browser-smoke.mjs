#!/usr/bin/env node
/**
 * The weather channel (CH 299, LOCAL WEATHER) in the real plex-tuner.html, headless, against a Plex-shaped stub, a stub relay
 * (the golden MET document), and stub radar servers (NOAA and Environment Canada) that answer with generated pictures.
 *
 * At 1920x1080, 1280x720 and a phone (390x844) it tunes the channel and, for each of the four screens (CURRENT CONDITIONS, TODAY'S
 * FORECAST, 5-DAY FORECAST, RADAR), checks what is drawn (every fillText is recorded) and saves a screenshot. It also walks the
 * rest of the feature:
 *
 *   - the guide row (CH 299, LOCAL WEATHER, a programme) and the info panel (the place and a one-line summary);
 *   - no location: the SET YOUR LOCATION IN SETTINGS card and its button; Settings > WEATHER: typing a city, picking a match,
 *     the units (AUTO is Fahrenheit for a US place, Celsius elsewhere) and the show/hide switch;
 *   - privacy: nothing but the page's own server, the relay and the two radar hosts is asked, and the only place that leaves the
 *     browser is the rounded one (2 decimals), to the relay, with the client header and no cookies;
 *   - radar: CA on Environment Canada (rain and snow layers), US on NOAA, Germany on DWD (its own source note, frames that stop before the clock,
 *     the magenta coverage edge dropped), a place with none gets RADAR NOT AVAILABLE IN YOUR AREA;
 *   - credits: DATA FROM MET NORWAY on every screen, the radar source's on the radar, the licence line in Settings;
 *   - GUIDE TEXT SIZE LARGE makes the drawn text bigger and never moves the layout;
 *   - the music: one bundled loop (m4a and mp3 sources), fetched only when the channel is tuned, on the SOUND control, stopped with the channel;
 *   - a relay that fails: FORECAST UNAVAILABLE RIGHT NOW, and it recovers.
 *
 * SHOTS=/dir saves the screenshots. Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable
 * `playwright`. Run: `npm run test:weather:browser`. Headless only.
 */
import http from "node:http";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));
const SHOTS = process.env.SHOTS || "";
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
const golden = JSON.parse(readFileSync(join(root, "scripts/weather-golden.json"), "utf8"));

// ── Stubs ──
const NOW = Date.parse("2026-11-15T18:20:00Z");
/** An epoch (ms) near NOW at `offset` seconds into screen `i` of the 65 second loop (current 0, today 15, week 30, radar 45). */
const LOOP = 65, STARTS = [0, 15, 30, 45];
const at = (i, offset = 4) => { const base = Math.floor(NOW / 1000); let s = base - (base % LOOP) + STARTS[i] + offset; if (s > base + 40) s -= LOOP; return s * 1000 + 250; };

function png(w, h, pixel) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; for (let x = 0; x < w; x++) { const p = pixel(x, y) || [0, 0, 0, 0]; raw.set(p, y * (w * 4 + 1) + 1 + x * 4); } }
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(td) >>> 0); return Buffer.concat([len, td, crc]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}
// Echoes in the sources' own colours (blue, green, yellow, orange, red, magenta), a few blobs that drift with the frame's time.
const RINGS = [[110, 150, 200], [60, 190, 70], [245, 230, 40], [240, 140, 0], [225, 25, 25], [255, 0, 255]];
function radarPng(w, h, time) {
  const minutes = Math.floor(Date.parse(time) / 60000) % 60;
  const blobs = [[120 + minutes * 3, 70, 40], [260 + minutes * 2, 110, 32], [330, 50 + minutes, 26]];
  return png(w, h, (x, y) => {
    let best = -1;
    for (const [cx, cy, r] of blobs) { const d = Math.hypot(x - cx, (y - cy) * 1.3); if (d < r) best = Math.max(best, Math.floor((1 - d / r) * RINGS.length)); }
    return best >= 0 ? [...RINGS[Math.min(best, RINGS.length - 1)], 255] : null;
  });
}

// DWD's picture: opaque. White where there is no echo, grey outside the radars, the edge of the coverage drawn in magenta, echoes in between.
function dwdPng(w, h, time) {
  const minutes = Math.floor(Date.parse(time) / 60000) % 60;
  const cx = 150 + minutes * 2, cy = 90;
  return png(w, h, (x, y) => {
    if (x < 12) return [190, 190, 190, 255];
    if (x < 14) return [230, 50, 230, 255];
    const d = Math.hypot(x - cx, (y - cy) * 1.2);
    if (d < 36) return [...RINGS[Math.min(RINGS.length - 2, Math.floor((1 - d / 36) * (RINGS.length - 1)))], 255];
    return [255, 255, 255, 255];
  });
}

const GENRES = ["Action", "Comedy", "Drama", "Family"];
const media = (i) => [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${i}/file.mp4` }] }];
const film = (i) => ({ ratingKey: String(1000 + i), title: `Family Day ${i}`, summary: `Film ${i}.`, year: 1980 + (i % 30), duration: (84 + (i % 40)) * 60000, type: "movie", addedAt: 1600000000 + i, contentRating: "PG", rating: 7, Genre: [{ tag: GENRES[i % 4] }, { tag: "Family" }], Guid: [{ id: `tmdb://${5000 + i}` }], Media: media(i), thumb: `/library/metadata/${1000 + i}/thumb/1` });
const POSTER = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
const plexLog = [];
const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  plexLog.push(url.pathname + url.search);
  res.setHeader("Content-Type", "application/json");
  if (url.pathname === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
  if (url.pathname === "/photo/:/transcode") { res.setHeader("Content-Type", "image/png"); return res.end(POSTER); }
  if (url.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }] } }));
  if (url.pathname === "/library/sections/1/all") {
    const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0);
    const size = Number(url.searchParams.get("X-Plex-Container-Size") || 300);
    const rows = [];
    for (let i = start; i < Math.min(300, start + size); i++) rows.push(film(i));
    return res.end(JSON.stringify({ MediaContainer: { size: rows.length, totalSize: 300, Metadata: rows } }));
  }
  if (url.pathname.startsWith("/library/parts/")) { res.writeHead(404); return res.end(); }
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".ttf": "font/ttf", ".woff2": "font/woff2" };
const NODE_MODULES = fileURLToPath(new URL("../node_modules/", import.meta.url));
let fontCss = "";
for (const pkg of ["vt323", "press-start-2p", "silkscreen"]) {
  const f = join(NODE_MODULES, "@fontsource", pkg, "400.css");
  if (existsSync(f)) fontCss += readFileSync(f, "utf8").replace(/url\(\.\/files\/([^)]+)\)/g, (m, name) => `url(__FONTS__/${pkg}/${name})`) + "\n";
}
const fileLog = [];
const files = http.createServer((req, res) => {
  fileLog.push(req.url.split("?")[0]);
  const fm = /^\/__fonts\/([a-z0-9-]+)\/([^/?]+)$/.exec(req.url.split("?")[0]);
  if (fm) {
    const f = join(NODE_MODULES, "@fontsource", fm[1], "files", fm[2]);
    if (!existsSync(f)) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { "Content-Type": "font/woff2", "Access-Control-Allow-Origin": "*" });
    return res.end(readFileSync(f));
  }
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0]).replace(/^\/weather\//, "/public/weather/")));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
    // ?selfhost=1 is the Docker build's marker, as selfhost-build.mjs writes it.
    if (/[?&]selfhost=1/.test(req.url)) body = body.replace(/<meta charset="UTF-8">/i, (m) => `${m}\n<meta name="nostalgex-build" content="selfhost">`);
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => plex.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${plex.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const TORONTO = { name: "Toronto", region: "ON", cc: "CA", lat: 43.65, lon: -79.38, tz: "America/Toronto", kind: "city" };
const BUFFALO = { name: "Buffalo", region: "NY", cc: "US", lat: 42.89, lon: -78.88, tz: "America/New_York", kind: "city" };
const LONDON = { name: "London", region: "England", cc: "GB", lat: 51.51, lon: -0.13, tz: "Europe/London", kind: "city" };

const browser = await chromium.launch({ headless: true });
const CH_ID = 1030000;

/** One browser context with every stub in place. `opts.place` seeds the saved place; `relay` is the answer the relay gives. */
async function open({ width, height, mobile = false, place = TORONTO, relay = "ok", large = false, music = false, units = null, selfhost = false }) {
  const ctx = await browser.newContext({ viewport: { width, height }, ...(mobile ? { deviceScaleFactor: 2, isMobile: true, hasTouch: true } : {}) });
  const seen = [];
  const relayCalls = [];
  const radarCalls = [];
  let relayMode = relay;
  await ctx.route(/fonts\.googleapis\.com\/css2/, (route) => route.fulfill({ contentType: "text/css", headers: { "access-control-allow-origin": "*" }, body: fontCss.replaceAll("__FONTS__", `${base}/__fonts`) }));
  await ctx.route((u) => !/^127\.0\.0\.1$/.test(u.hostname) && !/^(fonts\.googleapis\.com|opengeo\.ncep\.noaa\.gov|geo\.weather\.gc\.ca|maps\.dwd\.de|www\.nostalgex\.app)$/.test(u.hostname), (route) => { seen.push(route.request().url()); return route.abort(); });
  await ctx.route(/\/api\/weather/, async (route) => {
    // A self-hosted tuner asks the site from another origin: the browser sends a preflight first, and the relay answers it.
    if (route.request().method() === "OPTIONS") return route.fulfill({ status: 204, headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "x-nostalgex-client", "access-control-allow-methods": "GET, OPTIONS" } });
    relayCalls.push({ url: route.request().url(), headers: route.request().headers() });
    if (relayMode === "fail") return route.fulfill({ status: 502, contentType: "application/json", body: '{"error":"Forecast unavailable"}' });
    return route.fulfill({ status: 200, contentType: "application/json", headers: { "access-control-allow-origin": "*" }, body: JSON.stringify(golden.met) });
  });
  await ctx.route(/opengeo\.ncep\.noaa\.gov|geo\.weather\.gc\.ca|maps\.dwd\.de/, (route) => {
    const u = new URL(route.request().url());
    radarCalls.push(route.request().url());
    const q = u.searchParams;
    const cors = { "access-control-allow-origin": "*" };
    if (u.hostname.includes("dwd")) {
      if ((q.get("request") || "").toLowerCase() === "getcapabilities") {
        // DWD's range runs two hours past now (nowcast); the second dimension is the long list the layer-only capabilities also carry.
        const dim = `<Dimension name="time" default="current" units="ISO8601">${new Date(NOW - 3 * 86400000).toISOString()}/${new Date(Math.floor((NOW + 2 * 3600000) / 300000) * 300000).toISOString()}/PT5M</Dimension><Dimension name="REFERENCE_TIME" default="x" units="ISO8601">2026-11-12T00:00:00.000Z,2026-11-12T00:05:00.000Z</Dimension>`;
        return route.fulfill({ status: 200, contentType: "text/xml", headers: cors, body: `<WMS_Capabilities>${dim}</WMS_Capabilities>` });
      }
      return route.fulfill({ status: 200, contentType: "image/png", headers: cors, body: dwdPng(Number(q.get("width")), Number(q.get("height")), q.get("time") || new Date(NOW).toISOString()) });
    }
    if ((q.get("request") || "").toLowerCase() === "getcapabilities") {
      const dim = u.hostname.includes("noaa")
        ? `<Dimension name="time" default="x" units="ISO8601" nearestValue="1">${Array.from({ length: 40 }, (_, i) => new Date(NOW - 8 * 60000 - (39 - i) * 2 * 60000).toISOString()).join(",")}</Dimension>`
        : `<Dimension name="time" units="ISO8601" default="x" nearestValue="0">${new Date(NOW - 3 * 3600000).toISOString().slice(0, 17)}00Z/${new Date(Math.floor((NOW - 6 * 60000) / 360000) * 360000).toISOString().slice(0, 17)}00Z/PT6M</Dimension>`;
      return route.fulfill({ status: 200, contentType: "text/xml", headers: cors, body: `<WMS_Capabilities>${dim}</WMS_Capabilities>` });
    }
    return route.fulfill({ status: 200, contentType: "image/png", headers: cors, body: radarPng(Number(q.get("width")), Number(q.get("height")), q.get("time") || new Date(NOW).toISOString()) });
  });
  await ctx.addInitScript(([url, seed, units0, big, withMusic, now]) => {
    // Every string the page draws on the weather canvas, with its font.
    window.__wxText = [];
    const orig = CanvasRenderingContext2D.prototype.fillText;
    CanvasRenderingContext2D.prototype.fillText = function (t, x, y, w) { if (this.canvas && this.canvas.id === "weather-screen") window.__wxText.push([String(t), this.font, x, y]); return orig.call(this, t, x, y, w); };
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "plex", userToken: "t" }));
      if (seed) localStorage.setItem("nostalgex_weather_place", JSON.stringify(seed));
      if (units0) localStorage.setItem("nostalgex_weather_units", units0);
      if (big) localStorage.setItem("nostalgex_guide_text_size", "large");
    }
  }, [api, place, units, large, music, NOW]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR|ERR_FAILED|status of 404|status of 502/.test(m.text())) errors.push(m.text().slice(0, 200)); });
  await page.clock.setFixedTime(new Date(at(0)));
  await page.goto(`${base}/plex-tuner.html${selfhost ? "?selfhost=1" : ""}`);
  await page.waitForFunction(() => (typeof allItemsCache !== "undefined" && allItemsCache.length > 0) || !!document.querySelector(".library-continue"), null, { timeout: 30000 });
  if (await page.$(".library-continue")) await page.click(".library-continue").catch(() => {});
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length >= 250 && typeof CHANNELS !== "undefined" && CHANNELS.some((c) => c.enabled && c.schedule && c.schedule[0]), null, { timeout: 30000 });
  await page.waitForTimeout(800);
  return { ctx, page, seen, relayCalls, radarCalls, errors, setRelay: (m) => { relayMode = m; } };
}

/** The strings the weather canvas drew since the last call. Waits for a fresh draw. */
async function drawn(page, ms = 900) {
  await page.evaluate(() => { window.__wxText.length = 0; });
  await page.waitForTimeout(ms);
  return page.evaluate(() => window.__wxText.slice());
}
async function setClock(page, t) { await page.clock.setFixedTime(new Date(t)); }
// As a viewer does: the cursor goes to the row, then the channel is tuned.
const tune = (page, id = CH_ID) => page.evaluate((cid) => { guideFocusIndex = getEnabledChannels().findIndex((c) => c.id === cid); updateGuideFocus(); tuneFromGuide(cid); }, id);

async function shot(page, name) { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${name}.png` }); }
async function canvasInk(page) {
  return page.evaluate(() => {
    const c = document.getElementById("weather-screen");
    const d = c.getContext("2d").getImageData(0, 0, c.width, c.height).data;
    const seen = new Set();
    for (let i = 0; i < d.length; i += 4 * 997) seen.add(`${d[i] >> 4},${d[i + 1] >> 4},${d[i + 2] >> 4}`);
    return seen.size;
  });
}

// ═══ 1. The four screens at three sizes ═══
const SIZES = [["1920x1080", 1920, 1080, false], ["1280x720", 1280, 720, false], ["phone-390x844", 390, 844, true]];
const SCREENS = ["current", "today", "week", "radar"];
const TITLES = { current: "CURRENT CONDITIONS", today: "TODAY'S FORECAST", week: "5-DAY FORECAST", radar: "RADAR" };
const results = {};
for (const [tag, w, h, mobile] of SIZES) {
  const s = await open({ width: w, height: h, mobile });
  const { page } = s;
  await tune(s.page);
  await page.waitForFunction(() => document.getElementById("weather-screen").classList.contains("on") && WX.model && WX.fonts, null, { timeout: 15000 });
  for (let i = 0; i < 4; i++) {
    const id = SCREENS[i];
    await setClock(page, at(i));
    if (id === "radar") await page.waitForFunction(() => WX.radar.status === "ready" && WX.radar.frames.length >= 2, null, { timeout: 15000 });
    const text = await drawn(page);
    const strings = text.map((t) => t[0]);
    results[`${tag}/${id}`] = strings;
    check(`${tag} ${id}: the screen's title`, strings.includes(TITLES[id]), JSON.stringify(strings.slice(0, 8)));
    check(`${tag} ${id}: DATA FROM MET NORWAY, and CH 299`, strings.includes("DATA FROM MET NORWAY") && strings.includes("CH 299"));
    check(`${tag} ${id}: the place and the clock in the header`, strings.includes("TORONTO, ON") && strings.some((t) => /^\d{1,2}:\d{2} [AP]M$/.test(t)));
    // The credits and the age of the forecast: one small stack bottom left, 16 px, the least prominent text on the screen.
    const pxOf = (t) => Number(/(\d+(?:\.\d+)?)px/.exec(t[1])[1]);
    const isCredit = (t) => t[0] === "DATA FROM MET NORWAY" || /^UPDATED \d|^OLD FORECAST/.test(t[0]) || /^(RADAR: NOAA|DATA SOURCE: ENVIRONMENT|Datenbasis: )/.test(t[0]);
    const credits = text.filter(isCredit), others = text.filter((t) => !isCredit(t));
    const metLine = text.find((t) => t[0] === "DATA FROM MET NORWAY"), updLine = text.find((t) => /^UPDATED \d/.test(t[0]));
    check(`${tag} ${id}: the credits and UPDATED are one stack at x 90, 16 px, 22 px apart, ending at the safe edge`, credits.every((t) => pxOf(t) === 16 && t[0] !== undefined && t[2] === 90) && metLine && updLine && updLine[3] === 1018 && metLine[3] === 996 && (id !== "radar" || text.find((t) => /^(RADAR: NOAA|DATA SOURCE: ENVIRONMENT|Datenbasis: )/.test(t[0]))[3] === 974), JSON.stringify(credits));
    check(`${tag} ${id}: nothing on the screen is smaller than the credits, and nothing else is under 25 px`, others.every((t) => pxOf(t) >= 25), JSON.stringify(others.filter((t) => pxOf(t) < 25)));
    check(`${tag} ${id}: drawn with DM Mono and VT323`, text.some((t) => /DM Mono/.test(t[1])) && text.some((t) => /VT323/.test(t[1])));
    check(`${tag} ${id}: the canvas holds a picture`, (await canvasInk(page)) > 8);
    if (id === "current") {
      check(`${tag} current: Celsius for a Canadian place, the golden numbers`, strings.includes("6") && strings.includes("C") && strings.includes("NNW 17 KM/H") && strings.includes("1025 HPA") && strings.includes("CLOUDY"), JSON.stringify(strings));
      check(`${tag} current: FEELS LIKE and AS OF`, strings.includes("FEELS LIKE 3°") && strings.some((t) => /^AS OF \d/.test(t)));
    }
    if (id === "today") check(`${tag} today: four periods, TODAY then TOMORROW`, ["AFTERNOON", "EVENING", "OVERNIGHT", "MORNING"].every((p) => strings.includes(p)) && strings.includes("TODAY") && strings.includes("TOMORROW"), JSON.stringify(strings));
    if (id === "week") check(`${tag} week: TODAY, MON, TUE, WED, THU`, ["TODAY", "MON", "TUE", "WED", "THU"].every((d) => strings.includes(d)) && strings.includes("HIGH") && strings.includes("LOW"), JSON.stringify(strings));
    if (id === "radar") {
      check(`${tag} radar: the Environment Canada credit, the legend, the pin's name`, strings.includes("DATA SOURCE: ENVIRONMENT AND CLIMATE CHANGE CANADA") && strings.includes("LIGHT") && strings.includes("EXTREME") && strings.includes("TORONTO"), JSON.stringify(strings));
      check(`${tag} radar: the frame's time`, strings.some((t) => /MIN AGO$/.test(t)));
    }
    await shot(page, `weather-${id}-${tag}`);
  }
  check(`${tag}: the page does not scroll sideways`, await page.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1));
  const box = await page.evaluate(() => { const c = document.getElementById("weather-screen").getBoundingClientRect(), v = document.getElementById("video-container").getBoundingClientRect(); return { c: [c.left, c.top, c.width, c.height], v: [v.left, v.top, v.width, v.height] }; });
  check(`${tag}: the canvas fills the picture`, Math.abs(box.c[2] - box.v[2]) < 2 && Math.abs(box.c[3] - box.v[3]) < 2, JSON.stringify(box));
  if (tag === "1920x1080") {
    // The guide row and the info panel.
    await setClock(page, at(0));
    await page.waitForTimeout(600);
    const row = await page.evaluate((id) => {
      const r = document.querySelector(`#grid-body > .grid-row[data-channel-id="${id}"]`);
      return r ? { num: r.querySelector(".grid-ch-num").textContent.trim(), name: r.querySelector(".grid-ch-name").textContent.trim(), prog: [...r.querySelectorAll(".grid-program")].map((p) => p.textContent.trim()), active: r.classList.contains("active"), bar: (() => { const b = r.querySelector(".grid-program"), c = r.querySelector(".grid-row-programs"); return b ? { w: b.getBoundingClientRect().width, cw: c.getBoundingClientRect().width, start: b.dataset.start || null, end: b.dataset.end || null, now: b.classList.contains("now-playing"), bg: b.style.background } : null; })() } : null;
    }, CH_ID);
    check("guide: CH 299 is one full-width bar, LOCAL WEATHER and the temperature, no times, on now, in the row colour", row && row.num === "299" && row.name === "LOCAL WEATHER" && row.prog.length === 1 && row.prog[0] === "LOCAL WEATHER  6\u00B0C" && row.active && row.bar.w >= row.bar.cw - 1 && row.bar.start === null && row.bar.end === null && row.bar.now && /rgba?\(0, 212, 255|#00d4ff/i.test(row.bar.bg), JSON.stringify(row));
    // The time header scrolls; the bar does not break into blocks and is on now at every position. Left and Right on it step nothing.
    const moved = await page.evaluate((id) => {
      guideFocusIndex = getEnabledChannels().findIndex((c) => c.id === id); updateGuideFocus();
      const out = {};
      guideSlotOffset = 3; renderGrid(); const r = document.querySelector(`#grid-body > .grid-row[data-channel-id="${id}"]`);
      out.later = { bars: r.querySelectorAll(".grid-program").length, now: r.querySelector(".grid-program").classList.contains("now-playing"), slot: document.querySelector(".grid-time-slot").textContent };
      out.cursor = r.querySelector(".grid-program").classList.contains("grid-program--cursor");
      guideSlotOffset = 0; guideCursorTime = null; renderGrid();
      return out;
    }, CH_ID);
    check("guide: the time header moves, the bar stays one live bar with the cursor on it", moved.later.bars === 1 && moved.later.now && moved.cursor, JSON.stringify(moved));
    await page.keyboard.press("ArrowRight");
    const afterRight = await page.evaluate(() => ({ t: guideCursorTime, off: guideSlotOffset }));
    check("guide: Right on the weather row steps through no blocks", afterRight.t === null && afterRight.off === 0, JSON.stringify(afterRight));
    const live = await page.evaluate(() => ({ time: document.getElementById("info-time").textContent, up: document.getElementById("info-upnext").textContent, prog: document.getElementById("info-progress").style.width, np: document.getElementById("np-time").textContent }));
    check("info panel: LIVE, no UP NEXT", live.time === "LIVE" && live.up === "" && live.np === "LIVE", JSON.stringify(live));
    const info = await page.evaluate(() => ({ tag: document.getElementById("info-channel-tag").textContent, title: document.getElementById("info-title").textContent, ep: document.getElementById("info-episode-title").textContent, desc: document.getElementById("info-description").textContent }));
    check("info panel: the channel, the place, a summary", /CH 299 - LOCAL WEATHER/.test(info.tag) && info.title === "LOCAL WEATHER" && info.ep === "TORONTO, ON, CA" && /^Cloudy, 6°C\./.test(info.desc), JSON.stringify(info));
    await page.evaluate((id) => { const r = document.querySelector(`#grid-body > .grid-row[data-channel-id="${id}"]`); if (r) r.scrollIntoView({ block: "center" }); }, CH_ID);
    await page.waitForTimeout(300);
    await shot(page, "guide-with-weather-1920x1080");
    // The page's own other outside calls (the QR library, plex.tv sign-in) are not the weather's; none of them may carry the place.
    check("privacy: nothing outside carries the place, and no weather service is called but the relay and the radar hosts", s.seen.every((u) => !/43\.6|79\.3|met\.no|geonames|nostalgex\.app\/api\/weather/.test(u)), s.seen.join(" "));
    check("privacy: the relay is asked once, with the rounded place and the client header, and no cookie", s.relayCalls.length >= 1 && s.relayCalls.every((c) => /\/api\/weather\?lat=43\.65&lon=-79\.38$/.test(c.url) && c.headers["x-nostalgex-client"] === "web" && !c.headers.cookie), JSON.stringify(s.relayCalls.map((c) => c.url)));
    check("privacy: the relay is not asked again within the window", s.relayCalls.length === 1, String(s.relayCalls.length));
    check("privacy: MET is never called from the browser", ![...s.relayCalls.map((c) => c.url), ...s.radarCalls].some((u) => /api\.met\.no/.test(u)));
    check("radar: Canada asks the capabilities, then both layers for each frame", s.radarCalls.some((u) => /request=GetCapabilities/i.test(u) && /RADAR_1KM_RRAI/.test(u)) && s.radarCalls.some((u) => /layers=RADAR_1KM_RSNO/.test(u)) && s.radarCalls.some((u) => /layers=RADAR_1KM_RRAI/.test(u)));
    check("radar: the window is at 2 decimals or fewer in latitude and longitude only as a bounding box", s.radarCalls.filter((u) => /GetMap/i.test(u)).every((u) => /bbox=-?[\d.]+,-?[\d.]+,-?[\d.]+,-?[\d.]+/.test(u)));
  }
  check(`${tag}: no errors`, s.errors.length === 0, s.errors.join(" | "));
  await s.ctx.close();
}

// ═══ 2. No location, then Settings > WEATHER ═══
{
  const s = await open({ width: 1920, height: 1080, place: null });
  const { page } = s;
  await tune(page);
  await page.waitForFunction(() => document.getElementById("weather-screen").classList.contains("on") && WX.fonts, null, { timeout: 15000 });
  const text = (await drawn(page)).map((t) => t[0]);
  check("no location: SET YOUR LOCATION IN SETTINGS", text.includes("SET YOUR LOCATION IN SETTINGS") && text.includes("LOCAL WEATHER") && text.includes("DATA FROM MET NORWAY"), JSON.stringify(text));
  check("no location: nothing is asked of the relay", s.relayCalls.length === 0);
  const btn = await page.evaluate(() => { const b = document.querySelector("#weather-actions .nx-btn"); const r = b.getBoundingClientRect(); return { on: document.getElementById("weather-actions").classList.contains("on"), w: r.width, h: r.height, text: b.textContent }; });
  check("no location: a real button opens the setting (for a TV browser with no keys)", btn.on && btn.w > 60 && btn.h > 20 && btn.text === "SET LOCATION", JSON.stringify(btn));
  await shot(page, "weather-no-location-1920x1080");
  const info = await page.evaluate(() => document.getElementById("info-description").textContent);
  check("no location: the info panel says what to do", /Set your location in Settings/.test(info), info);

  // Before it is set, the row in CHANNELS & BUNDLES says NOT SET; PLAYBACK & PICTURE has no weather in it.
  await page.evaluate(() => { showConfig(); switchConfigTab("bundles"); });
  const row0 = await page.evaluate(() => { const r = [...document.querySelectorAll("#channels-list-rows .chan-link")].find((b) => /LOCAL WEATHER/.test(b.textContent)); return r ? { t: r.querySelector(".chan-link-title").textContent, v: r.querySelector(".chan-link-value").textContent, n: document.querySelectorAll("#channels-list-rows .chan-link").length } : null; });
  check("CHANNELS & BUNDLES has one LOCAL WEATHER link row, after the collections, saying NOT SET", row0 && row0.t === "LOCAL WEATHER" && row0.v === "NOT SET" && row0.n === 4, JSON.stringify(row0));
  check("PLAYBACK & PICTURE no longer has a weather section", await page.evaluate(() => { const g = document.getElementById("config-tab-general"); return !g.querySelector("#wx-input, #wx-units-chips, #wx-channel-toggle, .wx-credits") && !/WEATHER/.test(g.textContent); }));
  check("the weather controls are on their own page, hidden until the row is opened", await page.evaluate(() => document.getElementById("channels-page-weather").hidden && !!document.getElementById("channels-page-weather").querySelector("#wx-input, #wx-units-chips, #wx-channel-toggle, .wx-credits")));
  await page.evaluate(() => { hideConfig(); });
  await page.click("#weather-actions .nx-btn");
  await page.waitForFunction(() => document.getElementById("config-overlay").classList.contains("open") && !document.getElementById("wx-search").hidden);
  check("the button opens Settings on the LOCAL WEATHER page (CHANNELS & BUNDLES) with the box ready", await page.evaluate(() => configTab === "bundles" && channelsPage === "weather" && document.getElementById("config-pane-title").textContent === "LOCAL WEATHER") &&
    await page.evaluate(() => !document.getElementById("chan-back").hidden && document.getElementById("chan-back-label").textContent === "CHANNELS & BUNDLES"));
  check("the box is ready", await page.waitForFunction(() => document.activeElement && document.activeElement.id === "wx-input", null, { timeout: 3000 }).then(() => true, () => false));
  await page.fill("#wx-input", "tor");
  await page.waitForFunction(() => document.querySelectorAll("#wx-results .wx-result").length > 1);
  const matches = await page.$$eval("#wx-results .wx-result", (els) => els.map((e) => e.textContent));
  check("typing 'tor': matches, the biggest first", matches[0] === "TORONTO, ON, CA" && matches.length <= 8, JSON.stringify(matches));
  await page.fill("#wx-input", "toronto");
  await page.waitForFunction(() => (document.querySelector("#wx-results .wx-result") || {}).textContent === "TORONTO, ON, CA");
  await shot(page, "settings-weather-1920x1080");
  await page.click("#wx-results .wx-result:first-child");
  await page.waitForFunction(() => WX.place && WX.model);
  const saved = await page.evaluate(() => JSON.parse(localStorage.getItem("nostalgex_weather_place")));
  check("picking a match saves the town at 2 decimals with its time zone", saved.name === "Toronto" && saved.lat === 43.65 && saved.lon === -79.38 && saved.tz === "America/Toronto" && saved.cc === "CA", JSON.stringify(saved));
  check("the relay got exactly the rounded place", s.relayCalls.length === 1 && /lat=43\.65&lon=-79\.38$/.test(s.relayCalls[0].url), JSON.stringify(s.relayCalls.map((c) => c.url)));
  check("the page shows the place and offers REMOVE", await page.evaluate(() => document.getElementById("wx-place-desc").textContent === "TORONTO, ON, CA" && !document.getElementById("wx-remove-btn").hidden));
  check("the no-location button is gone", await page.evaluate(() => !document.getElementById("weather-actions").classList.contains("on")));
  const text2 = (await drawn(page)).map((t) => t[0]);
  check("the channel now reports Toronto", text2.includes("TORONTO, ON") && !text2.includes("SET YOUR LOCATION IN SETTINGS"), JSON.stringify(text2.slice(0, 6)));
  // Back returns to the row, which now says the place and that the channel is on.
  await page.keyboard.press("ArrowDown").catch(() => {});
  await page.click("#chan-back");
  const row1 = await page.evaluate(() => { const r = [...document.querySelectorAll("#channels-list-rows .chan-link")].find((b) => /LOCAL WEATHER/.test(b.textContent)); return { v: r.querySelector(".chan-link-value").textContent, focused: r.classList.contains("kfocus"), page: channelsPage, title: document.getElementById("config-pane-title").textContent }; });
  check("Back returns to the row, with the cursor on it, saying TORONTO, ON \u00B7 ON", row1.page === "list" && row1.focused && row1.v === "TORONTO, ON \u00B7 ON" && row1.title === "CHANNELS & BUNDLES", JSON.stringify(row1));
  await shot(page, "settings-weather-row-1920x1080");
  await page.evaluate(() => { document.querySelector("#channels-list-rows .chan-link.kfocus").click(); });
  await page.waitForFunction(() => channelsPage === "weather");
  check("the row opens the page again, LOCATION first", await page.waitForFunction(() => document.activeElement && document.activeElement.id === "wx-change-btn", null, { timeout: 3000 }).then(() => true, () => false));
  await page.keyboard.press("ArrowDown");
  check("Up and Down walk the page's controls", await page.evaluate(() => document.activeElement && document.activeElement.id === "wx-remove-btn"));
  await page.keyboard.press("ArrowLeft");
  check("Left goes back a page, as on the others", await page.evaluate(() => channelsPage === "list"));
  await page.evaluate(() => { openChannelsPage("weather"); });
  // The credit line.
  const credits = await page.evaluate(() => document.querySelector(".wx-credits").textContent);
  check("Settings carries the MET Norway, GeoNames, radar and Natural Earth credits and the privacy line", /MET Norway/.test(credits) && /CC BY 4\.0/.test(credits) && /GeoNames/.test(credits) && /Natural Earth/.test(credits) && /National Weather Service/.test(credits) && /Environment and Climate Change Canada/.test(credits) && /rounded to about a kilometre/.test(credits), credits);
  // Units.
  check("units AUTO on a Canadian place is Celsius", await page.evaluate(() => wxUnits() === "C"));
  await page.click('#wx-units-chips [data-units="F"]');
  await page.waitForFunction(() => wxUnits() === "F");
  await setClock(page, at(0));
  let t3 = (await drawn(page)).map((t) => t[0]);
  check("units F: 44 and 10 mph in the drawn text", t3.includes("44") && t3.includes("F") && t3.includes("NNW 10 MPH") && t3.includes("30.27 IN"), JSON.stringify(t3));
  check("the chip shows what is chosen", await page.evaluate(() => document.querySelector('#wx-units-chips [data-units="F"]').getAttribute("aria-pressed") === "true"));
  await page.click('#wx-units-chips [data-units="auto"]');
  // The switch.
  await page.click("#wx-channel-toggle");
  await page.waitForFunction((id) => !CHANNELS.some((c) => c.id === id), CH_ID);
  await page.evaluate(() => { renderGrid(); });
  check("switch OFF: the channel leaves the guide and the picture goes", await page.evaluate((id) => !document.querySelector(`#grid-body > .grid-row[data-channel-id="${id}"]`) && !document.getElementById("weather-screen").classList.contains("on") && currentChannel !== id, CH_ID));
  check("switch OFF: it is remembered, and the row says OFF", await page.evaluate(() => localStorage.getItem("nostalgex_weather_channel") === "0" && wxStatusText() === "TORONTO, ON \u00B7 OFF"));
  await page.click("#wx-channel-toggle");
  await page.waitForFunction((id) => CHANNELS.some((c) => c.id === id), CH_ID);
  check("the row says ON again", await page.evaluate(() => wxStatusText() === "TORONTO, ON \u00B7 ON"));
  check("switch ON: it is back, last in the guide", await page.evaluate((id) => CHANNELS[CHANNELS.length - 1].id === id, CH_ID));
  await page.click("#wx-remove-btn");
  check("REMOVE forgets the place and the saved forecast", await page.evaluate(() => !localStorage.getItem("nostalgex_weather_place") && !localStorage.getItem("nostalgex_weather_forecast") && !WX.place));
  check("settings: no errors", s.errors.length === 0, s.errors.join(" | "));
  await s.ctx.close();
}

// ═══ 3. Another country: Fahrenheit for a US place, radar from NOAA; no radar in the UK ═══
{
  const s = await open({ width: 1920, height: 1080, place: BUFFALO });
  const { page } = s;
  await tune(page);
  await page.waitForFunction(() => document.getElementById("weather-screen").classList.contains("on") && WX.model && WX.fonts, null, { timeout: 15000 });
  await setClock(page, at(0));
  const cur = (await drawn(page)).map((t) => t[0]);
  check("US place: Fahrenheit, mph, inches of mercury", cur.includes("44") && cur.includes("F") && cur.includes("NNW 10 MPH") && cur.includes("30.27 IN") && cur.includes("BUFFALO, NY"), JSON.stringify(cur));
  await setClock(page, at(3));
  await page.waitForFunction(() => WX.radar.status === "ready" && WX.radar.frames.length >= 4, null, { timeout: 15000 });
  const rad = (await drawn(page)).map((t) => t[0]);
  check("US place: the NOAA credit on the radar", rad.includes("RADAR: NOAA NATIONAL WEATHER SERVICE") && rad.includes("DATA FROM MET NORWAY"), JSON.stringify(rad));
  check("US place: one NOAA layer per frame, eight frames, the CONUS composite", s.radarCalls.filter((u) => /GetMap/i.test(u) && /conus_bref_qcd/.test(u)).length === 8, String(s.radarCalls.length));
  await shot(page, "weather-radar-us-1920x1080");
  await s.ctx.close();

  const uk = await open({ width: 1920, height: 1080, place: LONDON });
  await tune(uk.page);
  await uk.page.waitForFunction(() => document.getElementById("weather-screen").classList.contains("on") && WX.model && WX.fonts, null, { timeout: 15000 });
  await setClock(uk.page, at(3));
  const none = (await drawn(uk.page)).map((t) => t[0]);
  check("UK place: RADAR NOT AVAILABLE IN YOUR AREA, and still the forecast credit", none.includes("RADAR NOT AVAILABLE IN YOUR AREA") && none.includes("DATA FROM MET NORWAY"), JSON.stringify(none));
  check("UK place: no radar request at all", uk.radarCalls.length === 0);
  await setClock(uk.page, at(0));
  const ukCur = (await drawn(uk.page)).map((t) => t[0]);
  check("UK place: Celsius", ukCur.includes("C") && ukCur.includes("LONDON, GB"), JSON.stringify(ukCur.slice(0, 12)));
  await shot(uk.page, "weather-radar-not-available-1920x1080");
  check("UK place: no errors", uk.errors.length === 0, uk.errors.join(" | "));
  await uk.ctx.close();
}

// ═══ 4. GUIDE TEXT SIZE LARGE: bigger text, same layout ═══
{
  const sizeOf = (text, label) => { const t = text.find((x) => x[0] === label); const m = t && /(\d+(?:\.\d+)?)px/.exec(t[1]); return m ? Number(m[1]) : null; };
  const a = await open({ width: 1920, height: 1080 });
  await tune(a.page);
  await a.page.waitForFunction(() => WX.model && WX.fonts, null, { timeout: 15000 });
  await setClock(a.page, at(0));
  const normal = await drawn(a.page);
  await shot(a.page, "weather-current-text-normal-1920x1080");
  await a.ctx.close();
  const b = await open({ width: 1920, height: 1080, large: true });
  await tune(b.page);
  await b.page.waitForFunction(() => WX.model && WX.fonts, null, { timeout: 15000 });
  await setClock(b.page, at(0));
  const large = await drawn(b.page);
  await shot(b.page, "weather-current-text-large-1920x1080");
  const ratio = sizeOf(large, "WIND") / sizeOf(normal, "WIND");
  check("LARGE: the row label is the Apple TV's 29 to 34 step (x1.16)", Math.abs(ratio - 1.16) < 0.02 && sizeOf(normal, "WIND") === 29, `${sizeOf(normal, "WIND")} -> ${sizeOf(large, "WIND")}`);
  check("LARGE: the big temperature does not change size", sizeOf(normal, "6") === sizeOf(large, "6"));
  check("LARGE: the same things are drawn, none lost", JSON.stringify(normal.map((t) => t[0])) === JSON.stringify(large.map((t) => t[0])));
  await b.ctx.close();
}

// ═══ 5. The music: one bundled loop, on the SOUND control ═══
{
  const asked = () => fileLog.filter((u) => /local-forecast/.test(u)).length;
  const was = asked();
  const s = await open({ width: 1920, height: 1080 });
  const { page } = s;
  const before = asked() - was;   // loading the tuner and its guide fetches none of it
  const el = await page.evaluate(() => { const a = document.getElementById("weather-music"); return { loop: a.loop, preload: a.preload, paused: a.paused, src: a.getAttribute("src"), sources: a.querySelectorAll("source").length }; });
  check("the loop is an audio element that loops, with no source and nothing fetched before the channel is tuned", el.loop && el.preload === "none" && el.paused && el.src === null && el.sources === 0 && before === 0, JSON.stringify([el, before]));
  await page.evaluate(() => {
    // Music videos in the library are not used for the channel any more.
    allItemsCache.push({ librarySource: "musicVideo", type: "movie", ratingKey: "m1", title: "Song", artist: "Band", duration: 210, container: "mp4", videoCodec: "h264", audioCodec: "aac", year: 1991 });
  });
  await tune(page);
  await page.waitForFunction(() => document.getElementById("weather-screen").classList.contains("on") && !document.getElementById("weather-music").paused, null, { timeout: 10000 });
  const on = await page.evaluate(() => { const a = document.getElementById("weather-music"); return { paused: a.paused, muted: a.muted, videoSrc: document.getElementById("plex-video").getAttribute("src"), tracker: playbackTracker, up: document.getElementById("info-upnext").textContent, volume: a.volume }; });
  check("tuned: the m4a (or the mp3 where AAC is not played) is the source", await page.evaluate(() => /^weather\/music\/local-forecast\.(m4a|mp3)$/.test(document.getElementById("weather-music").getAttribute("src"))));
  check("tuned: the loop plays, muted like the page until SOUND is turned on, no video under it, no watch report", !on.paused && on.muted === true && !on.videoSrc && on.tracker === null, JSON.stringify(on));
  check("tuned: the page's own file (weather/music/) is asked for, now", asked() - was >= 1 && fileLog.slice(-20).some((u) => /\/weather\/music\/local-forecast\.(m4a|mp3)$/.test(u)), JSON.stringify(fileLog.filter((u) => /music/.test(u))));
  check("no music video from the library is played or named", !on.up && !(await page.evaluate(() => /Band|Song/.test(document.getElementById("info-panel").textContent))));
  await page.evaluate(() => toggleMute());
  check("SOUND on: the loop is audible", await page.evaluate(() => document.getElementById("weather-music").muted === false && videoMuted === false));
  await page.evaluate(() => toggleMute());
  check("SOUND off: the loop is muted again", await page.evaluate(() => document.getElementById("weather-music").muted === true));
  const meta = await page.evaluate(() => new Promise((resolve) => {
    const a = document.getElementById("weather-music");
    if (a.readyState >= 1) return resolve({ d: a.duration, ok: true });
    const t = setTimeout(() => resolve({ d: null, ok: !!(a.canPlayType("audio/mpeg") || a.canPlayType("audio/mp4")) }), 6000);
    a.addEventListener("loadedmetadata", () => { clearTimeout(t); resolve({ d: a.duration, ok: true }); }, { once: true });
  }));
  check("the loop is 2 to 4 minutes long (when this browser can decode it)", meta.d === null ? !meta.ok : (meta.d > 120 && meta.d < 240), JSON.stringify(meta));
  await page.evaluate(() => { stopVideo(); });
  check("the sleep timer's stop (stopVideo) stops the loop", await page.evaluate(() => document.getElementById("weather-music").paused));
  await page.evaluate((id) => { currentChannel = null; switchChannel(id, true); }, CH_ID);
  await page.waitForFunction(() => !document.getElementById("weather-music").paused, null, { timeout: 5000 });
  await page.evaluate(() => { const other = CHANNELS.find((c) => !c.weather && c.enabled); switchChannel(other.id, true); });
  check("leaving the channel stops the loop and the weather screen", await page.evaluate(() => document.getElementById("weather-music").paused && !document.getElementById("weather-screen").classList.contains("on") && WX.timer === null));
  check("music: no errors", s.errors.length === 0, s.errors.join(" | "));
  await s.ctx.close();
}

// ═══ 5a. Germany: DWD radar ═══
{
  const BERLIN = { name: "Berlin", region: "Land Berlin", cc: "DE", lat: 52.52, lon: 13.41, tz: "Europe/Berlin", kind: "city" };
  const s = await open({ width: 1920, height: 1080, place: BERLIN });
  const { page } = s;
  await tune(page);
  await page.waitForFunction(() => document.getElementById("weather-screen").classList.contains("on") && WX.model && WX.fonts, null, { timeout: 15000 });
  await setClock(page, at(3));
  await page.waitForFunction(() => WX.radar.status === "ready" && WX.radar.frames.length >= 4, null, { timeout: 15000 });
  const clock = at(3);
  const strings = (await drawn(page)).map((t) => t[0]);
  check("Germany: DWD's own source note, in its wording, on the radar", strings.includes("Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben") && strings.includes("DATA FROM MET NORWAY") && !strings.includes("RADAR NOT AVAILABLE IN YOUR AREA"), JSON.stringify(strings));
  const caps = s.radarCalls.filter((u) => /GetCapabilities/i.test(u));
  check("Germany: only the one layer's capabilities are asked for (not the whole server's)", caps.length === 1 && caps[0].startsWith("https://maps.dwd.de/geoserver/dwd/Niederschlagsradar/wms?"), JSON.stringify(caps));
  const maps = s.radarCalls.filter((u) => /GetMap/i.test(u));
  const times = maps.map((u) => Date.parse(decodeURIComponent(/time=([^&]+)/.exec(u)[1])));
  check("Germany: eight frames of the one layer, a 10 minute step, none after the clock minus 10 minutes (the range runs into the nowcast)", maps.length === 8 && maps.every((u) => /layers=dwd:Niederschlagsradar/.test(u)) && times.every((t) => t <= clock - 10 * 60000) && times.every((t, i) => i === 0 || Math.abs(t - times[i - 1] - 600000) < 6 * 60000), JSON.stringify(times.map((t) => new Date(t).toISOString())));
  const px = await page.evaluate(() => {
    const f = WX.radar.frames[0].canvas, g = f.getContext("2d");
    const at = (x, y) => Array.from(g.getImageData(x, y, 1, 1).data);
    let echo = 0, extreme = 0;
    const d = g.getImageData(0, 0, f.width, f.height).data;
    for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 0) { echo++; if (d[i] === 255 && d[i + 1] === 45 && d[i + 2] === 180) extreme++; }
    return { grey: at(5, 50), edge: at(12, 50), edge2: at(13, 50), white: at(300, 10), echo, extreme };
  });
  check("Germany: grey outside the radars, white without echo and the magenta coverage edge are clear; echoes are drawn", px.grey[3] === 0 && px.white[3] === 0 && px.edge[3] === 0 && px.edge2[3] === 0 && px.echo > 200, JSON.stringify(px));
  check("Germany: the EXTREME band is not drawn (the style's edge colour is its colour)", px.extreme === 0, String(px.extreme));
  await shot(page, "weather-radar-germany-1920x1080");
  check("Germany: no errors", s.errors.length === 0, s.errors.join(" | "));
  await s.ctx.close();
}

// ═══ 5b. The Docker tuner: the same page, the site's relay from another origin, the self-host client header ═══
{
  const s = await open({ width: 1920, height: 1080, selfhost: true });
  const { page } = s;
  await tune(page);
  await page.waitForFunction(() => WX.model && WX.fonts, null, { timeout: 15000 });
  check("Docker: the forecast comes from www.nostalgex.app/api/weather, with the self-host client header, rounded", s.relayCalls.length === 1 && s.relayCalls[0].url === "https://www.nostalgex.app/api/weather?lat=43.65&lon=-79.38" && s.relayCalls[0].headers["x-nostalgex-client"] === "selfhost", JSON.stringify(s.relayCalls.map((c) => [c.url, c.headers["x-nostalgex-client"]])));
  check("Docker: the place list is the page's own (weather/places/), not a service", await page.evaluate(async () => { const r = await fetch("weather/places/meta.json"); return r.ok && (await r.json()).postcodes.includes("US"); }));
  check("Docker: no errors", s.errors.length === 0, s.errors.join(" | "));
  await s.ctx.close();
}

// ═══ 5c. CH 299 tuned from a playing channel (Android drew the radar see-through over the last film): the old picture and sound stop, the weather is opaque, tuning away restores a channel ═══
{
  const s = await open({ width: 1920, height: 1080 });
  const { page } = s;
  const oid = await page.evaluate(() => CHANNELS.find((c) => !c.weather && c.enabled).id);
  await tune(page, oid);
  await page.waitForFunction(() => document.getElementById("plex-video").getAttribute("src"), null, { timeout: 10000 });
  check("before: a normal channel is playing (the video has a source)", await page.evaluate(() => !!document.getElementById("plex-video").getAttribute("src")));
  await tune(page, CH_ID);
  await page.waitForFunction(() => document.getElementById("weather-screen").classList.contains("on") && WX.fonts, null, { timeout: 10000 });
  await page.waitForTimeout(700);
  const on = await page.evaluate(() => {
    const v = document.getElementById("plex-video"), c = document.getElementById("weather-screen"), cs = getComputedStyle(c), r = c.getBoundingClientRect(), vr = document.getElementById("video-container").getBoundingClientRect();
    const px = (x, y) => Array.from(c.getContext("2d").getImageData(x, y, 1, 1).data);
    return { src: v.getAttribute("src"), paused: v.paused, hls: typeof hlsInstance === "undefined" ? null : hlsInstance, tracker: playbackTracker, bg: cs.backgroundColor, opacity: cs.opacity, display: cs.display, z: cs.zIndex,
      corners: [px(0, 0), px(c.width - 1, 0), px(0, c.height - 1), px(c.width - 1, c.height - 1), px(960, 540)], covers: Math.abs(r.width - vr.width) < 2 && Math.abs(r.height - vr.height) < 2 && Math.abs(r.left - vr.left) < 2 };
  });
  check("tuning CH 299 stops the previous channel's video and sound (no source, paused, no player, no watch session)", on.src === null && on.paused && !on.hls && on.tracker === null, JSON.stringify(on));
  check("the weather view is opaque: a solid background, full opacity, every drawn corner and the centre at alpha 255", /^rgb\(10, 10, 26\)$/.test(on.bg) && on.opacity === "1" && on.display === "block" && on.corners.every((p) => p[3] === 255), JSON.stringify([on.bg, on.opacity, on.corners]));
  check("the weather view covers the whole picture, above the video", on.covers && Number(on.z) >= 2, JSON.stringify([on.covers, on.z]));
  // A tune that has not started playing yet (the stream lookup is still in flight) must not start under the weather afterwards.
  await page.evaluate((ids) => { switchChannel(ids.o, true); switchChannel(ids.w, true); }, { o: oid, w: CH_ID });
  await page.waitForTimeout(2500);
  const late = await page.evaluate(() => ({ src: document.getElementById("plex-video").getAttribute("src"), paused: document.getElementById("plex-video").paused, on: document.getElementById("weather-screen").classList.contains("on"), cur: currentChannel }));
  check("a tune of another channel overtaken by CH 299 never starts its video under the weather", late.src === null && late.paused && late.on && late.cur === CH_ID, JSON.stringify(late));
  await tune(page, oid);
  await page.waitForFunction(() => document.getElementById("plex-video").getAttribute("src"), null, { timeout: 10000 });
  const back = await page.evaluate(() => ({ on: document.getElementById("weather-screen").classList.contains("on"), actions: document.getElementById("weather-actions").classList.contains("on"), music: document.getElementById("weather-music").paused, timer: WX.timer, app: appState,
    failure: document.getElementById("channel-display").classList.contains("has-failure"), src: !!document.getElementById("plex-video").getAttribute("src"), cur: currentChannel }));
  check("tuning away: the weather view, its button, its loop and its timer are gone, the channel plays, no failure card", !back.on && !back.actions && back.music && back.timer === null && back.src && !back.failure && back.cur === oid, JSON.stringify(back));
  check("tuning back to CH 299 again works and is opaque again", await (async () => { await tune(page, CH_ID); await page.waitForTimeout(700); return page.evaluate(() => { const c = document.getElementById("weather-screen"); return c.classList.contains("on") && Array.from(c.getContext("2d").getImageData(5, 5, 1, 1).data)[3] === 255 && !document.getElementById("plex-video").getAttribute("src"); }); })());
  check("CH 299 over a channel: no errors", s.errors.length === 0, s.errors.join(" | "));
  await s.ctx.close();
}

// ═══ 6. A relay that fails ═══
{
  const s = await open({ width: 1920, height: 1080, relay: "fail" });
  const { page } = s;
  await tune(page);
  await page.waitForFunction(() => document.getElementById("weather-screen").classList.contains("on") && WX.fonts && WX.status === "error", null, { timeout: 15000 });
  const text = (await drawn(page)).map((t) => t[0]);
  check("relay down, nothing kept: FORECAST UNAVAILABLE RIGHT NOW", text.includes("FORECAST UNAVAILABLE RIGHT NOW") && text.includes("TRYING AGAIN SOON"), JSON.stringify(text));
  await shot(page, "weather-forecast-unavailable-1920x1080");
  s.setRelay("ok");
  await page.evaluate(() => { WX.failedMs = 0; return wxEnsureForecast(true); });
  await page.waitForFunction(() => WX.model, null, { timeout: 10000 });
  const text2 = (await drawn(page)).map((t) => t[0]);
  check("the relay comes back: the forecast draws", !text2.includes("FORECAST UNAVAILABLE RIGHT NOW") && text2.includes("TORONTO, ON"));
  // A kept forecast survives a reload with the relay down.
  s.setRelay("fail");
  const before = s.relayCalls.length;
  await page.reload();
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length >= 250 && CHANNELS.some((c) => c.enabled && c.schedule && c.schedule[0]), null, { timeout: 30000 });
  await page.waitForTimeout(500);
  await tune(page);
  await page.waitForFunction(() => WX.model && WX.fonts, null, { timeout: 10000 });
  check("a reload with the relay down still shows the kept forecast, and does not ask again before it is due", s.relayCalls.length === before);
  check("relay: no errors", s.errors.length === 0, s.errors.join(" | "));
  await s.ctx.close();
}

await browser.close();
files.close(); plex.close();
if (failures.length) {
  console.error(`weather browser smoke: ${failures.length} failed, ${passed} passed\n${failures.map((f) => "  " + f).join("\n")}`);
  process.exit(1);
}
console.log(`weather browser smoke: ${passed} checks passed`);
process.exit(0);
