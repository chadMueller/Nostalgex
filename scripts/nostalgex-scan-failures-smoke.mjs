#!/usr/bin/env node
/**
 * A library scan that loses part of the server keeps the rest, and one that loses all of it is a
 * failure, not an empty guide (the Apple TV's 1.0.30 rule, SectionFailures / N-039).
 *
 * Before: the Jellyfin and Emby scan read every /Items answer as JSON without looking at its
 * status, so a 401 or a 500 was an empty library, and a scan where every library failed ended in
 * the "no channels" screen, which says the server has no content. A library that lost a view was
 * also saved as if it were whole, for 24 hours.
 *
 * This runs the real Jellyfin/Emby loader, lifted out of plex-tuner.html as in
 * scripts/nostalgex-jellyfin-library-smoke.mjs, over a stub that fails on request:
 *   - one library answers 500: the others load, the loss is named, and the library is not cached;
 *   - a later page of a library fails: the pages already read are kept, and the loss is named;
 *   - every library fails: the scan throws, so the page shows its error and not the empty screen;
 *   - a refused sign-in (401, 403) ends the scan with plexStatus, as it does on Plex;
 *   - a healthy scan, and a healthy empty library, are as before and are cached.
 * The Plex side is scripts/plex-section-failures-browser-smoke.mjs.
 *
 * No browser, no network. Run: `npm run test:scan-failures`.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import "./nostalgex-jellyfin-urls.js";
import "./nostalgex-daily-manifest.js";
import "./nostalgex-music-brainz.js";

const root = fileURLToPath(new URL("../", import.meta.url));
const html = readFileSync(join(root, "plex-tuner.html"), "utf8");

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

function lift(source, signature) {
  const at = source.indexOf(signature);
  if (at < 0) throw new Error(`plex-tuner.html changed shape: no ${signature}`);
  let depth = 0;
  let close = at + signature.length - 1;
  for (; close < source.length; close++) {
    if (source[close] === "(") depth++;
    else if (source[close] === ")" && --depth === 0) break;
  }
  depth = 0;
  for (let i = source.indexOf("{", close); i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return source.slice(at, i + 1);
  }
  throw new Error(`unbalanced ${signature}`);
}

/** Runs the scan; resolves { items, options, warnings } or { error }. */
async function scan(serve) {
  let items = null;
  let options = null;
  const warnings = [];
  const env = {
    fetch: async (url) => {
      const r = serve(url);
      return { status: r.status, ok: r.status >= 200 && r.status < 300, json: async () => r.body };
    },
    NostalgexLibraryLoad: {
      show() {}, hide() {}, refreshStepRail() {}, async pulsePhase() {}, setPhase() {},
      isFirstLibraryLoad: () => false, state: {},
    },
    NostalgexMusicBrainz: globalThis.NostalgexMusicBrainz,
    finalizeLibraryWithMusicBrainz: async (list, opts) => { items = list; options = opts; return list; },
  };
  const body = [
    lift(html, "function pickBestVersion("),
    lift(html, "function formatDuration("),
    lift(html, "async function fetchJellyfinLibraryFromServer("),
    lift(html, "async function fetchJellyfinLibraryScan("),
    "return fetchJellyfinLibraryFromServer({ background: true });",
  ].join("\n");
  const run = new Function(
    "fetch", "globalThis", "plexServerUrl", "jellyfinUserId", "mediaBackend", "bundles", "enabledBundleIDs",
    "discoveredGenres", "jellyfinAuthHeader", "backendDisplayName", "adoptMediaBrowserKind",
    "finalizeLibraryWithMusicBrainz", "NostalgexJellyfinUrls", "CHANNELS", "switchChannel", "console",
    "NostalgexDailyManifest",
    // STOP WAITING (scripts/stop-waiting-browser-smoke.mjs): a background scan has no watch.
    "scanSignal", "scanIsAbandoned", "noteScanAnswer", "startScanWatch", "endScanWatch", "abandonedScanError",
    body,
  );
  const log = { log() {}, warn: (...a) => warnings.push(a.map(String).join(" ")) };
  try {
    await run(
      env.fetch, { ...globalThis, ...env }, "http://server.invalid", "u", "jellyfin", [], new Set(),
      {}, () => "", () => "Jellyfin", () => {}, env.finalizeLibraryWithMusicBrainz, globalThis.NostalgexJellyfinUrls, [], () => {}, log,
      globalThis.NostalgexDailyManifest,
      () => undefined, () => false, () => {}, () => {}, () => {}, () => new Error("abandoned"),
    );
  } catch (error) {
    return { error, items, options, warnings };
  }
  return { items, options, warnings };
}

