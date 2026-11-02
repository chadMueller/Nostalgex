#!/usr/bin/env node
/**
 * Franchise channels and the FRANCHISES / OTHER COLLECTIONS split, in the real page.
 *
 * Loads plex-tuner.html, headless, against a Jellyfin-shaped server whose library and
 * collections are the first lineup of scripts/franchise-lineup-golden.json ("a bit of
 * everything, package on"): the same films, shows, TMDB collections (served as the Supabase
 * enrichment rows the page reads), server collections and franchise choices the Swift test
 * gives the Apple TV. What the Apple TV answers for it is in that file, so the page is held
 * to it here: the classics' pools, the Settings rows, each collection's category and fold,
 * every runtime channel with its number, id and members, and the guide.
 *
 * Then it drives Settings the way a viewer does, by click and by key: one franchise's
 * switch, REMOVE ALL, ADD ALL, the FRANCHISES package switch, a reload that keeps the
 * choices; checks the section at phone, tablet, desktop and 960x540 (clicks only, as a TV
 * browser has no keys); and times a rebuild on a 10,000-episode library.
 *
 * Negative control: NX_TUNER_HTML=/path serves another copy of the page (origin/main's) in
 * place of plex-tuner.html; it must fail. SHOTS=/dir saves screenshots.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:franchise-channels:browser`.
 */
import http from "node:http";
import { readFileSync, existsSync, statSync, mkdirSync } from "node:fs";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
// TUNER_ROOT serves another build of the tuner (dist, dist-selfhost) instead of this checkout.
const repo = fileURLToPath(new URL("../", import.meta.url));
const root = process.env.TUNER_ROOT ? process.env.TUNER_ROOT.replace(/\/?$/, "/") : repo;
const shots = process.env.SHOTS || "";
if (shots) mkdirSync(shots, { recursive: true });

const golden = JSON.parse(readFileSync(join(repo, "scripts/franchise-lineup-golden.json"), "utf8"));
const scenario = golden.lineups.find((l) => l.name === "a bit of everything, package on");
if (!scenario || !scenario.expected) throw new Error("the golden file has no answered lineup to drive the page with");

// ── The server: Jellyfin-shaped, holding the scenario's library ──

const TICKS = (min) => min * 60 * 10000000;
const tmdbOf = new Map(); // golden item id or show key -> numeric TMDB id
let nextTmdb = 700000;
const tmdb = (key) => {
  if (!tmdbOf.has(key)) tmdbOf.set(key, nextTmdb++);
  return tmdbOf.get(key);
};
const MARVEL = new Set(["mv1", "mv2", "mv3", "sm1", "sm2", "sm3"]);

function media(id, minutes) {
  return [{ Id: `ms-${id}`, Container: "mp4", RunTimeTicks: TICKS(minutes), Size: 2000000, SupportsDirectPlay: true,
    MediaStreams: [{ Type: "Video", Codec: "h264", Width: 1280, Height: 720, Index: 0, IsDefault: true }] }];
}

