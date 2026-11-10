#!/usr/bin/env node
/**
 * I-024, the saved login on the web tuner and Docker, on the real pages, headless.
 *
 * What it proves, against a Jellyfin-shaped server:
 *   1. Signing in on web-tuner.html saves the login in this browser: the access token, the server
 *      address and the user id in localStorage under plex90_saved_auth, and nothing else holds the
 *      token. The password is stored nowhere (not in storage, not in cookies, not in IndexedDB).
 *   2. A browser restart (localStorage and IndexedDB kept, sessionStorage gone) lands straight in
 *      the guide: web-tuner.html forwards, the connect screen never shows, the viewer is signed in.
 *   3. SIGN OUT leaves no copy of the token in localStorage, sessionStorage, IndexedDB or cookies,
 *      and the library cache is emptied.
 *   4. A login the server refuses is forgotten. The scan's first request (the library list) answers
 *      401: the screen says SESSION ENDED, the saved login is gone, and RECONNECT lands on the
 *      sign-in page instead of being forwarded straight back into the refusal. Jellyfin and Emby,
 *      at 960x540 and on a phone. Plex: plex.tv refusing the token does the same.
 *
 * Negative control: the page with the 401 handling taken out (?old) leaves the dead login saved and
 * RECONNECT bounces back to the tuner, which is how the web tuner behaved before.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:saved-login`.
 */
import http from "node:http";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));

const TOKEN = "JFTOKEN-SECRET-9f3a";
const PASSWORD = "pw-hunter2-zzz";
const movie = (i) => ({
  Id: `m${i}`, Name: `Movie ${i}`, Type: "Movie", ProductionYear: 1990 + i, Genres: ["Action"], OfficialRating: "PG-13",
  RunTimeTicks: 54000000000, ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", ImageTags: { Primary: "abc" },
  MediaSources: [{ Id: `m${i}`, Container: "mp4", RunTimeTicks: 54000000000, Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }] }],
});
const items = Array.from({ length: 30 }, (_, i) => movie(i));

let refuse = false; // when true the server refuses every authenticated request
let emby = false;   // when true /System/Info/Public answers the way Emby does (no ProductName)
const authBodies = [];
const media = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = req.url;
  const json = (body, status = 200) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(typeof body === "string" ? body : JSON.stringify(body)); };
  if (url.startsWith("/System/Info/Public")) {
    return json(emby ? { ServerName: "lab", Version: "4.10.1.0", Id: "lab", LocalAddresses: [] }
      : { ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" });
  }
  if (url.startsWith("/QuickConnect/Enabled")) return json("false");
  if (url.startsWith("/Users/Public")) return json("[]");
  if (url.startsWith("/Users/AuthenticateByName")) {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => { authBodies.push(body); json({ AccessToken: TOKEN, User: { Id: "uid1", Name: "bob", ServerName: "lab" } }); });
    return;
  }
  if (refuse) return json({}, 401);
  if (url.startsWith("/UserViews") || /^\/Users\/[^/]+\/Views/.test(url)) return json({ Items: [{ Id: "lib1", Name: "Movies", CollectionType: "movies" }], TotalRecordCount: 1 });
  if (url.includes("IncludeItemTypes=Movie")) return json({ Items: items, TotalRecordCount: items.length });
  json({ Items: [], TotalRecordCount: 0 });
});
const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
// What ?old takes out: the two lines that act on a refused login (see plex-tuner.html).
const OLD_STRIPS = [
  [/if \(viewsRes\.status === 401 \|\| viewsRes\.status === 403\) \{[\s\S]*?throw e;\s*\}/, "views check"],
  [/if \(failureKind === 'auth'\) forgetRejectedLogin\(\);/, "forget call"],
];
const files = http.createServer((req, res) => {
  // Extensionless paths resolve to .html, as on Vercel (cleanUrls) and in the Docker image (try_files).
  let p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!extname(p) && existsSync(p + ".html")) p += ".html";
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    let text = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
    if (req.headers.referer?.includes("old=1") || req.url.includes("old=1")) {
      for (const [re, name] of OLD_STRIPS) {
        if (!re.test(text)) { res.writeHead(500); return res.end(`negative control: ${name} not found`); }
        text = text.replace(re, "");
      }
    }
    body = text;
  }
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
const localOnly = (ctx) => ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());

