#!/usr/bin/env node
/**
 * The card that says why a programme will not play is on screen in the split view.
 *
 * The web tuner shows a playback failure ("This one wouldn't play", amber for the server, red
 * for the browser) and a connection error in .channel-display. The split view, which is the
 * default at every size, hid that block with `display: none !important`, so the card had a
 * 0 by 0 box and the viewer got a black picture and no reason. The Apple TV and Roku draw
 * the card in their own windowed view.
 *
 * This loads the real plex-tuner.html, headless, against a Jellyfin-shaped server that
 * refuses every video request, lets the page's own recovery run (direct play, then the server
 * stream, then the card), and checks, at phone, tablet, desktop and 960x540:
 *   - the card is on screen, inside the picture, with its headline and detail;
 *   - the title lines of the text display are not drawn behind it;
 *   - a connection error ("NOT CONNECTED...") shows the same way;
 *   - clearing the error, or signing out, puts the split view back as it was;
 *   - the full view (the other layout) still shows it.
 *
 * Set SHOTS=/dir for screenshots. NX_TUNER_HTML=/path serves another copy of the page
 * (origin/main's, for the negative control) in place of plex-tuner.html; it must fail.
 * TUNER_ROOT=/path/to/dist (or dist-selfhost) runs on a build.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:failure-card:browser`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const repo = fileURLToPath(new URL("../", import.meta.url));
const root = process.env.TUNER_ROOT ? process.env.TUNER_ROOT.replace(/\/?$/, "/") : repo;
const shots = process.env.SHOTS || "";
if (shots) mkdirSync(shots, { recursive: true });

const TICKS = (min) => min * 60 * 10000000;
const items = [];
for (let i = 0; i < 30; i++) {
  items.push({
    Id: `m${i}`, Name: `Family Day ${i}`, Type: "Movie", ProductionYear: 1986 + (i % 13), Genres: ["Family", "Comedy"], OfficialRating: "PG",
    RunTimeTicks: TICKS(95), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", CommunityRating: 7.2,
    MediaSources: [{ Id: `ms${i}`, Container: "mp4", RunTimeTicks: TICKS(95), Size: 2000000, SupportsDirectPlay: true,
      MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Channels: 2, Index: 1 }] }],
  });
}
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = req.url;
  // Every picture is refused: the programme cannot play, and the page has to say so.
  if (url.startsWith("/Videos/")) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  if (url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
  if (url.startsWith("/UserViews")) return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.includes("/PlaybackInfo")) return res.end(JSON.stringify({ MediaSources: [], PlaySessionId: "s" }));
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

const browser = await chromium.launch({ headless: true });
const viewports = {
  desktop: { viewport: { width: 1440, height: 900 } },
  tablet: { viewport: { width: 820, height: 1180 } },
  phone: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 3 },
  tv960: { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 },
};

async function launch(name) {
  const ctx = await browser.newContext({ ...viewports[name], timezoneId: "America/New_York" });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
    }
  }, [api]);
  const page = await ctx.newPage();
  page.setDefaultTimeout(10000);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  return { ctx, page, errors };
}

const read = (page) => page.evaluate(() => {
  const rect = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return { l: r.left, t: r.top, rt: r.right, b: r.bottom, w: r.width, h: r.height }; };
  const shown = (el) => { if (!el) return false; const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return cs.display !== "none" && cs.visibility !== "hidden" && Number(cs.opacity) > 0.5 && r.width > 0 && r.height > 0; };
  const display = document.getElementById("channel-display");
  const status = document.getElementById("display-status");
  const title = display.querySelector(".playing-title-main");
  return {
    shown: shown(status), statusRect: rect(status), picture: rect(document.getElementById("video-container")),
    headline: (status.querySelector(".failure-headline") || {}).textContent || "",
    detail: (status.querySelector(".failure-detail") || {}).textContent || "",
    text: status.textContent || "",
    displayDisplay: getComputedStyle(display).display, hasFailure: display.classList.contains("has-failure"),
    titleDrawn: shown(title),
    layout: document.getElementById("player-screen").className,
    fullscreen: !!document.fullscreenElement, vw: innerWidth, vh: innerHeight,
  };
});

const insidePicture = (s) => s.statusRect && s.picture && s.statusRect.l >= s.picture.l - 0.5 && s.statusRect.rt <= s.picture.rt + 0.5 && s.statusRect.t >= s.picture.t - 0.5 && s.statusRect.b <= s.picture.b + 0.5;

for (const name of Object.keys(viewports)) try {
  if (process.env.DEBUG_FC) console.log("viewport", name);
  const { page, errors } = await launch(name);

  // The page's own recovery: the first channel's programme is refused, direct play falls back to
  // the server stream, that is refused too, and the card says so.
  await page.waitForFunction(() => document.getElementById("display-status").classList.contains("visible"), null, { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(600);
  let s = await read(page);
  check(`${name}: a programme the server will not stream shows the failure card`, s.shown && s.headline.length > 0 && s.detail.length > 0, `${s.headline} | shown ${s.shown} | display ${s.displayDisplay}`);
  check(`${name}: the card sits inside the picture`, insidePicture(s), JSON.stringify({ card: s.statusRect, picture: s.picture }));
  check(`${name}: the layout is the split view`, /layout-side/.test(s.layout), s.layout);
  check(`${name}: the text display's title lines are not drawn behind the card`, s.titleDrawn === false);
  if (shots && (name === "tv960" || name === "phone")) await page.screenshot({ path: join(shots, `failure-card-${name}.png`) });

  // A connection error shows the same way.
  await page.evaluate(() => { clearVideoError(); showVideoError("NOT CONNECTED. RECONNECT YOUR SERVER"); });
  await page.waitForTimeout(500);
  s = await read(page);
  check(`${name}: a connection error shows`, s.shown && /NOT CONNECTED/.test(s.text), s.text);
  check(`${name}: the connection error sits inside the picture`, insidePicture(s), JSON.stringify({ card: s.statusRect, picture: s.picture }));

  // Clearing puts the split view back as it was.
  await page.evaluate(() => clearVideoError());
  await page.waitForTimeout(300);
  s = await read(page);
  check(`${name}: clearing the error hides the block again in the split view`, s.displayDisplay === "none" && !s.hasFailure, `${s.displayDisplay} ${s.hasFailure}`);

  // Signing out ends the session the card belongs to: it must not be on screen over the next sign-in.
  await page.evaluate(() => { showPlaybackFailure(classifyPlaybackFailure({ noSource: true }), false); });
  await page.waitForTimeout(300);
  s = await read(page);
  check(`${name}: a failure card is up before the sign-out`, s.shown && s.hasFailure, `${s.displayDisplay} ${s.hasFailure}`);
  await page.evaluate(() => signOut());
  await page.waitForTimeout(400);
  s = await read(page);
  check(`${name}: signing out takes the card down in the split view`, !s.shown && s.displayDisplay === "none" && !s.hasFailure && s.text === "", `${s.shown} ${s.displayDisplay} ${s.hasFailure} "${s.text}"`);

  // The other layout still shows it.
  await page.evaluate(() => { toggleGuideLayout(); showPlaybackFailure(classifyPlaybackFailure({ noSource: true }), false); });
  await page.waitForTimeout(600);
  s = await read(page);
  check(`${name}: the full view still shows the card`, !/layout-side/.test(s.layout) && s.shown && s.headline.length > 0, `${s.layout} ${s.headline}`);
  check(`${name}: not in browser full screen`, s.fullscreen === false);
  check(`${name}: no page errors`, errors.length === 0, errors.join(" | "));
  await page.context().close();
} catch (err) {
  failures.push(`${name} flow stopped: ${String(err.message || err).split("\n")[0]}`);
}

await browser.close();
jellyfin.closeAllConnections?.();
files.closeAllConnections?.();
jellyfin.close();
files.close();

if (failures.length) {
  console.error(`failure card browser: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`failure card browser: ${passed} checks passed`);
process.exit(0);