function jellyfinFor(items, boxSets) {
  const movies = items.filter((i) => i.type === "movie");
  const episodes = items.filter((i) => i.type === "episode");
  const shows = new Map();
  const episodesByShow = new Map();
  for (const e of episodes) {
    if (!shows.has(e.showKey)) { shows.set(e.showKey, e.title); episodesByShow.set(e.showKey, []); }
    episodesByShow.get(e.showKey).push(e);
  }
  const movieJSON = movies.map((m) => ({
    Id: m.id, Name: m.title, Type: "Movie", ProductionYear: 2001, Genres: [], OfficialRating: null,
    RunTimeTicks: TICKS(120), ProviderIds: { Tmdb: String(tmdb(m.id)) },
    Studios: MARVEL.has(m.id) ? [{ Name: "Marvel Studios" }] : [],
    DateCreated: "2020-01-01T00:00:00.0000000Z", MediaSources: media(m.id, 120),
  }));
  const seriesJSON = [...shows].map(([key, name]) => ({
    Id: key, Name: name, Type: "Series", ProductionYear: 2019, Genres: [], Studios: [], ProviderIds: { Tmdb: String(tmdb(`show:${key}`)) },
  }));
  const episodeJSONByShow = new Map();
  for (const [key, list] of episodesByShow) {
    episodeJSONByShow.set(key, list.map((e, i) => ({
      Id: e.id, Name: e.episodeTitle || "Pilot", Type: "Episode", ParentIndexNumber: 1, IndexNumber: i + 1,
      RunTimeTicks: TICKS(45), DateCreated: "2020-01-01T00:00:00.0000000Z", MediaSources: media(e.id, 45),
    })));
  }
  const episodeJSON = (key) => episodeJSONByShow.get(key) || [];
  const byId = new Map(movieJSON.map((x) => [x.Id, x]));
  for (const list of episodeJSONByShow.values()) for (const x of list) byId.set(x.Id, x);
  const page = (list, url) => {
    const start = Number(new URL(url, "http://x").searchParams.get("StartIndex") || 0);
    const limit = Number(new URL(url, "http://x").searchParams.get("Limit") || 200);
    return { Items: list.slice(start, start + limit), TotalRecordCount: list.length };
  };
  return (url) => {
    const q = new URL(url, "http://x").searchParams;
    if (url.startsWith("/System/Info/Public")) return { ServerName: "lab", Version: "10.10.7", ProductName: "Jellyfin Server", Id: "lab" };
    if (url.startsWith("/UserViews")) {
      return { Items: [{ Id: "lib-movies", Name: "Movies", CollectionType: "movies" }, { Id: "lib-tv", Name: "Shows", CollectionType: "tvshows" }], TotalRecordCount: 2 };
    }
    if (!url.startsWith("/Items")) return {};
    const types = q.get("IncludeItemTypes") || "";
    const parent = q.get("ParentId");
    if (types === "BoxSet") return { Items: boxSets.map((b) => ({ Id: b.id, Name: b.title })), TotalRecordCount: boxSets.length };
    const box = boxSets.find((b) => b.id === parent);
    if (box) return page(box.members.map((id) => byId.get(id) || seriesJSON.find((s) => s.Id === id)).filter(Boolean), url);
    if (parent === "lib-movies") return page(movieJSON, url);
    if (parent === "lib-tv") return page(seriesJSON, url);
    if (shows.has(parent)) return page(episodeJSON(parent), url);
    return { Items: [], TotalRecordCount: 0 };
  };
}

/** The Supabase rows the page reads for enrichment: the scenario's TMDB collections, nothing else. */
function enrichmentRows(items) {
  const rows = [];
  for (const m of items.filter((i) => i.type === "movie")) {
    rows.push({
      tmdb_id: String(tmdb(m.id)), media_type: "movie", keywords: [], networks: [], production_companies: [], tmdb_genres: [],
      franchise_id: m.enrichment ? m.enrichment.franchiseID : null, franchise_name: m.enrichment ? m.enrichment.franchiseName : null,
      fetched_at: "2026-10-01T00:00:00.000Z",
    });
  }
  const seen = new Set();
  for (const e of items.filter((i) => i.type === "episode")) {
    if (seen.has(e.showKey)) continue;
    seen.add(e.showKey);
    rows.push({ tmdb_id: String(tmdb(`show:${e.showKey}`)), media_type: "tv", keywords: [], networks: [], production_companies: [],
      tmdb_genres: [], franchise_id: null, franchise_name: null, fetched_at: "2026-10-01T00:00:00.000Z" });
  }
  return rows;
}

let libraryAnswer = jellyfinFor(scenario.items, scenario.collections.map((c) => ({ id: c.id, title: c.title, members: c.members })));
let enrichment = enrichmentRows(scenario.items);

const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  res.writeHead(200, { "Content-Type": "application/json" });
  const url = req.url;
  if (url.startsWith("/rest/v1/media_enrichments")) {
    if (req.method !== "GET") return res.end("[]");
    const ids = new Set((/tmdb_id=in\.\(([^)]*)\)/.exec(url) || [, ""])[1].split(","));
    return res.end(JSON.stringify(enrichment.filter((r) => ids.has(r.tmdb_id))));
  }
  if (url.startsWith("/relay")) { res.writeHead(404); return res.end("{}"); }
  res.end(JSON.stringify(libraryAnswer(url)));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${server.address().port}`;

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    if (process.env.NX_TUNER_HTML) body = readFileSync(process.env.NX_TUNER_HTML);
    body = body.toString()
      .replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>")
      .replace("%VITE_SUPABASE_URL%", api).replace("%VITE_SUPABASE_ANON_KEY%", "anon").replace("%VITE_TMDB_RELAY_URL%", `${api}/relay`);
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${files.address().port}`;

