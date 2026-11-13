#!/usr/bin/env node
/**
 * The web tuner's guide screen as a viewer sees it, in the real plex-tuner.html (headless), against a Plex-shaped stub
 * whose titles have a synopsis, a year, a rating and a runtime. At 1280x800, 1440x900 and 1920x1080 it measures and checks:
 *
 *   - the now-playing window above the guide shows the programme's description, year, rating and runtime as well as its
 *     title, progress and UP NEXT (the window the web tuner had before 1.0.17, which the Apple TV's panel had replaced);
 *   - the sidebar next to it holds only the controls it held before 1.0.17 (sound, full screen, retro, sleep, info,
 *     settings and the links), and no control's label spills out of its button; captions, quality, subtitle language and
 *     the rest are in the playback menu, which one sidebar button opens;
 *   - the guide's channel number and name, programme titles, time labels and rows read at the Apple TV's proportions:
 *     on its 1080 canvas a row is 64 pt, row text 22 pt and the time labels 25 pt, so as a share of the window height 5.93%,
 *     2.04% and 2.31%. The test asserts the computed sizes at 1440x900 and 1920x1080 are within a tenth of that share.
 *
 * GUIDE_SCALE=0.9 re-draws the screenshots with another --guide-scale (the checks assume the page's own).
 * Every run prints MEASURE lines with the numbers; run it on another tree to compare:
 *   TUNER_ROOT=/path/to/tuner-v1.0.16 node scripts/web-layout-browser-smoke.mjs   (its checks will fail where it differs)
 * SHOTS=/dir saves a screenshot per size.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Run: `npm run test:web-layout:browser`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = process.env.TUNER_ROOT ? resolve(process.env.TUNER_ROOT) : fileURLToPath(new URL("../", import.meta.url));
const SHOTS = process.env.SHOTS || "";
if (SHOTS) mkdirSync(SHOTS, { recursive: true });

// ── The Apple TV's guide, from its source: row 64 pt, row text 22 pt, time labels 25 pt (NXType.caption) on a 1080 canvas ──
const CANVAS = 1080;
const APPLE = { row: 64 / CANVAS, text: 22 / CANVAS, time: 25 / CANVAS };
// ── What the guide is asked to be on a desktop window: modest, between the too-small 1.0.19 and the Apple TV's own size. A row of about 4.4% of
//    the window height and programme text of about 1.5% (the time labels follow at 1.7%). The page has one variable for it, --guide-scale. ──
const TARGET = { row: 0.044, text: 0.015, time: 0.017 };
const GUIDE_SCALE = Number((/--guide-scale:\s*([\d.]+)/.exec(readFileSync(join(root, "plex-tuner.html"), "utf8")) || [])[1] || 1); // older pages (TUNER_ROOT) have no variable

// ── A Plex-shaped stub: 400 films, each with a synopsis, a year, a content rating, a star rating and a runtime ──
const GENRES = ["Action", "Comedy", "Drama", "Thriller", "Horror", "Romance", "Science Fiction", "Adventure", "Animation", "Family", "Crime", "Mystery"];
const CERTS = ["G", "PG", "PG-13", "R"];
const N = 400;
// A 1x1 PNG: the poster the stub serves, stretched by the page to the poster box.
const POSTER = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
const media = (i) => [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${i}/file.mp4` }] }];
const film = (i) => ({
  ratingKey: String(1000 + i), title: `Family Day ${i}`, summary: `A long synopsis for film ${i}. A family spends one ordinary day together and nothing goes to plan, which is the whole point of it.`,
  year: 1980 + (i % 30), duration: (84 + (i % 40)) * 60000, type: "movie", addedAt: 1600000000 + i, contentRating: CERTS[i % CERTS.length],
  rating: 6 + (i % 30) / 10, Genre: [{ tag: GENRES[i % GENRES.length] }, { tag: GENRES[(i * 5 + 1) % GENRES.length] }, { tag: "Family" }],
  Guid: [{ id: `tmdb://${5000 + i}` }], Media: media(i), thumb: `/library/metadata/${1000 + i}/thumb/1`,
});
const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  res.setHeader("Content-Type", "application/json");
  if (url.pathname === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
  if (url.pathname === "/photo/:/transcode") { res.setHeader("Content-Type", "image/png"); return res.end(POSTER); }
  if (url.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }] } }));
  if (url.pathname === "/library/sections/1/all") {
    const start = Number(url.searchParams.get("X-Plex-Container-Start") || 0);
    const size = Number(url.searchParams.get("X-Plex-Container-Size") || N);
    const rows = [];
    for (let i = start; i < Math.min(N, start + size); i++) rows.push(film(i));
    return res.end(JSON.stringify({ MediaContainer: { size: rows.length, totalSize: N, Metadata: rows } }));
  }
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
// The page asks Google Fonts for VT323, Press Start 2P and Silkscreen (the self-host build vendors them). Headless has no internet, so the
// same fontsource files the self-host build copies answer that request, and the faces really render.
const FONT_PKGS = ["vt323", "press-start-2p", "silkscreen"];
const NODE_MODULES = fileURLToPath(new URL("../node_modules/", import.meta.url));
let fontCss = "";
for (const pkg of FONT_PKGS) for (const w of ["400", "700"]) {
  const f = join(NODE_MODULES, "@fontsource", pkg, `${w}.css`);
  if (existsSync(f)) fontCss += readFileSync(f, "utf8").replace(/url\(\.\/files\/([^)]+)\)/g, (m, name) => `url(__FONTS__/${pkg}/${name})`) + "\n";
}
const files = http.createServer((req, res) => {
  const fm = /^\/__fonts\/([a-z0-9-]+)\/([^/?]+)$/.exec(req.url.split("?")[0]);
  if (fm) {
    const f = join(NODE_MODULES, "@fontsource", fm[1], "files", fm[2]);
    if (!existsSync(f)) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { "Content-Type": "font/woff2", "Access-Control-Allow-Origin": "*" });
    return res.end(readFileSync(f));
  }
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) body = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => plex.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${plex.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

const fontRequests = [];
let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });

async function measure(width, height, ctxOpts = {}, tag = "", large = false) {
  const ctx = await browser.newContext({ viewport: { width, height }, ...ctxOpts });
  await ctx.route(/fonts\.googleapis\.com\/css2/, (route) => { fontRequests.push(decodeURIComponent(route.request().url()).replace(/\+/g, " ")); return route.fulfill({ contentType: "text/css", headers: { "access-control-allow-origin": "*" }, body: fontCss.replaceAll("__FONTS__", `${base}/__fonts`) }); });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost|fonts\.googleapis\.com)$/.test(u.hostname), (route) => route.abort());
  await ctx.addInitScript(([url, pageSize]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "plex", userToken: "t" }));
      if (pageSize) localStorage.setItem("nostalgex_page_size", pageSize);
    }
  }, [api, large ? "large" : null]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/plex-tuner.html`);
  // A first setup stops at CHOOSE YOUR LIBRARIES (1.0.17 and later); one click on CONTINUE starts the scan.
  await page.waitForFunction(() => (typeof allItemsCache !== "undefined" && allItemsCache.length > 0) || !!document.querySelector(".library-continue"), null, { timeout: 30000 });
  if (await page.$(".library-continue")) await page.click(".library-continue").catch(() => {});
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length >= 300 && typeof CHANNELS !== "undefined" && CHANNELS.some((c) => c.enabled && c.schedule && c.schedule[0]), null, { timeout: 60000 });
  await page.waitForTimeout(1500);
  // Tune a channel so the window above the guide has a programme to describe.
  await page.evaluate(() => {
    const ch = CHANNELS.find((c) => c.enabled && c.schedule && c.schedule[0]);
    if (ch && currentChannel === null) switchChannel(ch.id, true);
    if (typeof updateInfoPanel === "function") updateInfoPanel();
  });
  await page.waitForTimeout(1200);
  if (process.env.GUIDE_SCALE) { await page.addStyleTag({ content: `:root { --guide-scale: ${process.env.GUIDE_SCALE} !important; }` }); await page.waitForTimeout(400); }
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/guide-${width}x${height}${tag}.png` });
  const m = await page.evaluate(() => {
    const px = (el) => (el ? parseFloat(getComputedStyle(el).fontSize) : null);
    const text = (id) => { const el = document.getElementById(id); return el && getComputedStyle(el).display !== "none" ? el.textContent.trim() : null; };
    const shown = (el) => !!el && !el.hidden && getComputedStyle(el).display !== "none" && getComputedStyle(el).visibility !== "hidden" && el.getBoundingClientRect().width > 0;
    const label = (b) => { const l = b.querySelector(".v-btn-label"); return (l ? l.textContent : b.textContent).replace(/\s+/g, " ").trim(); };
    const side = [...document.querySelectorAll("#v-toolbar .v-btn")].filter(shown).map((b) => ({ label: label(b), spill: [...b.querySelectorAll(".v-btn-label,.v-btn-value")].some((s) => shown(s) && s.scrollWidth > s.clientWidth + 1) || b.scrollWidth > b.clientWidth + 1 }));
    const row = document.querySelector(".grid-row:not(.grid-row--promo)");
    const rowRect = row ? row.getBoundingClientRect() : null;
    const panelBox = document.getElementById("info-panel") ? document.getElementById("info-panel").getBoundingClientRect() : null;
    const desc = document.getElementById("info-description");
    const meta = document.getElementById("info-meta-row");
    return {
      vh: window.innerHeight, vw: window.innerWidth,
      title: text("info-title"), description: desc && shown(desc) ? desc.textContent.trim() : null, meta: meta && shown(meta) ? meta.textContent.replace(/\s+/g, " ").trim() : null,
      metaParts: meta && shown(meta) ? [...meta.children].map((c) => c.textContent.trim()) : [],
      posterShown: shown(document.getElementById("info-poster")), upnext: text("info-upnext"), time: text("info-time"),
      side, rowH: rowRect ? rowRect.height : null,
      num: px(document.querySelector(".grid-ch-num")), name: px(document.querySelector(".grid-ch-name")), program: px(document.querySelector(".grid-program")),
      slot: px(document.querySelector(".grid-time-slot")), head: px(document.querySelector(".grid-channel-col")),
      infoTitle: px(document.getElementById("info-title")), infoDesc: px(desc),
      panelH: panelBox ? panelBox.height : null, scrollV: document.scrollingElement.scrollHeight - document.scrollingElement.clientHeight,
      fonts: (() => {
        const fam = (el) => (el ? getComputedStyle(el).fontFamily : null);
        return { tag: fam(document.getElementById("info-channel-tag")), title: fam(document.getElementById("info-title")), badge: fam(document.querySelector(".info-meta-badge")), time: fam(document.getElementById("info-time")),
          upnext: fam(document.getElementById("info-upnext")), program: fam(document.querySelector(".grid-program")), slot: fam(document.querySelector(".grid-time-slot")), head: fam(document.querySelector(".grid-channel-col")),
          vt323: document.fonts.check('16px "VT323"'), pressStart: document.fonts.check('16px "Press Start 2P"') };
      })(),
      layout: (() => {
        const top = (el) => (el ? el.getBoundingClientRect().top : null), bottom = (el) => (el ? el.getBoundingClientRect().bottom : null);
        const tag = document.getElementById("info-channel-tag"), poster = document.getElementById("info-poster"), text = document.querySelector(".info-text");
        const up = document.getElementById("info-upnext"), cs = up ? getComputedStyle(up) : null;
        return { tagText: tag ? tag.textContent : null, tagColor: tag ? getComputedStyle(tag).color : null, tagBottom: bottom(tag), mainTop: poster && !poster.hidden ? top(poster) : top(text),
          tops: ["info-title", "info-meta-row", "info-description"].map((id) => top(document.getElementById(id))).concat([top(document.querySelector(".info-progress-wrap")), top(up)]),
          upnext: up ? up.textContent : null, upnextChildren: up ? up.children.length : null, upnextRadius: cs ? cs.borderTopLeftRadius : null, upnextBg: cs ? cs.backgroundColor : null, upnextBorder: cs ? cs.borderTopWidth : null,
          time: (document.getElementById("info-time") || {}).textContent, hasChannelName: !!document.getElementById("info-channel-name") };
      })(),
      panel: (() => {
        const p = document.getElementById("info-panel"); if (!p) return null;
        const pr = p.getBoundingClientRect(), up = document.getElementById("info-upnext"), pg = document.querySelector(".info-progress-wrap");
        const inside = (el) => !el || el.getBoundingClientRect().bottom <= pr.bottom + 1;
        return { scroll: p.scrollHeight, client: p.clientHeight, upnextInside: inside(up), progressInside: inside(pg), zoom: parseFloat(getComputedStyle(document.documentElement).zoom) || 1 };
      })(),
      rows: (() => { const row = document.querySelector(".grid-row:not(.grid-row--promo)"), body = document.getElementById("grid-body"); return row && body ? body.getBoundingClientRect().height / row.getBoundingClientRect().height : null; })(),
    };
  });
  // A file with subtitle and audio tracks: the one AUDIO & SUBS button shows, the rail still holds everything, and its menu lists the rows.
  const railBefore = await page.evaluate(() => { const tb = document.getElementById("v-toolbar"); return { scroll: tb.scrollHeight, client: tb.clientHeight }; });
  const withTracks = await page.evaluate(() => {
    currentPlayingItem = Object.assign({}, currentPlayingItem || {}, { subtitles: [{ index: 1, lang: "eng", title: "English" }], audioStreams: [{ index: 0, lang: "eng", title: "English" }, { index: 1, lang: "fra", title: "French" }] });
    renderTrackRows();
    const tb = document.getElementById("v-toolbar");
    const visible = (el) => !!el && !el.hidden && getComputedStyle(el).display !== "none" && el.getBoundingClientRect().height > 0;
    const btn = document.getElementById("tb-tracks");
    const last = [...tb.querySelectorAll("a.v-btn, a.v-coffee, .v-btn, .v-coffee")].filter(visible).pop();
    const area = document.getElementById("video-area").getBoundingClientRect();
    const railRows = [...tb.querySelectorAll(".track-row")].filter(visible).length;
    const spill = (() => {
      if (!visible(btn)) return null;
      const br = btn.getBoundingClientRect();
      const parts = [...btn.querySelectorAll(".v-btn-label,.v-btn-short,.v-btn-value")].filter(visible).map((e) => ({ cls: e.className, t: e.textContent.trim(), r: e.getBoundingClientRect() }));
      const out = parts.filter((x) => x.r.right > br.right + 0.5 || x.r.left < br.left - 0.5).map((x) => `${x.t} by ${Math.max(x.r.right - br.right, br.left - x.r.left).toFixed(1)} px`);
      const label = parts.find((x) => /v-btn-(label|short)/.test(x.cls)), value = parts.find((x) => /v-btn-value/.test(x.cls));
      if (label && value && value.t && label.r.right > value.r.left + 0.5 && Math.abs(label.r.top - value.r.top) < 4) out.push(`label and value overlap by ${(label.r.right - value.r.left).toFixed(1)} px`);
      return out;
    })();
    return { spill, btn: visible(btn) ? btn.textContent.replace(/\s+/g, " ").trim() : null, railTrackRows: railRows, scroll: tb.scrollHeight, client: tb.clientHeight, clipped: tb.scrollHeight > tb.clientHeight + 1, lastBottom: last ? last.getBoundingClientRect().bottom : null, areaBottom: area.bottom, insta: visible(document.querySelector(".v-toolbar a[href*='instagram']")), instaBottom: (document.querySelector(".v-toolbar a[href*='instagram']") || { getBoundingClientRect: () => ({ bottom: 9999 }) }).getBoundingClientRect().bottom };
  });
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/guide-with-tracks-${width}x${height}${tag}.png` });
  const menu = await page.evaluate(() => { document.getElementById("tb-tracks").click(); const d = document.getElementById("track-dialog"); return { open: !d.hidden, title: document.getElementById("track-dialog-title").textContent, rows: [...document.querySelectorAll("#track-rows .sleep-row")].map((r) => r.querySelector(".sleep-row-label").textContent.trim()) }; });
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/guide-tracks-${width}x${height}${tag}.png` });
  await ctx.close();
  return { ...m, errors, withTracks, menu, railBefore };
}

const SIZES = [[1280, 800], [1440, 900], [1920, 1080]];
// The same window with tracks, at the other common sizes too, for the new button's spill (1280x720 is a TV step, 1024x768 a tablet).
const SPILL_ONLY = [[1366, 768], [1280, 720], [1024, 768]];
const results = {};
const largeResults = {};
for (const [w, h] of [...SIZES, ...SPILL_ONLY]) {
  const m = await measure(w, h);
  results[`${w}x${h}`] = m;
  if (SPILL_ONLY.some(([a, b]) => a === w && b === h)) continue;
  const pct = (v) => (v == null ? "n/a" : `${(100 * v / m.vh).toFixed(2)}%`);
  console.log(`MEASURE ${w}x${h}: row ${m.rowH && m.rowH.toFixed(1)} px (${pct(m.rowH)} of the height; Apple TV ${(100 * APPLE.row).toFixed(2)}%, asked for ${(100 * TARGET.row).toFixed(1)}%), number ${m.num} px (${pct(m.num)}), name ${m.name} px (${pct(m.name)}), programme ${m.program} px (${pct(m.program)}), time ${m.slot} px (${pct(m.slot)}; Apple TV ${(100 * APPLE.time).toFixed(2)}%), heading ${m.head} px; row text Apple TV ${(100 * APPLE.text).toFixed(2)}%`);
  console.log(`MEASURE ${w}x${h}: window: title ${JSON.stringify(m.title)}, description ${m.description ? "yes (" + m.description.length + " chars)" : "NO"}, meta ${JSON.stringify(m.meta)}, poster ${m.posterShown}, up next ${m.upnext ? "yes" : "no"}; sidebar ${m.side.length} controls: ${m.side.map((b) => b.label + (b.spill ? " (SPILLS)" : "")).join(" | ")}`);
}

for (const [w, h] of SIZES) {
  const m = results[`${w}x${h}`];
  console.log(`MEASURE ${w}x${h}: with tracks: button ${JSON.stringify(m.withTracks.btn)}, track rows in the rail ${m.withTracks.railTrackRows}, rail scroll/client ${m.railBefore.scroll}/${m.railBefore.client} before, ${m.withTracks.scroll}/${m.withTracks.client} with the button, last control bottom ${m.withTracks.lastBottom && m.withTracks.lastBottom.toFixed(0)} of ${m.withTracks.areaBottom.toFixed(0)}; menu ${JSON.stringify(m.menu)}`);
}
for (const [w, h] of SIZES) {
  const key = `${w}x${h}`, m = results[key];
  check(`${key}: with subtitle and audio tracks the rail gets one AUDIO & SUBS button and no track rows`, !!m.withTracks.btn && /AUDIO & SUBS/.test(m.withTracks.btn) && m.withTracks.railTrackRows === 0, JSON.stringify(m.withTracks));
  check(`${key}: and still holds the links: Instagram is wholly on screen and the rail is not clipped`, m.withTracks.insta && !m.withTracks.clipped && m.withTracks.instaBottom <= m.withTracks.areaBottom + 1, JSON.stringify({ insta: m.withTracks.insta, clipped: m.withTracks.clipped, instaBottom: m.withTracks.instaBottom, area: m.withTracks.areaBottom }));
  check(`${key}: the menu lists captions, subtitle language, auto subtitles, audio and audio language`, m.menu.open && m.menu.rows.length === 5 && /CAPTIONS/.test(m.menu.rows[0]) && /SUBTITLE LANGUAGE/.test(m.menu.rows[1]) && /AUTO SUBTITLES/.test(m.menu.rows[2]) && /^AUDIO\b/.test(m.menu.rows[3]) && /AUDIO LANGUAGE/.test(m.menu.rows[4]), JSON.stringify(m.menu));
  check(`${key}: the now-playing window shows the programme's description`, !!m.description && /synopsis/.test(m.description), JSON.stringify(m.description));
  const parts = m.metaParts;
  check(`${key}: and its year, content rating and star rating, and no runtime`, parts.length === 3 && /^(19|20)\d\d$/.test(parts[0]) && /^(G|PG|PG-13|R)$/.test(parts[1]) && /^\u2605 \d\.\d$/.test(parts[2]), JSON.stringify(parts));
  const L = m.layout;
  check(`${key}: the channel line is across the top, above the poster and text, in the form "CH 05 - 90S SITCOMS"`, /^CH \d\d - [A-Z0-9 &'.-]+$/.test(L.tagText || "") && L.tagBottom <= L.mainTop + 1 && !L.hasChannelName, JSON.stringify({ t: L.tagText, bottom: L.tagBottom, mainTop: L.mainTop }));
  check(`${key}: the poster is shown (the stub has artwork), on the left under the channel line`, m.posterShown, String(m.posterShown));
  check(`${key}: the channel line is in the channel's colour, not white`, !!L.tagColor && L.tagColor !== "rgb(255, 255, 255)", L.tagColor);
  check(`${key}: top to bottom: title, meta, description, progress, up next`, L.tops.every((t, i) => t != null && (i === 0 || t > L.tops[i - 1])), JSON.stringify(L.tops));
  check(`${key}: the progress line has the elapsed and total time`, /\d+:\d\d \/ \d+:\d\d/.test(L.time || ""), L.time);
  check(`${key}: UP NEXT is one plain line "Up next in 44 min: the title": no pill, capsule, border or background`, /^Up next in (\d+|less than 1) min: .+/.test(L.upnext || "") && L.upnextChildren === 0 && L.upnextRadius === "0px" && L.upnextBorder === "0px" && L.upnextBg === "rgba(0, 0, 0, 0)", JSON.stringify(L));
  const F = m.fonts;
  check(`${key}: the 8-bit faces are loaded (VT323 and Press Start 2P)`, F.vt323 && F.pressStart, JSON.stringify({ vt: F.vt323, ps: F.pressStart }));
  const has = (fam, name) => !!fam && fam.includes(name);
  check(`${key}: window: Press Start 2P for the channel line and the badges; VT323 for the title, time and up next`, has(F.tag, "Press Start 2P") && has(F.badge, "Press Start 2P") && has(F.title, "VT323") && has(F.time, "VT323") && has(F.upnext, "VT323"), JSON.stringify(F));
  check(`${key}: guide: Press Start 2P for the CHANNEL heading; VT323 for programme titles and times`, has(F.head, "Press Start 2P") && has(F.program, "VT323") && has(F.slot, "VT323"), JSON.stringify(F));
  check(`${key}: and its title, progress and UP NEXT`, !!m.title && !!m.time && !!m.upnext);
  const labels = m.side.map((b) => b.label.replace(/\s*\[.*?\]/g, "").trim().toUpperCase());
  // Before 1.0.17 the sidebar held: sound, full screen, retro, sleep, info, quality, settings and the links.
  const OLD = ["SOUND", "FULLSCREEN", "FULL SCREEN", "RETRO", "SLEEP", "INFO", "QUALITY", "SETTINGS", "APPLE TV", "BUY ME A COFFEE", "INSTAGRAM"];
  const extra = labels.filter((l) => !OLD.some((o) => l === o || l.startsWith(o)));
  check(`${key}: the sidebar holds only the controls it held before 1.0.17 (the AUDIO & SUBS button is checked with tracks, below)`, extra.length === 0 && m.side.length <= 12, JSON.stringify({ extra, n: m.side.length }));
  check(`${key}: no sidebar label spills out of its button`, m.side.every((b) => !b.spill), m.side.filter((b) => b.spill).map((b) => b.label).join(", "));
  check(`${key}: no page errors`, m.errors.length === 0, m.errors.join(" | "));
}
// The guide at the size asked for (a row of about 4.4% of the window height, programme text about 1.5%, times 1.7%), at the two common desktop
// sizes, within 8%; and the page's one variable is what sets it (the Apple TV's share times --guide-scale).
for (const [w, h] of [[1440, 900], [1920, 1080]]) {
  const key = `${w}x${h}`, m = results[key];
  const share = (v) => v / m.vh;
  const near = (v, want) => v != null && Math.abs(share(v) - want) <= want * 0.08;
  check(`${key}: guide rows are about ${(100 * TARGET.row).toFixed(1)}% of the window height`, near(m.rowH, TARGET.row), `${(100 * share(m.rowH)).toFixed(2)}%`);
  check(`${key}: channel number, name and programme title are about ${(100 * TARGET.text).toFixed(1)}% of the height`, near(m.num, TARGET.text) && near(m.name, TARGET.text) && near(m.program, TARGET.text), `${(100 * share(m.num)).toFixed(2)} / ${(100 * share(m.name)).toFixed(2)} / ${(100 * share(m.program)).toFixed(2)}%`);
  check(`${key}: time labels are about ${(100 * TARGET.time).toFixed(1)}% of the height`, near(m.slot, TARGET.time), `${(100 * share(m.slot)).toFixed(2)}%`);
  const exact = (v, apple) => Math.abs(share(v) - apple * GUIDE_SCALE) < 0.0015;
  check(`${key}: and that is the Apple TV's size times --guide-scale (${GUIDE_SCALE})`, exact(m.rowH, APPLE.row) && exact(m.program, APPLE.text) && exact(m.slot, APPLE.time), `${(100 * share(m.rowH)).toFixed(2)} / ${(100 * share(m.program)).toFixed(2)} / ${(100 * share(m.slot)).toFixed(2)}%`);
}

// The new button's label and value fit inside it, with tracks present, at every size (the tablet has no rail, so it is only held to it if it shows).
for (const key of Object.keys(results)) {
  const m = results[key];
  const tablet = key === "1024x768";
  const shown = !!m.withTracks.btn;
  check(`${key}: AUDIO & SUBS shows with tracks${tablet ? " (or the tablet has no rail)" : ""}`, shown || tablet, JSON.stringify(m.withTracks));
  if (shown) {
    check(`${key}: AUDIO & SUBS label and value fit inside the button (no spill, no overlap)`, m.withTracks.spill && m.withTracks.spill.length === 0, JSON.stringify(m.withTracks.spill));
    console.log(`MEASURE ${key}: AUDIO & SUBS ${JSON.stringify(m.withTracks.btn)} spill ${JSON.stringify(m.withTracks.spill)}`);
  }
}

// PAGE SIZE LARGE (the page zoomed by 1.3333): the window above the guide still holds everything, and the guide keeps the Apple TV's proportions.
for (const [w, h] of [[1920, 1080], [1440, 900]]) {
  const key = `${w}x${h}`, N = results[key];
  const L = await measure(w, h, {}, "-large", true);
  largeResults[key] = L;
  console.log(`MEASURE ${key} PAGE SIZE LARGE: zoom ${L.panel && L.panel.zoom}, window ${L.panel && L.panel.scroll}/${L.panel && L.panel.client} (scroll/client), UP NEXT inside ${L.panel && L.panel.upnextInside}, progress inside ${L.panel && L.panel.progressInside}, rows in view ${L.rows && L.rows.toFixed(2)} (NORMAL ${N.rows && N.rows.toFixed(2)}), programme ${L.program} px (NORMAL ${N.program} px)`);
  check(`${key}: PAGE SIZE LARGE is on (the page is zoomed by a third)`, !!L.panel && Math.abs(L.panel.zoom - 1.3333) < 0.01, String(L.panel && L.panel.zoom));
  check(`${key}: NORMAL: the info window holds everything (scrollHeight <= clientHeight)`, !!N.panel && N.panel.scroll <= N.panel.client + 1 && N.panel.upnextInside && N.panel.progressInside, JSON.stringify(N.panel));
  check(`${key}: PAGE SIZE LARGE: the info window holds everything (scrollHeight <= clientHeight), progress and UP NEXT inside it`, !!L.panel && L.panel.scroll <= L.panel.client + 1 && L.panel.upnextInside && L.panel.progressInside, JSON.stringify(L.panel));
  check(`${key}: PAGE SIZE LARGE: the guide keeps the Apple TV's row proportion (as many rows in view as NORMAL, within one)`, L.rows != null && N.rows != null && Math.abs(L.rows - N.rows) <= 1, `${L.rows} vs ${N.rows}`);
  check(`${key}: PAGE SIZE LARGE: the description, year and rating are still in the window`, !!L.description && L.metaParts.length >= 3, JSON.stringify({ d: !!L.description, m: L.metaParts }));
  check(`${key}: PAGE SIZE LARGE: no page errors`, L.errors.length === 0, L.errors.join(" | "));
}

// The TV-browser and phone sizes keep their own layouts: shown for a look (EXTRA=1), not asserted on.
if (process.env.EXTRA) {
  for (const [w, h, o, tag] of [[960, 540, { deviceScaleFactor: 2 }, "-tv"], [390, 844, { deviceScaleFactor: 3, isMobile: true, hasTouch: true }, "-phone"]]) {
    const m = await measure(w, h, o, tag);
    console.log(`MEASURE ${w}x${h}${tag}: description ${m.description ? "yes" : "NO"}, meta ${JSON.stringify(m.metaParts)}, row ${m.rowH && m.rowH.toFixed(1)} px, programme ${m.program} px, time ${m.slot} px, sidebar ${m.side.length} controls, with tracks: button ${JSON.stringify(m.withTracks.btn)}, rail ${m.withTracks.scroll}/${m.withTracks.client}`);
  }
}
if (fontRequests.length) {
  check("the page asks Google Fonts for VT323 and Press Start 2P", fontRequests.every((q) => q.includes("family=VT323") && q.includes("family=Press Start 2P")), fontRequests[0]);
}

await browser.close();
plex.close();
files.close();
if (failures.length) {
  console.error(`web layout browser: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`web layout browser: ${passed} checks passed`);
process.exit(0);
