#!/usr/bin/env node
/**
 * Plex sign-in finds the server's address without waiting on the ones it will not use.
 *
 * The web tuner tested every address plex.tv lists with Promise.all, so every sign-in waited
 * for the slowest, a dead remote address costing its whole 5 s timeout. The Apple TV and Roku
 * stop once the answer cannot change (scripts/nostalgex-server-resolve.js has the rules).
 *
 * This loads the real plex-tuner.html, headless, and signs in the way a viewer's second visit
 * does: a plex.tv token, plex.tv's list of servers (served here), and a Plex server per address
 * that answers, hangs (a blackhole: it takes the connection and never replies, as a dead
 * address does), or is refused. It reports, for each case, how long the connect phase took
 * (plex.tv's list of servers arriving, to the first /library/sections request, read from the
 * servers' own clocks), which server the library came from, and how long until the library was in the
 * guide, and holds them to the bounds below.
 *
 *   MEASURE_ONLY=1   print the numbers and assert nothing, for a before/after run on another page
 *   NX_TUNER_HTML=/path   serve another copy of the page (origin/main's) in place of
 *                         plex-tuner.html
 *   TUNER_ROOT=/path/to/dist (or dist-selfhost)   run on a build
 *   RUNS=3           repeat each case and report the median
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:plex-resolve:browser`.
 */
import http from "node:http";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const repo = fileURLToPath(new URL("../", import.meta.url));
const root = process.env.TUNER_ROOT ? process.env.TUNER_ROOT.replace(/\/?$/, "/") : repo;
const measureOnly = process.env.MEASURE_ONLY === "1";
const runs = Math.max(1, Number(process.env.RUNS || 1));

const movie = (n, title) => ({
  ratingKey: String(100 + n), title, summary: "", year: 1985 + n, duration: 5400000, type: "movie",
  addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Action" }],
  Media: [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${n}/file.mp4` }] }],
});
const metadata = Array.from({ length: 6 }, (_, i) => movie(i + 1, `Film ${i + 1}`));

// ── Servers. One per address, each with its own behaviour. ──
const open = new Set();
const track = (server) => { server.on("connection", (s) => { open.add(s); s.on("close", () => open.delete(s)); }); return server; };
const t0 = () => Number(process.hrtime.bigint() / 1000000n);

/** behaviour: "ok:<ms>", "wrong:<ms>" (another Plex server answers), "hang", "refuse". */
async function startAddress(behaviour, machineId, log) {
  if (behaviour === "refuse") {
    // A port nothing listens on: the connection is refused at once.
    const s = net.createServer();
    await new Promise((r) => s.listen(0, "127.0.0.1", r));
    const port = s.address().port;
    await new Promise((r) => s.close(r));
    return { port, close: async () => {} };
  }
  if (behaviour === "hang") {
    const s = track(net.createServer((sock) => { sock.on("error", () => {}); /* never answers */ }));
    await new Promise((r) => s.listen(0, "127.0.0.1", r));
    return { port: s.address().port, close: async () => { s.close(); } };
  }
  const [kind, ms] = behaviour.split(":");
  const delay = Number(ms || 0);
  const s = track(http.createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Headers", "*");
    if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
    const path = req.url.split("?")[0];
    log.push({ at: t0(), path, port: s.address().port });
    res.setHeader("Content-Type", "application/json");
    if (path === "/identity") {
      return setTimeout(() => res.end(JSON.stringify({ MediaContainer: { machineIdentifier: kind === "wrong" ? "someone-elses-plex" : machineId, version: "1.43.4" } })), delay);
    }
    if (path === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }] } }));
    if (path === "/library/sections/1/all") return res.end(JSON.stringify({ MediaContainer: { size: metadata.length, totalSize: metadata.length, Metadata: metadata } }));
    res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
  }));
  await new Promise((r) => s.listen(0, "127.0.0.1", r));
  return { port: s.address().port, close: async () => { s.close(); } };
}

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
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${files.address().port}`;

const browser = await chromium.launch({ headless: true });

/**
 * One sign-in. servers: [{ name, id, addresses: [{ tier, behaviour }] }], tier one of
 * "local", "remote" (HTTPS, so a blackhole it is), "remote-plain", "relay".
 */
async function signIn(servers, { waitMs = 40000 } = {}) {
  const log = [];
  const started = [];
  const resources = [];
  for (const s of servers) {
    const connections = [];
    for (const a of s.addresses) {
      const addr = await startAddress(a.behaviour, s.id, log);
      started.push(addr);
      const scheme = a.tier === "remote" ? "https" : "http";   // HTTPS to a plain server fails at once; to a blackhole it hangs
      connections.push({
        protocol: scheme, address: "127.0.0.1", port: addr.port, uri: `${scheme}://127.0.0.1:${addr.port}`,
        local: a.tier === "local", relay: a.tier === "relay",
      });
    }
    resources.push({ name: s.name, provides: "server", owned: true, accessToken: "t", clientIdentifier: s.id, presence: true, connections });
  }

  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  let resourcesAt = null;
  await ctx.route(/plex\.tv\/api\/v2\/resources/, (route) => { resourcesAt = t0(); return route.fulfill({
    status: 200, contentType: "application/json",
    headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*" },
    body: JSON.stringify(resources),
  }); });
  await ctx.addInitScript(() => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      // A viewer who has a plex.tv token and is picking a server: the page goes straight to finding one.
      sessionStorage.setItem("plex90_token", "t");
      sessionStorage.setItem("plex90_pick_server", "1");
    }
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));
  await page.goto(`${base}/plex-tuner.html`);
  // Two or more servers: the picker, with everything selected. CONNECT is a button.
  let clickedAt = null;
  if (servers.length > 1) { await page.locator(".server-picker-connect").click({ timeout: 20000 }); clickedAt = t0(); }
  // A first sign-in stops at CHOOSE YOUR LIBRARIES once a server answers: one press of CONTINUE (all on) starts the scan.
  // Where nothing answers there is no list, so the wait is short and the case goes on to its failure.
  await page.locator(".library-continue").click({ timeout: waitMs }).catch(() => {});
  let loaded = false;
  try {
    await page.waitForFunction(() => typeof allItemsCache !== "undefined" && allItemsCache.length > 0, null, { timeout: waitMs });
    loaded = true;
  } catch { /* the failure case: nothing reachable */ }
  const loadedAt = t0();
  const errorText = await page.evaluate(() => (document.getElementById("plex-error-label") || {}).textContent || "");
  const tunerCount = await page.evaluate(() => (typeof allItemsCache !== "undefined" ? allItemsCache.length : 0));
  const pickedNames = await page.evaluate(() => (typeof selectedServers !== "undefined" ? selectedServers.map((x) => x.name) : []));
  const primaryName = await page.evaluate(() => (typeof plexServerName !== "undefined" ? plexServerName : null));
  await ctx.close();
  for (const a of started) await a.close();
  const sections = log.filter((l) => l.path === "/library/sections");
  const firstSections = sections[0];
  return {
    loaded, count: tunerCount, errors, errorText, pickedNames, primaryName,
    // From plex.tv's list of servers arriving (or, with several servers, CONNECT pressed) to the
    // first library request: the whole of finding addresses.
    connectMs: resourcesAt !== null && firstSections ? firstSections.at - (clickedAt ?? resourcesAt) : null,
    loadMs: loaded && resourcesAt !== null ? loadedAt - (clickedAt ?? resourcesAt) : null,
    sectionPorts: [...new Set(sections.map((l) => l.port))],
    resources, log,
  };
}

const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; };