// ── Checks ──

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
/** JSON with the keys in order, so two objects with the same content compare equal. */
const canon = (v) => JSON.stringify(v, (_, x) => (x && typeof x === "object" && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));
const same = (a, b) => canon(a) === canon(b);
/** Where two values first differ, for a failure message. */
function firstDiff(a, b, path = "") {
  if (canon(a) === canon(b)) return "";
  if (a && b && typeof a === "object" && typeof b === "object") {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const k of keys) {
      const d = firstDiff(a[k], b[k], `${path}/${k}`);
      if (d) return d;
    }
  }
  return `${path}: got ${JSON.stringify(a)} want ${JSON.stringify(b)}`;
}
const norm = (v) => JSON.parse(JSON.stringify(v, (_, x) => (x === undefined ? null : x)));

const browser = await chromium.launch({ headless: true });
const VIEWPORTS = { desktop: [1440, 900], tablet: [820, 1180], phone: [390, 844], tv960: [960, 540] };

/** A fresh browser context with the viewer's saved choices, signed in to the fake server. */
async function openPage(viewport = "desktop", { seed = true, extra = {} } = {}) {
  const [w, h] = VIEWPORTS[viewport];
  const ctx = await browser.newContext({ viewport: { width: w, height: h } });
  await ctx.route((u) => !/^(127\.0\.0\.1|localhost)$/.test(u.hostname), (route) => route.abort());
  await ctx.addInitScript(([url, s, more]) => {
    if (!location.pathname.endsWith("plex-tuner.html") || sessionStorage.getItem("nx-seeded")) return;
    sessionStorage.setItem("nx-seeded", "1");
    localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "jellyfin", jellyfinUserId: "u" }));
    if (s) {
      localStorage.setItem("nostalgex_enabled_bundles", JSON.stringify(["nostalgex", "franchises"]));
      localStorage.setItem("nostalgex_enabled_franchises", JSON.stringify(s.enabledFranchiseIDs));
      localStorage.setItem("nostalgex_disabled_franchises", JSON.stringify(s.disabledFranchiseIDs));
      localStorage.setItem("nostalgex_enabled_collections", JSON.stringify(s.enabledCollectionIDs.map((id) => `jellyfin:${id}`)));
    }
    for (const [k, v] of Object.entries(more)) localStorage.setItem(k, v);
  }, [api, seed ? scenario : null, extra]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  await page.goto(`${base}/plex-tuner.html`);
  return { ctx, page, errors };
}

async function settled(page, { found = "dict:JOHN WICK", timeout = 30000 } = {}) {
  await page.waitForFunction(
    (id) => collectionScanState === "done" && enrichmentRecords && foundFranchises.some((f) => f.id === id),
    found, { timeout },
  );
  await page.waitForTimeout(400);
}


/** What the page ended up with, in the shape the golden file records it. */
const snapshot = (page) => page.evaluate(() => {
  const kind = (id) => (id >= 1020000 ? "otherCollection" : id >= 1010000 ? "franchiseCollection" : "found");
  const ids = (list) => list.map((i) => i.ratingKey);
  const pools = {};
  // The classics in the lineup, as the app's `allChannels` holds them: built with enough to air.
  for (const ch of allChannelsUnfiltered) {
    if (ch.stock && franchiseBundleChannelIDs().includes(ch.id) && ch.itemPool.length >= ch.minItems) pools[String(ch.id)] = ids(ch.itemPool);
  }
  return {
    stockPools: pools,
    rows: franchiseRows,
    collections: collectionCandidates.map((c) => ({ id: c.id.replace(/^jellyfin:/, ""), title: c.title, category: c.category, foldedInto: c.foldedInto })),
    channels: allChannelsUnfiltered.filter(isRuntimeChannel).sort((a, b) => a.number - b.number)
      .map((ch) => ({ number: ch.number, id: ch.id, name: ch.name, kind: kind(ch.id), items: ids(ch.itemPool) })),
    // On air: in the guide and with enough to play.
    guide: CHANNELS.filter((c) => c.enabled).map((c) => c.number).filter((n) => n >= 300 && n <= 499).sort((a, b) => a - b),
  };
});

