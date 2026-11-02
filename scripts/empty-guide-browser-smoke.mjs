#!/usr/bin/env node
/**
 * A library where no package has any content shows NO CHANNELS FOUND, the Apple TV and Roku
 * line, and an OPEN SETTINGS button (issue #129). Before this the web tuner and Docker left a
 * black screen with nothing to press.
 *
 * Loads the real plex-tuner.html, headless, against a Jellyfin-shaped server holding one film
 * nothing matches (the #124 fallback finds no package with content). Checks both ways the page
 * gets its library: a fresh fetch, and a reload that restores the saved cache. On each: the
 * heading, the line, a focusable button that opens Settings by click (a TV browser has no keys),
 * and nothing in browser full screen. The fresh load also runs at phone, tablet, desktop and
 * 960x540 and checks the block sits inside the screen. Set SHOTS=/dir to save the 960x540 and
 * phone screenshots.
 * Negative control: the same page with the empty-state branch taken out (the old "tune the first
 * enabled channel, if there is one"), which must show no message on either path. NX_TUNER_HTML=/path
 * serves another copy of the page (for example origin/main's) in place of plex-tuner.html.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:empty-guide`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));
const shots = process.env.SHOTS || "";
if (shots) mkdirSync(shots, { recursive: true });

const HEADING = "NO CHANNELS FOUND";
const LINE = "Your library didn't have enough content to fill any channels. Open Settings to see which packages your library supports.";

const odd = {
  Id: "odd1", Name: "Odd One", Type: "Movie", ProductionYear: 2023, Genres: ["Western"], OfficialRating: null,
  RunTimeTicks: 900000000, ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z",
  MediaSources: [{ Id: "odd1", Container: "mp4", RunTimeTicks: 900000000, Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 640, Height: 360, Index: 0, IsDefault: true }] }],
};
let libraryFetches = 0;
const jellyfin = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  const url = req.url;
  if (url.startsWith("/System/Info/Public")) return res.end(JSON.stringify({ ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" }));
  if (url.startsWith("/UserViews")) return res.end(JSON.stringify({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 }));
  if (url.includes("IncludeItemTypes=Movie")) { libraryFetches += 1; return res.end(JSON.stringify({ Items: [odd], TotalRecordCount: 1 })); }
  res.end(JSON.stringify({ Items: [], TotalRecordCount: 0 }));
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    if (process.env.NX_TUNER_HTML) body = readFileSync(process.env.NX_TUNER_HTML);
    let text = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
    // ?nofix: the old ending, tune the first enabled channel if there is one, for the negative control.
    if (req.url.includes("nofix")) {
      const marker = "function tuneFirstOrShowEmpty() {";
      if (!text.includes(marker)) { res.writeHead(500); return res.end("helper not found"); }
      text = text.replace(marker, `${marker}\n    { const f = CHANNELS.find(ch => ch.enabled); if (f) switchChannel(f.id); return; }`);
    }
    body = text;
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
const viewports = { desktop: [1440, 900], tablet: [820, 1180], phone: [390, 844], tv960: [960, 540] };

const read = (page) => page.evaluate(() => {
  const box = (id) => { const el = document.getElementById(id); if (!el) return { shown: false, r: { l: 0, t: 0, rt: 0, b: 0 } }; const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); const shown = cs.display !== "none" && cs.visibility !== "hidden" && r.width > 0 && r.height > 0; return { shown, r: { l: r.left, t: r.top, rt: r.right, b: r.bottom } }; };
  return {
    heading: document.querySelector(".plex-empty-title")?.textContent || "",
    line: (document.querySelector(".plex-empty-text")?.innerText || "").replace(/\s+/g, " ").trim(),
    block: box("plex-empty"), btn: box("plex-empty-settings-btn"),
    btnText: document.getElementById("plex-empty-settings-btn")?.textContent || "",
    fullscreen: !!document.fullscreenElement,
    vw: innerWidth, vh: innerHeight,
  };
});

async function open(name, query, { reloadFrom } = {}) {
  const [w, h] = viewports[name];
  const ctx = reloadFrom ? reloadFrom.ctx : await browser.newContext({ viewport: { width: w, height: h } });
  if (!reloadFrom) {
    await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
    await ctx.addInitScript(([url]) => {
      if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
        sessionStorage.setItem("nx-seeded", "1");
        localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
      }
    }, [api]);
  }
  const page = reloadFrom ? reloadFrom.page : await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  if (reloadFrom) await page.reload(); else await page.goto(`${base}/plex-tuner.html${query}`);
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(1500);
  return { ctx, page, errors };
}

for (const query of ["", "?nofix"]) {
  const control = query === "?nofix";
  const tag = control ? "negative control (old ending)" : "fixed";
  for (const name of control ? ["desktop"] : Object.keys(viewports)) {
    const first = await open(name, query);
    const s = await read(first.page);
    if (control) {
      check(`${tag}, fresh fetch: no message`, !s.block.shown && !s.btn.shown, JSON.stringify(s.block));
    } else {
      check(`${name}, fresh fetch: heading`, s.heading === HEADING && s.block.shown, s.heading);
      check(`${name}, fresh fetch: the line matches the Apple TV`, s.line === LINE, s.line);
      check(`${name}, fresh fetch: OPEN SETTINGS button shown`, s.btn.shown && s.btnText === "OPEN SETTINGS", s.btnText);
      const inside = s.block.r.l >= 0 && s.block.r.rt <= s.vw + 0.5 && s.block.r.t >= 0 && s.block.r.b <= s.vh + 0.5;
      check(`${name}, fresh fetch: the block fits the ${s.vw}x${s.vh} screen`, inside, JSON.stringify(s.block.r));
      check(`${name}, fresh fetch: not in browser full screen`, s.fullscreen === false);
      check(`${name}, fresh fetch: no page errors`, first.errors.length === 0, first.errors.join(" | "));
      if (shots && (name === "tv960" || name === "phone")) await first.page.screenshot({ path: join(shots, `empty-guide-${name}.png`) });
    }
    if (name === "desktop") {
      // The cache-restore path: the same browser, reloaded, reads the saved library without asking the server.
      const before = libraryFetches;
      const again = await open(name, query, { reloadFrom: first });
      const c = await read(again.page);
      const restored = libraryFetches === before;
      if (control) {
        check(`${tag}, cache restore: no message`, !c.block.shown && !c.btn.shown, JSON.stringify(c.block));
      } else {
        check("desktop, cache restore: the library came from the saved cache, not the server", restored, `fetches ${before} -> ${libraryFetches}`);
        check("desktop, cache restore: heading", c.heading === HEADING && c.block.shown, c.heading);
        check("desktop, cache restore: the line matches the Apple TV", c.line === LINE, c.line);
        check("desktop, cache restore: OPEN SETTINGS button shown", c.btn.shown && c.btnText === "OPEN SETTINGS", c.btnText);
        // A real button: focusable, and a click (no key) opens Settings.
        const focusable = await again.page.evaluate(() => { const b = document.getElementById("plex-empty-settings-btn"); if (!b) return false; b.focus(); return document.activeElement === b && b.tagName === "BUTTON"; });
        check("desktop, cache restore: the button is a focusable button", focusable);
        await again.page.click("#plex-empty-settings-btn", { timeout: 2000 }).catch(() => {});
        await again.page.waitForTimeout(300);
        const opened = await again.page.evaluate(() => document.getElementById("config-overlay").classList.contains("open") && appState === "config");
        check("desktop, cache restore: a click on OPEN SETTINGS opens Settings", opened);
        check("desktop, cache restore: no page errors", again.errors.length === 0, again.errors.join(" | "));
      }
    }
    if (!control && name === "tv960") {
      // Same click on the fresh-fetch path, at the TV size.
      await first.page.click("#plex-empty-settings-btn", { timeout: 2000 }).catch(() => {});
      await first.page.waitForTimeout(300);
      check("tv960, fresh fetch: a click on OPEN SETTINGS opens Settings", await first.page.evaluate(() => document.getElementById("config-overlay").classList.contains("open")));
    }
    await first.ctx.close();
  }
}

await browser.close();
jellyfin.close();
files.close();
if (failures.length) {
  console.error(`empty-guide smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`empty-guide smoke: ${passed} checks passed (fresh fetch at 4 sizes, cache restore, and the negative control)`);