/** Everything this origin holds that contains `needle`: storage areas, IndexedDB rows, cookies. */
const holders = (page, needles) => page.evaluate(async (needles) => {
  const found = {};
  const add = (needle, where) => { (found[needle] ||= []).push(where); };
  for (const [name, area] of [["localStorage", localStorage], ["sessionStorage", sessionStorage]]) {
    for (let i = 0; i < area.length; i++) {
      const k = area.key(i);
      const text = k + "=" + area.getItem(k);
      for (const n of needles) if (text.includes(n)) add(n, `${name}:${k}`);
    }
  }
  for (const n of needles) if (document.cookie.includes(n)) add(n, "cookie");
  let idbRows = 0;
  for (const d of (await indexedDB.databases?.()) || []) {
    await new Promise((resolve) => {
      const rq = indexedDB.open(d.name);
      rq.onerror = () => resolve();
      rq.onsuccess = async () => {
        const db = rq.result;
        for (const s of [...db.objectStoreNames]) {
          const rows = await new Promise((r2) => { const g = db.transaction(s).objectStore(s).getAll(); g.onsuccess = () => r2(g.result); g.onerror = () => r2([]); });
          idbRows += rows.length;
          const text = JSON.stringify(rows);
          for (const n of needles) if (text.includes(n)) add(n, `indexedDB:${d.name}/${s}`);
        }
        db.close();
        resolve();
      };
    });
  }
  return { found, idbRows };
}, needles);

// ---- 1 to 3: sign in, restart, sign out ----
{
  const ctx = await browser.newContext({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 });
  await localOnly(ctx);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/web-tuner.html`);
  await page.click("#connect-jellyfin-btn");
  await page.click("#find-type-btn");
  await page.fill("#address-input", api);
  await page.press("#address-input", "Enter");
  await page.waitForSelector("#signin-user", { state: "visible", timeout: 15000 });
  await page.fill("#signin-user", "bob");
  await page.fill("#signin-pass", PASSWORD);
  await page.click("#signin-btn");
  await page.waitForURL(/plex-tuner\.html/, { timeout: 15000 });
  await page.waitForFunction(() => localStorage.getItem("nostalgex_completed_initial_load") === "1", null, { timeout: 30000 });

  const saved = JSON.parse(await page.evaluate(() => localStorage.getItem("plex90_saved_auth")));
  check("1: the login is saved in localStorage", saved.token === TOKEN && saved.serverUrl === api && saved.jellyfinUserId === "uid1" && saved.backend === "jellyfin");
  check("1: the saved login holds only these fields", JSON.stringify(Object.keys(saved).sort()) === JSON.stringify(["backend", "jellyfinUserId", "jfUrl", "jfUser", "serverName", "serverUrl", "token"]), Object.keys(saved).join(","));
  const signedIn = await holders(page, [TOKEN, PASSWORD]);
  check("1: the token is held by the saved login and its working copy in sessionStorage, nowhere else",
    JSON.stringify(signedIn.found[TOKEN]?.sort()) === JSON.stringify(["localStorage:plex90_saved_auth", "sessionStorage:plex90_token"]), JSON.stringify(signedIn.found[TOKEN]));
  check("1: the password is stored nowhere", !signedIn.found[PASSWORD], JSON.stringify(signedIn.found[PASSWORD]));
  check("1: the password was sent to the server once, to sign in", authBodies.length === 1 && authBodies[0].includes(PASSWORD));
  check("1: the library cache holds the library", signedIn.idbRows > 0);

  // A browser restart keeps localStorage and IndexedDB and drops sessionStorage.
  const state = await ctx.storageState({ indexedDB: true });
  await ctx.close();
  const ctx2 = await browser.newContext({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2, storageState: state });
  await localOnly(ctx2);
  const p2 = await ctx2.newPage();
  const errors2 = [];
  p2.on("pageerror", (e) => errors2.push(String(e).slice(0, 160)));
  check("2: sessionStorage did not survive the restart", await (async () => { await p2.goto(`${base}/privacy.html`); return (await p2.evaluate(() => sessionStorage.length)) === 0; })());
  await p2.goto(`${base}/web-tuner.html`);
  await p2.waitForURL(/plex-tuner\.html/, { timeout: 15000 });
  await p2.waitForFunction(() => typeof plexConnected !== "undefined" && plexConnected === true, null, { timeout: 20000 });
  check("2: the restart lands in the tuner signed in", true);
  check("2: the connect screen is not showing", (await p2.evaluate(() => getComputedStyle(document.getElementById("plex-connect")).display)) === "none");
  check("2: no page errors", errors.length === 0 && errors2.length === 0, errors.concat(errors2).join(" | "));

  await p2.evaluate(() => document.getElementById("cfg-plex-btn").click());
  await p2.waitForFunction(() => localStorage.getItem("plex90_saved_auth") === null, null, { timeout: 10000 });
  await p2.waitForTimeout(1000);
  const out = await holders(p2, [TOKEN, PASSWORD, "uid1"]);
  check("3: after SIGN OUT no storage holds the token", !out.found[TOKEN], JSON.stringify(out.found[TOKEN]));
  check("3: after SIGN OUT no storage holds the user id", !out.found.uid1, JSON.stringify(out.found.uid1));
  check("3: after SIGN OUT sessionStorage is empty", (await p2.evaluate(() => sessionStorage.length)) === 0);
  check("3: after SIGN OUT the library cache is empty", out.idbRows === 0, `${out.idbRows} rows`);
  await ctx2.close();
}

// ---- 4: a login the server refuses ----
const seed = (ctx, auth) => ctx.addInitScript(([a]) => {
  if (location.pathname.endsWith("plex-tuner.html") && !localStorage.getItem("nx-seeded")) {
    localStorage.setItem("nx-seeded", "1");
    localStorage.setItem("plex90_saved_auth", JSON.stringify(a));
  }
}, [auth]);

async function refusedRun(name, viewport, backend, { old = false } = {}) {
  refuse = true;
  emby = backend === "emby";
  const ctx = await browser.newContext(viewport);
  await localOnly(ctx);
  await seed(ctx, { backend, token: "revoked", serverUrl: api, serverName: "lab", jellyfinUserId: "u", jfUrl: api, jfUser: "bob" });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/plex-tuner.html${old ? "?old=1" : ""}`);
  const word = backend === "emby" ? "EMBY" : "JELLYFIN";
  if (!old) {
    await page.waitForFunction(() => /SESSION ENDED/.test(document.getElementById("plex-error-label")?.textContent || ""), null, { timeout: 20000 });
    const label = await page.evaluate(() => document.getElementById("plex-error-label").textContent);
    check(`${name} ${backend}: says the session ended`, label.startsWith(`${word} SESSION ENDED`), label);
    check(`${name} ${backend}: the dead login is forgotten`, (await page.evaluate(() => localStorage.getItem("plex90_saved_auth"))) === null);
    const btn = page.locator("#plex-reconnect-jf");
    check(`${name} ${backend}: RECONNECT is on screen`, await btn.isVisible());
    const box = await btn.boundingBox();
    const vp = page.viewportSize();
    check(`${name} ${backend}: RECONNECT fits the screen`, box && box.y >= 0 && box.y + box.height <= vp.height && box.x >= 0 && box.x + box.width <= vp.width, JSON.stringify(box));
    await btn.click();
    await page.waitForURL(/web-tuner/, { timeout: 10000 });
    await page.waitForTimeout(1500);
    check(`${name} ${backend}: RECONNECT lands on the sign-in page and stays there`, /web-tuner/.test(page.url()) && await page.locator("#connect-jellyfin-btn").isVisible(), page.url());
  } else {
    await page.waitForTimeout(5000);
    check(`negative control ${backend}: the old page does not say the session ended`, !/SESSION ENDED/.test(await page.evaluate(() => document.getElementById("plex-error-label")?.textContent || "")));
    check(`negative control ${backend}: the old page leaves the dead login saved`, (await page.evaluate(() => localStorage.getItem("plex90_saved_auth"))) !== null);
    await page.goto(`${base}/web-tuner.html`);
    await page.waitForURL(/plex-tuner\.html/, { timeout: 10000 }).catch(() => {});
    check(`negative control ${backend}: the sign-in page forwards straight back into the tuner`, /plex-tuner\.html/.test(page.url()), page.url());
  }
  check(`${old ? "negative control" : name} ${backend}: no page errors`, errors.length === 0, errors.join(" | "));
  await ctx.close();
  refuse = false;
  emby = false;
}