const guideRuntime = (page) => page.evaluate(() => CHANNELS.filter(isRuntimeChannel).map((c) => `${c.number} ${c.name}`));
const guideFranchiseNumbers = (page) => page.evaluate(() => CHANNELS.filter((c) => c.enabled).map((c) => c.number).filter((n) => n >= 300 && n < 400));

/** One section of the test. A page that cannot do the thing at all is a failure with a name, not a stack trace. */
async function block(name, fn) {
  try {
    await fn();
  } catch (err) {
    failures.push(`${name} stopped: ${String(err && err.message).split("\n")[0].slice(0, 200)}`);
  }
}

// 1. The page against the Apple TV's answers.
await block("the page against the Apple TV", async () => {
  const { ctx, page, errors } = await openPage("desktop");
  await settled(page);
  const got = norm(await snapshot(page));
  const want = scenario.expected;
  check("the classics' pools match the Apple TV", same(got.stockPools, want.stockPools), firstDiff(got.stockPools, want.stockPools));
  check("the Settings rows match the Apple TV", same(got.rows, want.rows), firstDiff(got.rows, want.rows));
  const byId = new Map(got.collections.map((c) => [c.id, c]));
  const collectionsOK = want.collections.every((w) => {
    const g = byId.get(w.id);
    return g && g.title === w.title && g.category === w.category && g.foldedInto === w.foldedInto;
  });
  check("every collection's category and fold match the Apple TV", collectionsOK, JSON.stringify(got.collections).slice(0, 500));
  check("every runtime channel has the Apple TV's number, id, name and members", same(got.channels, want.channels),
    firstDiff(got.channels, want.channels));
  check("the guide's franchise numbers match the Apple TV", same(got.guide, want.guide), firstDiff(got.guide, want.guide));
  check("no page errors on load", errors.length === 0, errors.join(" | "));
  const nums = await guideFranchiseNumbers(page);
  check("the guide shows the classics at CH 300 and 301 and the rest from 310", nums[0] === 300 && nums[1] === 301 && nums[2] === 310, JSON.stringify(nums));
  if (shots) await page.screenshot({ path: join(shots, "franchises-guide-desktop.png") });
  await ctx.close();
});