// What each case has, and what the page may take. `max` is the connect phase in ms.
const one = (addresses) => [{ name: "Lab", id: "lab-plex", addresses }];
const cases = [
  { name: "home answers in 30 ms; remote and relay are dead",
    servers: one([{ tier: "local", behaviour: "ok:30" }, { tier: "remote", behaviour: "hang" }, { tier: "relay", behaviour: "hang" }]),
    expectAddress: 0, max: 1500 },
  { name: "home 30 ms, remote 300 ms, relay 1800 ms, all answer",
    servers: one([{ tier: "local", behaviour: "ok:30" }, { tier: "remote-plain", behaviour: "ok:300" }, { tier: "relay", behaviour: "ok:1800" }]),
    expectAddress: 0, max: 1500 },
  { name: "home refused at once; remote answers in 150 ms; relay is dead",
    servers: one([{ tier: "local", behaviour: "refuse" }, { tier: "remote-plain", behaviour: "ok:150" }, { tier: "relay", behaviour: "hang" }]),
    expectAddress: 1, max: 1500 },
  { name: "no home address (a shared server); remote answers in 150 ms; relay is dead",
    servers: one([{ tier: "remote-plain", behaviour: "ok:150" }, { tier: "relay", behaviour: "hang" }]),
    expectAddress: 0, max: 1500 },
  { name: "home is dead (blackholed); remote answers in 150 ms; relay is dead",
    servers: one([{ tier: "local", behaviour: "hang" }, { tier: "remote-plain", behaviour: "ok:150" }, { tier: "relay", behaviour: "hang" }]),
    expectAddress: 1, min: 2800, max: 3800 },   // the home address gets its 3 s, as on the Apple TV and Roku
  { name: "only the relay answers (200 ms); home and remote are dead",
    servers: one([{ tier: "local", behaviour: "refuse" }, { tier: "remote", behaviour: "refuse" }, { tier: "relay", behaviour: "ok:200" }]),
    expectAddress: 2, max: 1500 },
  { name: "home is another Plex server (wrong identity); remote answers in 150 ms",
    servers: one([{ tier: "local", behaviour: "wrong:30" }, { tier: "remote-plain", behaviour: "ok:150" }]),
    expectAddress: 1, max: 1500 },
  { name: "nothing answers",
    servers: one([{ tier: "local", behaviour: "hang" }, { tier: "remote", behaviour: "hang" }, { tier: "relay", behaviour: "hang" }]),
    expectNone: true, min: 4500, max: 9000 },
  { name: "three servers, each: home 30 ms, remote and relay dead",
    servers: ["A", "B", "C"].map((n) => ({ name: `Lab ${n}`, id: `lab-plex-${n}`, addresses: [{ tier: "local", behaviour: "ok:30" }, { tier: "remote", behaviour: "hang" }, { tier: "relay", behaviour: "hang" }] })),
    expectAddress: 0, max: 2500, many: true },
  // Servers are asked together, not one after another, and the list keeps the order they were
  // picked in: the first is the primary, even when a later one answers sooner.
  { name: "two servers: the first answers in 900 ms, the second in 30 ms; the first stays the primary",
    servers: [
      { name: "Lab A", id: "lab-plex-A", addresses: [{ tier: "local", behaviour: "ok:900" }] },
      { name: "Lab B", id: "lab-plex-B", addresses: [{ tier: "local", behaviour: "ok:30" }] },
    ],
    expectAddress: 0, max: 2500, many: true, expectOrder: ["Lab A", "Lab B"] },
  { name: "three servers, two of them off (every address dead), one answering",
    servers: [
      { name: "Lab A", id: "lab-plex-A", addresses: [{ tier: "local", behaviour: "hang" }, { tier: "remote", behaviour: "hang" }] },
      { name: "Lab B", id: "lab-plex-B", addresses: [{ tier: "local", behaviour: "ok:30" }] },
      { name: "Lab C", id: "lab-plex-C", addresses: [{ tier: "remote", behaviour: "hang" }, { tier: "relay", behaviour: "hang" }] },
    ],
    expectAddress: 0, min: 4500, max: 7000, many: true, live: 1, expectOrder: ["Lab B"] },   // one wait for the dead ones, not one each
];

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const rows = [];
for (const c of cases) {
  if (process.env.ONLY && !c.name.includes(process.env.ONLY)) continue;
  const results = [];
  // A case where nothing answers waits just past the last probe's timeout, not for a library.
  for (let i = 0; i < runs; i++) results.push(await signIn(c.servers, { waitMs: c.expectNone ? 9500 : 40000 }));
  const r = results[0];
  const connect = results.map((x) => x.connectMs).filter((x) => x !== null);
  const load = results.map((x) => x.loadMs).filter((x) => x !== null);
  const connectMs = connect.length ? median(connect) : null;
  const loadMs = load.length ? median(load) : null;
  // Which address (its place in its own server's list) the first library request went to.
  const usedAddress = r.sectionPorts.length ? Math.max(...r.resources.map((x) => x.connections.findIndex((y) => y.port === r.sectionPorts[0]))) : -1;
  rows.push({ name: c.name, connectMs, loadMs, loaded: r.loaded, usedAddress });
  console.log(`${connectMs === null ? "   n/a" : String(connectMs).padStart(6)} ms connect  ${loadMs === null ? "   n/a" : String(loadMs).padStart(6)} ms to library  ${r.loaded ? "library loaded" : "no library"}  ${r.sectionPorts.length ? `address #${usedAddress}` : "no address"}  | ${c.name}`);
  if (measureOnly) continue;
  if (c.expectNone) {
    check(`${c.name}: no address, no library`, !r.loaded && r.sectionPorts.length === 0);
    check(`${c.name}: the page says the server cannot be reached`, /CANNOT REACH ANY SELECTED SERVER/.test(r.errorText), r.errorText);
    continue;
  }
  const live = c.live || c.servers.length;
  check(`${c.name}: the library loads (every answering server's films)`, r.loaded && r.count === metadata.length * live, `${r.loaded} ${r.count}`);
  if (c.expectOrder) check(`${c.name}: the servers are in the order they were picked, the first is the primary`, JSON.stringify(r.pickedNames) === JSON.stringify(c.expectOrder) && r.primaryName === c.expectOrder[0], `${JSON.stringify(r.pickedNames)} primary ${r.primaryName}`);
  check(`${c.name}: the library comes from the expected address (#${c.expectAddress})`, usedAddress === c.expectAddress, `address #${usedAddress}`);
  if (c.max != null) check(`${c.name}: connect phase under ${c.max} ms`, connectMs !== null && connectMs <= c.max, `${connectMs} ms`);
  if (c.min != null) check(`${c.name}: connect phase takes at least ${c.min} ms (the home address gets its grace)`, connectMs !== null && connectMs >= c.min, `${connectMs} ms`);
  check(`${c.name}: no page errors`, r.errors.length === 0, r.errors.join(" | "));
}

await browser.close();
for (const s of open) s.destroy();
files.close();

if (measureOnly) process.exit(0);
if (failures.length) {
  console.error(`plex resolve browser: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`plex resolve browser: ${passed} checks passed`);
process.exit(0);
