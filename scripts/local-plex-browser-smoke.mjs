#!/usr/bin/env node
/**
 * LOCAL SERVER (NO PLEX.TV) on the self-hosted tuner (I-057), headless, against a stub Plex server.
 *
 * A Plex server can let a home network in without a sign-in (Plex, Settings, Network, "List of IP addresses and networks
 * that are allowed without auth"). The Docker tuner runs on http and can reach it; the hosted https page cannot, so it has
 * no such button. The Apple TV's counterpart is appletv/i057-local-plex.
 *
 * 1. The button: on the Plex code screen beside CANCEL in the self-host build (dist-selfhost/), absent from the hosted
 *    build (dist/).
 * 2. The address: what is typed gets :32400 when it has no port (a unit check of NostalgexSignIn.localPlexAddress).
 * 3. A server that lets the network in: LOCAL SERVER, type the address, CONNECT. The tuner opens on that server, reads its
 *    libraries and shows the guide. The stub saw /identity and the libraries, and not one request carried an X-Plex-Token
 *    (no header, no address parameter). plex.tv was not asked once the button was pressed. The sign-in is saved with the
 *    "no plex.tv" flag, a reload keeps it, and signing out clears the flag and the saved sign-in.
 * 4. A server that wants a sign-in (401 on its libraries): the address screen names Plex's setting, and nothing is saved.
 *    A saved local sign-in that meets a 401 later keeps the sign-in and says the same on the tuner page.
 * 5. An address that answers but is not Plex, and one nothing answers at: each its own line.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a resolvable `playwright`.
 * Needs both builds: `npm run build && npm run build:selfhost`. Run: `npm run test:local-plex:browser`. Headless only.
 * SHOTS=/dir saves a screenshot of the code screen and the address screen.
 */
import http from "node:http";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const repo = fileURLToPath(new URL("../", import.meta.url));
const SELFHOST = resolve(repo, "dist-selfhost");
const HOSTED = resolve(repo, "dist");
for (const d of [SELFHOST, HOSTED]) if (!existsSync(d)) { console.error(`local-plex smoke: ${d} is missing. Run npm run build && npm run build:selfhost.`); process.exit(2); }
if (process.env.SHOTS) mkdirSync(process.env.SHOTS, { recursive: true });

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