// 2. Settings, by click.
await block("Settings, by click", async () => {
  const { ctx, page, errors } = await openPage("desktop");
  await settled(page);
  await page.evaluate(() => showConfig());
  const list = page.locator("#franchise-list");
  const row = (name) => list.locator(".bundle-row", { hasText: name }).first();

  const titles = await list.locator(".bundle-row:not(.franchise-all) div[style*='font-size: 16px']").allInnerTexts();
  const names = titles.map((t) => t.trim());
  check("the FRANCHISES section starts with the package switch", names[0] === "FRANCHISES", JSON.stringify(names.slice(0, 3)));
  check("the classics are listed with the found franchises, A to Z",
    names.slice(1).join("|") === [...scenario.expected.rows.map((r) => r.name), ...scenario.expected.collections
      .filter((c) => c.category === "franchises" && !c.foldedInto).map((c) => c.title)].sort((a, b) => a.toLowerCase() < b.toLowerCase() ? -1 : 1).join("|"),
    names.join("|"));
  check("a classic shows its channel number", /CH 300/.test(await row("STAR WARS").innerText()));
  check("a found franchise on air shows its channel number", /CH 311/.test(await row("JOHN WICK").innerText()), await row("JOHN WICK").innerText());
  check("a folded collection is not listed again", (await list.locator(".bundle-row", { hasText: "WIZARDING WORLD" }).count()) === 0);
  check("MY COLLECTIONS lists only the other collections",
    (await page.locator("#collection-list .bundle-row").allInnerTexts()).every((t) => !/SAGA|VOYAGER MIX/.test(t)));

  await row("JOHN WICK").click();
  let nums = await guideRuntime(page);
  check("clicking a found franchise takes its channel out and closes the numbers up",
    same(nums, ["310 ALIEN SAGA", "311 SPY KIDS", "312 STAR TREK", "313 VOYAGER MIX", "400 TOM HANKS"]), JSON.stringify(nums));
  const saved = await page.evaluate(() => [localStorage.getItem("nostalgex_enabled_franchises"), localStorage.getItem("nostalgex_disabled_franchises")]);
  check("the choice is saved by stable id", JSON.parse(saved[1]).includes("dict:JOHN WICK") && !JSON.parse(saved[0]).includes("dict:JOHN WICK"), JSON.stringify(saved));

  await page.locator("#franchise-list .franchise-all", { hasText: "REMOVE ALL" }).click();
  check("REMOVE ALL empties the franchise block and the classics", same(await guideFranchiseNumbers(page), []), JSON.stringify(await guideFranchiseNumbers(page)));
  check("REMOVE ALL leaves the other collections alone", (await guideRuntime(page)).join() === "400 TOM HANKS", (await guideRuntime(page)).join());
  const disabledCount = await page.evaluate(() => JSON.parse(localStorage.getItem("nostalgex_disabled_franchises")).length);
  check("REMOVE ALL records a choice for every row", disabledCount === scenario.expected.rows.length, String(disabledCount));

  await page.locator("#franchise-list .franchise-all", { hasText: "ADD ALL" }).click();
  nums = await guideRuntime(page);
  check("ADD ALL puts the lot on air, SPIDER-MAN included",
    same(nums, ["310 ALIEN SAGA", "311 JOHN WICK", "312 SPIDER-MAN", "313 SPY KIDS", "314 STAR TREK", "315 VOYAGER MIX", "400 TOM HANKS"]), JSON.stringify(nums));
  const afterAddAll = await guideFranchiseNumbers(page);
  check("ADD ALL brings the classics back", afterAddAll.slice(0, 3).join() === "300,301,302", JSON.stringify(afterAddAll));

  await row("FRANCHISES").first().click();
  check("the package switch takes every franchise channel out of the guide", same(await guideFranchiseNumbers(page), []));
  check("the other collections stay when the package is off", (await guideRuntime(page)).join() === "400 TOM HANKS", (await guideRuntime(page)).join());
  check("the section says why its list is empty", /SWITCH FRANCHISES ON/.test(await page.locator("#franchises-status").innerText()));
  await page.locator("#franchise-list .bundle-row").first().click();
  check("the package switch back on restores them", same(await guideFranchiseNumbers(page), afterAddAll), JSON.stringify(await guideFranchiseNumbers(page)));
  check("no page errors while switching", errors.length === 0, errors.join(" | "));
  if (shots) {
    await page.locator("#franchise-list").scrollIntoViewIfNeeded();
    await page.screenshot({ path: join(shots, "franchises-settings-desktop.png") });
  }
  await ctx.close();
});

// 3. Settings, by key.
await block("Settings, by key", async () => {
  const { ctx, page } = await openPage("desktop");
  await settled(page);
  await page.evaluate(() => { showConfig(); });
  const index = await page.evaluate(() => {
    const m = bundleTabModel();
    return m.packages.length + m.franchises.findIndex((r) => r.kind === "row" && r.row.id === "dict:JOHN WICK");
  });
  for (let i = 0; i < index; i++) await page.keyboard.press("ArrowDown");
  const at = await page.evaluate(() => bundleFocusIndex);
  check("the arrow keys walk packages, then the FRANCHISES rows", at === index, `${at} vs ${index}`);
  await page.keyboard.press("Enter");
  check("Enter switches the focused franchise", !(await guideRuntime(page)).some((c) => /JOHN WICK/.test(c)), (await guideRuntime(page)).join());
  await page.keyboard.press("Enter");
  check("and back on", (await guideRuntime(page)).some((c) => /JOHN WICK/.test(c)));
  const total = await page.evaluate(() => bundleTabModel().total);
  for (let i = 0; i < total + 3; i++) await page.keyboard.press("ArrowDown");
  check("the index stops at the last row", (await page.evaluate(() => bundleFocusIndex)) === total - 1);
  await ctx.close();
});

// 4. A reload keeps the choices.
await block("a reload", async () => {
  const { ctx, page } = await openPage("desktop");
  await settled(page);
  await page.evaluate(() => showConfig());
  await page.locator("#franchise-list .bundle-row", { hasText: "SPY KIDS" }).first().click();
  const before = await guideRuntime(page);
  await page.reload();
  await settled(page);
  const after = await guideRuntime(page);
  check("a reload keeps what the viewer switched", same(before, after) && !after.some((c) => /SPY KIDS/.test(c)), `${before.join()} -> ${after.join()}`);
  await ctx.close();
});