for (const backend of ["jellyfin", "emby"]) {
  await refusedRun("TV 960x540", { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 }, backend);
  await refusedRun("phone 390x844", { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true }, backend);
}
await refusedRun("control", { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 }, "jellyfin", { old: true });

// Plex: plex.tv refusing the saved token forgets it too (the same helper).
{
  const ctx = await browser.newContext({ viewport: { width: 960, height: 540 } });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => {
    if (route.request().url().startsWith("https://plex.tv/api/v2/user")) {
      return route.fulfill({ status: 401, contentType: "application/json", headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*" }, body: "{}" });
    }
    return route.abort();
  });
  await seed(ctx, { backend: "plex", token: "serverTok", userToken: "accountTok", serverUrl: api, serverName: "lab" });
  const page = await ctx.newPage();
  await page.goto(`${base}/plex-tuner.html`);
  await page.waitForFunction(() => localStorage.getItem("plex90_saved_auth") === null, null, { timeout: 15000 }).catch(() => {});
  const left = await holders(page, ["serverTok", "accountTok"]);
  check("Plex: plex.tv refusing the token forgets the login and holds no token", !left.found.serverTok && !left.found.accountTok, JSON.stringify(left.found));
  await ctx.close();
}

await browser.close();
media.close();
files.close();
if (failures.length) {
  console.error(`saved login (browser): ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`saved login (browser): ${passed} passed (sign-in, restart, sign-out, refused login on Jellyfin, Emby and Plex, with the negative control)`);