// ── The stub Plex server ──
const movie = (n) => ({
  ratingKey: String(100 + n), title: `Film ${n}`, summary: "", year: 1985 + n, duration: 5400000, type: "movie",
  addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Action" }],
  Media: [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${n}/file.mp4` }] }],
});
const metadata = Array.from({ length: 8 }, (_, i) => movie(i + 1));

/** mode: "open" (lets the network in), "auth" (401 on the libraries), "notplex" (answers, but not as Plex). */
async function stubPlex(mode) {
  const log = [];
  const server = http.createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Headers", "*");
    if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
    const u = new URL(req.url, "http://stub");
    log.push({ path: u.pathname, query: u.search, token: req.headers["x-plex-token"], tokenInQuery: u.searchParams.has("X-Plex-Token") });
    if (mode === "notplex") { res.writeHead(200, { "Content-Type": "text/html" }); return res.end("<html>a web page</html>"); }
    res.setHeader("Content-Type", "application/json");
    if (u.pathname === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "stub-plex-id", version: "1.43.4" } }));
    if (mode === "auth" && u.pathname.startsWith("/library")) { res.writeHead(401); return res.end(JSON.stringify({ errors: [{ code: 1001, message: "User could not be authenticated" }] })); }
    if (u.pathname === "/") return res.end(JSON.stringify({ MediaContainer: { friendlyName: "Stub Plex" } }));
    if (u.pathname === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }] } }));
    if (u.pathname === "/library/sections/1/all") return res.end(JSON.stringify({ MediaContainer: { size: metadata.length, totalSize: metadata.length, Metadata: metadata } }));
    res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { port: server.address().port, log, close: () => new Promise((r) => server.close(r)) };
}
async function deadPort() {
  const s = net.createServer();
  await new Promise((r) => s.listen(0, "127.0.0.1", r));
  const port = s.address().port;
  await new Promise((r) => s.close(r));
  return port;
}

// ── The two builds, served over http ──
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
async function serve(root) {
  const server = http.createServer((req, res) => {
    let p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
    if (!extname(p) && existsSync(p + ".html")) p += ".html";
    if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
    let body = readFileSync(p);
    if (p.endsWith("plex-tuner.html")) body = Buffer.from(body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>"));
    res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
    res.end(body);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { base: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}
const selfhost = await serve(SELFHOST);
const hosted = await serve(HOSTED);
const browser = await chromium.launch({ headless: true });

/** A page whose requests to anything but the local servers are stubbed, counting what goes to plex.tv. */
async function openPage(viewport = { width: 1440, height: 900 }) {
  const ctx = await browser.newContext({ viewport });
  const plexTv = [];
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => {
    const url = route.request().url();
    if (/plex\.tv/.test(url)) {
      plexTv.push({ at: Date.now(), method: route.request().method(), url });
      // The code screen's own request for a code (before the viewer chooses LOCAL SERVER) and its polling get an answer.
      if (/\/pins$/.test(url)) return route.fulfill({ status: 201, contentType: "application/json", headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*" }, body: JSON.stringify({ id: 4242, code: "ABCD" }) });
      if (/\/pins\/4242/.test(url)) return route.fulfill({ status: 200, contentType: "application/json", headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*" }, body: JSON.stringify({ id: 4242, code: "ABCD", authToken: null }) });
    }
    return route.abort();
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  return { ctx, page, plexTv, errors };
}
const visible = (page, sel) => page.locator(sel).first().isVisible().catch(() => false);
const shot = async (page, name) => { if (process.env.SHOTS) await page.screenshot({ path: join(process.env.SHOTS, name) }); };
const SETTING = /list of ip addresses and networks that are allowed without auth/i;

// ── 1. The button: self-host only, beside CANCEL ──
{
  const { ctx, page, errors } = await openPage();
  await page.goto(`${selfhost.base}/web-tuner.html`);
  await page.locator("#connect-btn").click();
  await page.locator("#plex-cancel").waitFor({ timeout: 10000 });
  check("self-host: LOCAL SERVER (NO PLEX.TV) is on the Plex code screen", await visible(page, "#plex-local-btn"));
  check("self-host: the button reads LOCAL SERVER (NO PLEX.TV)", (await page.locator("#plex-local-btn").textContent()).trim() === "LOCAL SERVER (NO PLEX.TV)");
  const a = await page.locator("#plex-cancel").boundingBox();
  const b = await page.locator("#plex-local-btn").boundingBox();
  check("self-host: the button sits beside CANCEL (same row, to its right)", a && b && Math.abs(a.y - b.y) < 6 && b.x > a.x, JSON.stringify({ a, b }));
  await shot(page, "local-plex-code-screen.png");
  check("self-host: no page error", errors.length === 0, errors.join(" | "));
  await ctx.close();
}
{
  const { ctx, page } = await openPage();
  await page.goto(`${hosted.base}/web-tuner.html`);
  await page.locator("#connect-btn").click();
  await page.locator("#plex-cancel").waitFor({ timeout: 10000 });
  check("hosted: there is no LOCAL SERVER button", (await page.locator("#plex-local-btn").count()) === 0);
  await ctx.close();
}

// ── 1b. No internet: plex.tv cannot be reached, and the code screen stays so the button is still there ──
{
  const ctx = await browser.newContext({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  const page = await ctx.newPage();
  await page.goto(`${selfhost.base}/web-tuner.html`);
  await page.locator("#connect-btn").click();
  await page.waitForFunction(() => /plex\.tv/i.test(document.getElementById("plex-status").textContent) && !/CONNECTING TO/i.test(document.getElementById("plex-status").textContent), null, { timeout: 10000 }).catch(() => {});
  check("self-host, plex.tv unreachable: the code screen stays, with the reason", await visible(page, "#plex-cancel") && /could not reach plex\.tv|no internet/i.test(await page.locator("#plex-status").textContent()), await page.locator("#plex-status").textContent());
  check("self-host, plex.tv unreachable: LOCAL SERVER (NO PLEX.TV) is still there to press", await visible(page, "#plex-local-btn"));
  const box = await page.locator("#plex-local-btn").boundingBox();
  check("at 960x540 the button fits on screen", box && box.x >= 0 && box.x + box.width <= 960 && box.y + box.height <= 540, JSON.stringify(box));
  await shot(page, "local-plex-code-screen-tv.png");
  await ctx.close();
}
{
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  const page = await ctx.newPage();
  await page.goto(`${hosted.base}/web-tuner.html`);
  await page.locator("#connect-btn").click();
  await page.locator("#picker-error:not([hidden])").waitFor({ timeout: 10000 });
  check("hosted, plex.tv unreachable: back to the first screen with the reason, as before", await visible(page, "#connect-btn") && /plex\.tv/i.test(await page.locator("#picker-error").textContent()));
  await ctx.close();
}

// ── 2. The address gets :32400 ──
{
  const { ctx, page } = await openPage();
  await page.goto(`${selfhost.base}/web-tuner.html`);
  const got = await page.evaluate(() => ["192.168.1.10", " nas.local ", "http://nas:8080/", "https://plex.example.com", "10.0.0.5:32401", "", "  "].map(window.NostalgexSignIn.localPlexAddress));
  const want = ["http://192.168.1.10:32400", "http://nas.local:32400", "http://nas:8080", "https://plex.example.com:32400", "http://10.0.0.5:32401", "", ""];
  check("an address with no port gets :32400, a typed port is kept, http is the default", JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  await ctx.close();
}

// ── 3. A server that lets the network in ──
{
  const stub = await stubPlex("open");
  const { ctx, page, plexTv, errors } = await openPage();
  await page.goto(`${selfhost.base}/web-tuner.html`);
  await page.locator("#connect-btn").click();
  await page.locator("#plex-local-btn").waitFor({ timeout: 10000 });
  const beforeLocal = plexTv.length;
  await page.locator("#plex-local-btn").click();
  await page.locator("#address-input").waitFor({ state: "visible", timeout: 10000 });
  check("LOCAL SERVER opens the address screen, titled for Plex without plex.tv", /WITHOUT PLEX\.TV/i.test(await page.locator("#address-title").textContent()));
  await shot(page, "local-plex-address-screen.png");
  await page.locator("#address-input").fill(`127.0.0.1:${stub.port}`);
  await page.locator("#address-connect").click();
  await page.waitForURL(/plex-tuner\.html/, { timeout: 20000 });
  await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length > 0, null, { timeout: 40000 }).catch(() => {});
  // A first sign-in can stop at CHOOSE YOUR LIBRARIES; one press of CONTINUE starts the scan.
  await page.locator(".library-continue").click({ timeout: 3000 }).catch(() => {});
  let loaded = false;
  try { await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length > 0, null, { timeout: 40000 }); loaded = true; } catch { /* reported below */ }
  check("the tuner reads the library from the local server", loaded);
  check("the guide shows (the connect screen is gone)", !(await visible(page, "#plex-connect")));
  const paths = stub.log.map((l) => l.path);
  check("the stub was asked /identity and the libraries", paths.includes("/identity") && paths.includes("/library/sections") && paths.includes("/library/sections/1/all"), paths.join(" "));
  check("no request to the server carried an X-Plex-Token header", stub.log.every((l) => l.token === undefined), JSON.stringify(stub.log.filter((l) => l.token !== undefined)));
  check("no request to the server carried an X-Plex-Token in its address", stub.log.every((l) => !l.tokenInQuery), JSON.stringify(stub.log.filter((l) => l.tokenInQuery)));
  check("plex.tv was not asked after LOCAL SERVER was pressed", plexTv.length === beforeLocal, JSON.stringify(plexTv.slice(beforeLocal)));
  const saved = await page.evaluate(() => JSON.parse(localStorage.getItem("plex90_saved_auth") || "null"));
  check("the sign-in is saved with the no-plex.tv flag and no token", saved && saved.localNoAuth === true && !saved.token && saved.serverUrl === `http://127.0.0.1:${stub.port}` && saved.serverName === "Stub Plex", JSON.stringify(saved));
  check("the session carries the flag and an empty token", await page.evaluate(() => sessionStorage.getItem("plex90_plex_local") === "1" && sessionStorage.getItem("plex90_token") === ""));

  // A reload keeps it, and still asks plex.tv nothing.
  const asked = stub.log.length;
  await page.reload();
  await page.locator(".library-continue").click({ timeout: 4000 }).catch(() => {});
  let again = false;
  try { await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length > 0, null, { timeout: 40000 }); again = true; } catch { /* reported below */ }
  check("a reload keeps the sign-in and reads the library again", again && !(await visible(page, "#plex-connect")));
  check("a reload sent no token either", stub.log.slice(asked).every((l) => l.token === undefined && !l.tokenInQuery));
  check("plex.tv was never asked on the way", plexTv.length === beforeLocal, JSON.stringify(plexTv.slice(beforeLocal)));

  // Signing out clears the flag and the saved sign-in.
  await page.evaluate(() => document.getElementById("cfg-plex-btn").click());
  await page.waitForTimeout(500);
  const after = await page.evaluate(() => ({ saved: localStorage.getItem("plex90_saved_auth"), flag: sessionStorage.getItem("plex90_plex_local"), token: sessionStorage.getItem("plex90_token") }));
  check("sign out clears the flag and the saved sign-in", after.saved === null && after.flag === null && after.token === null, JSON.stringify(after));
  check("no page error on the tuner page", errors.length === 0, errors.join(" | "));
  await ctx.close();
  await stub.close();
}

// ── 4. A server that wants a sign-in ──
{
  const stub = await stubPlex("auth");
  const { ctx, page, plexTv } = await openPage();
  await page.goto(`${selfhost.base}/web-tuner.html`);
  await page.locator("#connect-btn").click();
  await page.locator("#plex-local-btn").click();
  await page.locator("#address-input").fill(`127.0.0.1:${stub.port}`);
  await page.locator("#address-connect").click();
  await page.locator("#address-warn:not([hidden])").waitFor({ timeout: 15000 });
  const warn = await page.locator("#address-warn").textContent();
  check("a 401 names Plex's allowed-without-auth setting", SETTING.test(warn), warn);
  check("a 401 leaves nothing saved", await page.evaluate(() => localStorage.getItem("plex90_saved_auth") === null && sessionStorage.getItem("plex90_plex_local") === null));
  check("a 401 sent no token", stub.log.every((l) => l.token === undefined && !l.tokenInQuery));
  check("the address screen stays on the address, ready for another try", await visible(page, "#address-input") && (await page.locator("#address-input").inputValue()).includes(String(stub.port)));
  await ctx.close();

  // A saved local sign-in that meets the 401 later: kept, and the tuner page names the setting.
  const second = await openPage();
  await second.page.addInitScript((url) => {
    if (!localStorage.getItem("seeded")) {
      localStorage.setItem("seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ backend: "plex", token: "", localNoAuth: true, serverUrl: url, serverName: "Stub Plex" }));
    }
  }, `http://127.0.0.1:${stub.port}`);
  await second.page.goto(`${selfhost.base}/plex-tuner.html`);
  await second.page.waitForFunction(() => /allowed without auth/i.test((document.getElementById("plex-error-label") || {}).textContent || ""), null, { timeout: 20000 }).catch(() => {});
  const line = await second.page.evaluate(() => (document.getElementById("plex-error-label") || {}).textContent || "");
  check("a saved local sign-in that meets a 401 names the setting on the tuner page", SETTING.test(line), line);
  check("it keeps the saved sign-in", await second.page.evaluate(() => !!localStorage.getItem("plex90_saved_auth")));
  check("it never asked plex.tv", second.plexTv.length === 0, JSON.stringify(second.plexTv));
  await second.ctx.close();
  await stub.close();
}

// ── 5. An address that is not Plex, and one nothing answers at ──
{
  const stub = await stubPlex("notplex");
  const { ctx, page } = await openPage();
  await page.goto(`${selfhost.base}/web-tuner.html`);
  await page.locator("#connect-btn").click();
  await page.locator("#plex-local-btn").click();
  await page.locator("#address-input").fill(`127.0.0.1:${stub.port}`);
  await page.locator("#address-connect").click();
  await page.locator("#address-warn:not([hidden])").waitFor({ timeout: 15000 });
  check("an address that is not Plex says so", /isn't a Plex server/i.test(await page.locator("#address-warn").textContent()));
  await stub.close();
  await page.locator("#address-input").fill(`127.0.0.1:${await deadPort()}`);
  await page.locator("#address-connect").click();
  await page.waitForFunction(() => /nothing answered/i.test((document.getElementById("address-warn") || {}).textContent || ""), null, { timeout: 15000 }).catch(() => {});
  check("an address nothing answers at says so", /nothing answered/i.test(await page.locator("#address-warn").textContent()));
  // BACK goes to the first screen, and the Jellyfin address screen does not inherit the Plex address.
  await page.locator("#address-back").click();
  check("BACK from the address screen returns to the first screen", await visible(page, "#connect-btn"));
  await page.locator("#connect-jellyfin-btn").click();
  await page.locator("#find-type-btn").click().catch(() => {});
  await page.locator("#address-input").waitFor({ state: "visible", timeout: 5000 });
  check("the Jellyfin address screen starts empty after a Plex one", (await page.locator("#address-input").inputValue()) === "");
  await ctx.close();
}

await browser.close();
selfhost.close();
hosted.close();
if (failures.length) {
  console.error(`local-plex browser smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`local-plex browser smoke: ${passed} checks passed`);