// 5. The section at every size.
for (const name of Object.keys(VIEWPORTS)) await block(`the section at ${name}`, async () => {
  const { ctx, page, errors } = await openPage(name);
  await settled(page);
  await page.evaluate(() => showConfig());
  await page.locator("#franchise-list").scrollIntoViewIfNeeded();
  const m = await page.evaluate(() => {
    const list = document.getElementById("franchise-list");
    const r = list.getBoundingClientRect();
    const rows = [...list.querySelectorAll(".bundle-row")];
    const panel = document.querySelector(".config-panel");
    return {
      vw: innerWidth, left: r.left, right: r.right, rows: rows.length,
      overflow: rows.some((el) => el.scrollWidth > el.clientWidth + 1),
      panelOverflow: panel ? panel.scrollWidth > panel.clientWidth + 1 : false,
      wide: panel ? [...panel.querySelectorAll("*")].filter((el) => el.getBoundingClientRect().right > panel.getBoundingClientRect().right + 1 && el.offsetParent !== null)
        .slice(0, 3).map((el) => `${el.tagName}.${el.className || el.id} ${Math.round(el.getBoundingClientRect().right)}`) : [],
      docOverflow: document.documentElement.scrollWidth > innerWidth + 1,
      fullscreen: !!document.fullscreenElement,
    };
  });
  check(`${name}: the list sits inside the screen`, m.left >= 0 && m.right <= m.vw + 1, JSON.stringify(m));
  check(`${name}: no row overflows`, !m.overflow && !m.docOverflow, JSON.stringify(m));
  check(`${name}: not in browser full screen`, m.fullscreen === false);
  // A pointer click on a row works at this size (a TV browser has no keys).
  await page.locator("#franchise-list .bundle-row", { hasText: "STAR TREK" }).first().click();
  check(`${name}: a click switches a franchise`, !(await guideRuntime(page)).some((c) => /STAR TREK/.test(c)), (await guideRuntime(page)).join());
  check(`${name}: no page errors`, errors.length === 0, errors.join(" | "));
  if (shots) await page.screenshot({ path: join(shots, `franchises-settings-${name}.png`) });
  await ctx.close();
});

// 6. A big library: the franchises are found again in step with the page, not minutes after.
await block("a big library", async () => {
  const big = JSON.parse(JSON.stringify(scenario.items));
  for (let s = 0; s < 400; s++) {
    for (let e = 0; e < 25; e++) big.push({ id: `bs${s}e${e}`, type: "episode", title: `Show Number ${s}`, episodeTitle: `Episode ${e + 1}`, showKey: `bigshow${s}` });
  }
  for (let m = 0; m < 1500; m++) big.push({ id: `bm${m}`, type: "movie", title: `Some Film Number ${m}`, ...(m % 5 === 0 ? { enrichment: { franchiseID: 1000 + (m % 90), franchiseName: `Series ${m % 90} Collection` } } : {}) });
  libraryAnswer = jellyfinFor(big, scenario.collections.map((c) => ({ id: c.id, title: c.title, members: c.members })));
  enrichment = enrichmentRows(big);
  const { ctx, page } = await openPage("desktop");
  await settled(page, { timeout: 90000 });
  const ms = await page.evaluate(() => {
    const times = [];
    for (let i = 0; i < 3; i++) { const t = performance.now(); refreshDynamicChannels(); times.push(Math.round(performance.now() - t)); }
    return { times, items: allItemsCache.length };
  });
  console.log(`rebuild on ${ms.items} items: ${ms.times.join(", ")} ms`);
  check(`rebuilding the franchises on ${ms.items} items takes under 1.5 s`, Math.max(...ms.times) < 1500, ms.times.join(", "));
  await ctx.close();
});

await browser.close();
server.close();
files.close();

const total = passed + failures.length;
if (failures.length) {
  console.error(`franchise channels (browser): ${failures.length} of ${total} FAILED`);
  for (const f of failures) console.error(`  x ${f}`);
  process.exit(1);
}
console.log(`franchise channels (browser): ${total} checks passed`);