const TICKS = (min) => min * 60 * 10000000;
const film = (id, name) => ({
  Id: id, Name: name, Type: "Movie", ProductionYear: 1988, Genres: ["Drama"], OfficialRating: "PG", RunTimeTicks: TICKS(100),
  ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "",
  MediaSources: [{ Id: `ms-${id}`, Container: "mp4", Bitrate: 6000000, MediaStreams: [] }],
});
const VIEWS = [
  { Id: "lib-a", Name: "Movies", CollectionType: "movies" },
  { Id: "lib-b", Name: "Classics", CollectionType: "movies" },
];
const held = {
  "lib-a": Array.from({ length: 5 }, (_, i) => film(`a${i}`, `Film A${i}`)),
  "lib-b": Array.from({ length: 250 }, (_, i) => film(`b${i}`, `Film B${i}`)),
};

/** A stub whose behaviour per library comes from `plan`: a status for every request, or by page. */
function stub(plan = {}) {
  return (url) => {
    const u = new URL(url, "http://server.invalid");
    if (u.pathname.endsWith("/UserViews")) return { status: 200, body: { Items: VIEWS, TotalRecordCount: VIEWS.length } };
    const parent = u.searchParams.get("ParentId");
    const start = Number(u.searchParams.get("StartIndex") || 0);
    const p = plan[parent];
    const status = typeof p === "function" ? p(start) : (p || 200);
    if (status !== 200) return { status, body: {} };
    const all = held[parent] || [];
    const limit = Number(u.searchParams.get("Limit") || all.length);
    return { status: 200, body: { Items: all.slice(start, start + limit), TotalRecordCount: all.length } };
  };
}

// ── A healthy scan is as before, and is cached ──
{
  const r = await scan(stub());
  check("healthy: the scan finishes", !r.error, String(r.error));
  check("healthy: all 255 films load", r.items && r.items.length === 255, String(r.items && r.items.length));
  check("healthy: the library is cached (nothing lost)", r.options && !r.options.skipCacheSave, JSON.stringify(r.options));
  check("healthy: no warning", r.warnings.length === 0, r.warnings.join(" | "));
}
// ── A healthy library with nothing in it is an empty library, not a failure ──
{
  const savedA = held["lib-a"].splice(0);
  const savedB = held["lib-b"].splice(0);
  const r = await scan(stub());
  held["lib-a"].push(...savedA);
  held["lib-b"].push(...savedB);
  check("empty: a healthy empty server is not an error", !r.error && r.items && r.items.length === 0, String(r.error));
}
// ── One library answers 500: the other loads, the loss is named, nothing is cached ──
{
  const r = await scan(stub({ "lib-a": 500 }));
  check("one library lost: the scan still finishes", !r.error, String(r.error));
  check("one library lost: the other library's 250 films are kept", r.items && r.items.length === 250, String(r.items && r.items.length));
  check("one library lost: the library is not cached as whole", r.options && r.options.skipCacheSave === true, JSON.stringify(r.options));
  check("one library lost: the loss is named", r.warnings.some((w) => /lost 1/.test(w) && /Movies/.test(w)), r.warnings.join(" | "));
}
// ── A later page fails: the pages already read are kept ──
{
  const r = await scan(stub({ "lib-b": (start) => (start > 0 ? 500 : 200) }));
  check("later page lost: the scan finishes", !r.error, String(r.error));
  check("later page lost: the 5 films and the 200 read are kept", r.items && r.items.length === 205, String(r.items && r.items.length));
  check("later page lost: not cached as whole, and named", r.options && r.options.skipCacheSave === true && r.warnings.some((w) => /Classics/.test(w)), r.warnings.join(" | "));
}
// ── Every library fails: a failure, not an empty guide ──
{
  const r = await scan(stub({ "lib-a": 500, "lib-b": 503 }));
  check("all lost: the scan throws", !!r.error, "it resolved");
  check("all lost: the error says what the server answered", r.error && /HTTP 50\d/.test(String(r.error.message)), String(r.error && r.error.message));
  check("all lost: no guide is built from nothing", r.items === null);
}
// ── A refused sign-in ends the scan ──
for (const code of [401, 403]) {
  const r = await scan(stub({ "lib-a": code, "lib-b": code }));
  check(`HTTP ${code}: the scan throws with plexStatus ${code}`, r.error && r.error.plexStatus === code, JSON.stringify(r.error && r.error.plexStatus));
}
{
  const r = await scan(stub({ "lib-b": 401 }));
  check("HTTP 401 on one library still ends the scan (the sign-in is gone, not one library)", r.error && r.error.plexStatus === 401, String(r.error));
}

if (failures.length) {
  console.error(`scan failures smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`scan failures smoke: ${passed} checks passed (partial loss keeps the rest, total loss is an error, a refused sign-in ends the scan)`);
