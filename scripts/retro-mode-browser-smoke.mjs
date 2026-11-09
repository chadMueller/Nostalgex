#!/usr/bin/env node
/**
 * RETRO MODE has no tracking line (Chad, 2026-11-09: viewers found the white drift line very distracting).
 * The real plex-tuner.html, headless, against a Jellyfin-shaped stub holding a few hundred films so a
 * channel is playing and the overlay is drawn.
 *
 * What it checks, with retro mode on (it is on for a browser that never chose), a channel up, and long
 * enough after switching it on for the old line's first sweep to have started (it began 2 to 8 s in):
 *   - nothing in the page is named for the line: no .vhs-tracking element, nothing with "vhs" in its class,
 *     no stylesheet rule or @keyframes for it, no inline animation that names it, no running animation of it;
 *   - nothing else draws it either: no full-width element 3 px tall or less that is painted (a thin
 *     bright line crossing the picture, by any name);
 *   - the rest of Retro mode is still there: scanlines and vignette on the overlay, the flicker on the
 *     video container, the 4:3 picture;
 *   - Settings > GENERAL > Display > Retro mode reads "CRT scanlines, vignette, flicker, 4:3 aspect ratio.
 *     Shortcut: B" (the Apple TV's wording), with no "VHS" and no "glitch" in it;
 *   - switching Retro mode off and on again (the B key, the Settings button) throws nothing: the old code
 *     called start/stop functions for the line from both, so a leftover call would be a ReferenceError.
 * Three ways in: a new install (retro on by default) at 1440x900 and at 390x844, and a browser that had it off,
 * switched on at 960x540.
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (origin/main's, with the line); the
 * "no line" checks must fail there.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable
 * `playwright`. Run: `npm run test:retro:browser`. Headless only.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

// ── A stub library: 300 films across years, genres and ratings ──────────────────
const GENRES = ["Action", "Comedy", "Drama", "Thriller", "Horror", "Romance", "Science Fiction", "Adventure", "Animation", "Family", "Crime", "Mystery", "War", "Western", "Documentary", "Fantasy"];
const CERTS = ["G", "PG", "PG-13", "R", "PG", "PG-13"];
const films = Array.from({ length: 300 }, (_, i) => {
  const ticks = (85 + (i % 40)) * 60 * 10000000;
  return {
    Id: `film${i}`, Name: `Film ${i}`, Type: "Movie", ProductionYear: 1960 + (i % 62), Genres: [GENRES[i % GENRES.length], GENRES[(i * 7 + 3) % GENRES.length]],
    OfficialRating: CERTS[i % CERTS.length], CommunityRating: 5 + (i % 40) / 10, RunTimeTicks: ticks, ProviderIds: { Tmdb: String(1000 + i) }, Studios: [],
    DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "A film.",
    MediaSources: [{ Id: `ms${i}`, Container: "mp4", Bitrate: 4000000, RunTimeTicks: ticks, Size: 2000000, SupportsDirectPlay: true,
      MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }, { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true }] }],
  };
});
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  const url = req.url;
  if (url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.11.11", ProductName: "Jellyfin Server", Id: "lab" }));
  if (url.startsWith("/UserViews")) return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.includes("IncludeItemTypes=Movie")) {
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
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1" && typeof currentChannel !== "undefined" && currentChannel !== null, null, { timeout: 45000 }).catch(() => {});
  await page.waitForTimeout(800);
  return { ctx, page, errors };
}

// Everything the old line was, by name or by looks, in the live page.
const lineReport = (page) => page.evaluate(() => {
  const named = [...document.querySelectorAll("*")].filter((el) => /vhs|tracking/i.test(typeof el.className === "string" ? el.className : "") || /vhs|tracking/i.test(el.id || "")).map((el) => el.tagName + "." + el.className);
  const inline = [...document.querySelectorAll("[style]")].filter((el) => /vhs|tracking/i.test(el.getAttribute("style"))).map((el) => el.tagName + "." + el.className);
  const rules = [];
  for (const sheet of document.styleSheets) {
    let list; try { list = sheet.cssRules; } catch (e) { continue; }
    const walk = (rs) => { for (const r of rs) {
      if (r.cssRules && !r.name) walk(r.cssRules);
      if (r.name && /vhs|tracking/i.test(r.name)) rules.push("@keyframes " + r.name);
      if (r.selectorText && /vhs|tracking/i.test(r.selectorText)) rules.push(r.selectorText);
    } };
    walk(list);
  }
  const running = document.getAnimations().map((a) => a.animationName || a.id || "").filter((n) => /vhs|tracking/i.test(n));
  // A thin full-width painted bar by any name (the progress bar is drawn narrower than the screen and is not position absolute).
  const thin = [...document.body.querySelectorAll("*")].filter((el) => {
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || (cs.position !== "absolute" && cs.position !== "fixed")) return false;
    const r = el.getBoundingClientRect();
    if (r.width < innerWidth * 0.9 || r.height < 0.5 || r.height > 3.5) return false;
    const bg = cs.backgroundColor.match(/rgba?\(([^)]+)\)/);
    const alpha = bg ? (bg[1].split(",").length === 4 ? Number(bg[1].split(",")[3]) : 1) : 0;
    return alpha > 0 || cs.boxShadow !== "none";
  }).map((el) => el.tagName + "#" + el.id + "." + el.className);
  return { retro: document.body.classList.contains("retro-mode"), tagged: document.querySelectorAll(".vhs-tracking").length, named, inline, rules, running, thin };
});

// What is left of the look, with a channel playing.
const lookReport = (page) => page.evaluate(() => {
  const overlay = document.getElementById("retro-overlay");
  const oc = overlay ? getComputedStyle(overlay) : null;
  const vc = document.querySelector(".video-container");
  const video = document.getElementById("plex-video");
  return {
    playing: document.querySelector(".player-screen")?.classList.contains("has-channel") === true,
    overlayShown: !!oc && oc.display === "block",
    scanlines: !!oc && /repeating-linear-gradient/.test(oc.backgroundImage),
    vignette: !!oc && /radial-gradient/.test(oc.backgroundImage),
    scanlineMotion: !!oc && /scanlines/.test(oc.animationName),
    flicker: !!vc && /retro-flicker/.test(getComputedStyle(vc).animationName),
    aspect43: !!video && /4\s*\/\s*3/.test(getComputedStyle(video).aspectRatio),
  };
});

const retroRow = (page) => page.evaluate(() => {
  showConfig();
  switchConfigTab("general");
  const title = [...document.querySelectorAll("#config-tab-general div")].find((d) => d.textContent.trim() === "Retro mode");
  const line = title && title.nextElementSibling ? title.nextElementSibling.textContent.trim() : null;
  hideConfig();
  return line;
});

const WANT = "CRT scanlines, vignette, flicker, 4:3 aspect ratio. Shortcut: B";
const WAIT_FOR_OLD_SWEEP = 9500;   // the old line's first sweep began 2 to 8 s after retro mode went on

async function verify(name, t, { checkRow = true } = {}) {
  await t.page.waitForTimeout(WAIT_FOR_OLD_SWEEP);
  const r = await lineReport(t.page);
  check(`${name}: retro mode is on`, r.retro === true, JSON.stringify(r));
  check(`${name}: no .vhs-tracking element`, r.tagged === 0, String(r.tagged));
  check(`${name}: nothing in the page is named for the line`, r.named.length === 0 && r.inline.length === 0, JSON.stringify({ named: r.named, inline: r.inline }));
  check(`${name}: no stylesheet rule or @keyframes for it`, r.rules.length === 0, JSON.stringify(r.rules));
  check(`${name}: no animation of it is running`, r.running.length === 0, JSON.stringify(r.running));
  check(`${name}: no thin full-width bright line is drawn by any name`, r.thin.length === 0, JSON.stringify(r.thin));
  const look = await lookReport(t.page);
  check(`${name}: a channel is playing, so the overlay can be seen`, look.playing, JSON.stringify(look));
  check(`${name}: scanlines are still drawn`, look.overlayShown && look.scanlines && look.scanlineMotion, JSON.stringify(look));
  check(`${name}: the vignette is still drawn`, look.overlayShown && look.vignette, JSON.stringify(look));
  check(`${name}: the flicker is still on the video`, look.flicker, JSON.stringify(look));
  check(`${name}: the picture is still 4:3`, look.aspect43, JSON.stringify(look));
  if (checkRow) {
    const line = await retroRow(t.page);
    check(`${name}: the Settings line is the Apple TV's wording`, line === WANT, JSON.stringify(line));
    check(`${name}: and says nothing of VHS or glitch`, line !== null && !/vhs|glitch/i.test(line), JSON.stringify(line));
  }
}

// 1. A new install at desktop size: retro mode is on by default. Then off and on again, by the key and by the button.
{
  const t = await openPage(1440, 900);
  await verify("1440x900 new install", t);
  await t.page.keyboard.press("b");
  await t.page.waitForTimeout(300);
  const off = await lineReport(t.page);
  check("1440x900: the B key switches retro mode off and nothing throws", off.retro === false && t.errors.length === 0, JSON.stringify({ retro: off.retro, errors: t.errors }));
  check("1440x900: off, nothing of the line is left", off.tagged === 0 && off.named.length === 0 && off.thin.length === 0, JSON.stringify(off));
  await t.page.evaluate(() => { showConfig(); switchConfigTab("general"); });
  await t.page.click("#cfg-retro-toggle", { timeout: 4000 }).catch(() => {});
  await t.page.waitForTimeout(300);
  const on = await lineReport(t.page);
  check("1440x900: the Settings button switches it on again and nothing throws", on.retro === true && t.errors.length === 0, JSON.stringify({ retro: on.retro, errors: t.errors }));
  await t.page.evaluate(() => { hideConfig(); });
  await t.page.waitForTimeout(WAIT_FOR_OLD_SWEEP);
  const again = await lineReport(t.page);
  check("1440x900: switched back on, still no line after the old sweep time", again.tagged === 0 && again.named.length === 0 && again.running.length === 0 && again.thin.length === 0, JSON.stringify(again));
  check("1440x900: no page errors in the whole run", t.errors.length === 0, t.errors.join(" | "));
  await t.ctx.close();
}

// 2. A browser that had it off, switched on at TV size.
{
  const t = await openPage(960, 540, { plex90_retro_mode: "false" });
  const before = await lineReport(t.page);
  check("960x540: stored off, retro mode is off at load", before.retro === false && before.tagged === 0, JSON.stringify(before));
  await t.page.keyboard.press("b");
  await t.page.waitForTimeout(300);
  await verify("960x540 switched on", t, { checkRow: true });
  check("960x540: no page errors", t.errors.length === 0, t.errors.join(" | "));
  await t.ctx.close();
}

// 3. A phone.
{
  const t = await openPage(390, 844);
  await verify("390x844 new install", t, { checkRow: false });
  check("390x844: no page errors", t.errors.length === 0, t.errors.join(" | "));
  await t.ctx.close();
}

await browser.close();
jellyfin.close();
files.close();
if (failures.length) {
  console.error(`retro-mode smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`retro-mode smoke: ${passed} checks passed (no tracking line by name or by looks, scanlines, vignette, flicker and 4:3 kept, Settings line in the Apple TV's words, off and on again throws nothing; 1440x900, 960x540, 390x844)`);
