#!/usr/bin/env node
/**
 * Library selection (CHOOSE YOUR LIBRARIES, Settings > SERVERS & ACCOUNTS): the scan skips the libraries the
 * viewer switched OFF, on every backend, and nothing else about it changes.
 *
 * Runs the real scan functions lifted out of plex-tuner.html (as scripts/nostalgex-scan-failures-smoke.mjs does):
 *   - Plex: scanOnePlexServerSections asks for the sections that are on and never for an off one;
 *   - Jellyfin and Emby: fetchJellyfinLibraryScan reads the items of the views that are on only;
 *   - OFF by default: with nothing stored, every library is read, as before;
 *   - the key is <serverId>::<sectionKey> (ids, not names), so a rename on the server changes nothing, and the
 *     same section key on two Plex servers is two libraries.
 *
 * No browser, no network. Run: `npm run test:library-selection`.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import "./nostalgex-jellyfin-urls.js";
import "./nostalgex-daily-manifest.js";
import "./nostalgex-music-brainz.js";
import "./nostalgex-library-selection.js";

const root = fileURLToPath(new URL("../", import.meta.url));
const html = readFileSync(join(root, "plex-tuner.html"), "utf8");
const LS = globalThis.NostalgexLibrarySelection;

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

/** A localStorage stand-in holding the OFF set. */
function withOff(ids) {
  const store = new Map(ids ? [[LS.STORAGE_KEY, JSON.stringify(ids)]] : []);
  globalThis.localStorage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => { store.set(k, String(v)); }, _store: store };
}
const noStorage = () => { delete globalThis.localStorage; };

/** Lifted functions run in a scope where any name the page defines elsewhere is a harmless stub. */
function runLifted(parts, tail, known) {
  const scope = new Proxy(known, {
    has: (t, k) => typeof k === "string" && (k in t || !(k in globalThis)),
    get: (t, k) => (k === Symbol.unscopables ? undefined : (k in t ? t[k] : (k in globalThis ? globalThis[k] : () => undefined))),
  });
  return new Function("scope", `with (scope) { return (async () => { ${parts.join("\n")}\n${tail} })(); }`)(scope);
}

const LL = { show() {}, hide() {}, refreshStepRail() {}, async pulsePhase() {}, setPhase() {}, isFirstLibraryLoad: () => false, state: {} };

// ── the module ──
noStorage();
check("default: nothing is off (no storage at all)", !LS.isOff("srv", "1"));
withOff(null);
check("default: nothing is off (empty storage)", !LS.isOff("srv", "1"));
check("setOff writes the key <serverId>::<sectionKey>", LS.setOff("srv", "1", true) && JSON.parse(globalThis.localStorage._store.get(LS.STORAGE_KEY)).join() === "srv::1");
check("an off library is off, the same key on another server is not", LS.isOff("srv", "1") && !LS.isOff("other", "1"));
LS.setOff("srv", "1", false);
check("switching it back on removes it", !LS.isOff("srv", "1"));
withOff(["srv::7"]);
check("a saved list survives a reload (it is only storage)", LS.isOff("srv", "7"));
globalThis.localStorage.setItem(LS.STORAGE_KEY, "not json");
check("a damaged value reads as nothing off", !LS.isOff("srv", "7"));
check("a Plex server without a machineIdentifier is keyed by name", LS.plexServerId({ name: "Den" }) === "Den" && LS.plexServerId({ machineIdentifier: "abc", name: "Den" }) === "abc");
check("a Jellyfin server is keyed by its address, case and trailing slash ignored", LS.mediaBrowserServerId("HTTP://Jelly.local:8096/") === "http://jelly.local:8096");
check("labels follow the Apple TV", LS.typeLabel("show") === "TV Shows" && LS.typeLabel("movie", "Music Videos") === "Music Videos" && LS.typeLabel("movie", "Films") === "Movies");

// ── Plex ──
async function plexScan(servers) {
  const asked = [];
  const sections = [{ key: "1", title: "Movies", type: "movie" }, { key: "2", title: "Shows", type: "show" }, { key: "3", title: "Classics", type: "movie" }];
  const known = {
    globalThis: { ...globalThis, NostalgexCollections: { fetchPlexPaged: async () => sections, plexWindowPath: (p) => p } },
    plexLibraryFetchForServer: async () => ({}),
    fetchPlexSectionPaged: async (server, section) => { asked.push(`${server.name}:${section.key}`); return []; },
  };
  for (const server of servers) {
    await runLifted([lift(html, "async function scanOnePlexServerSections(")], "return scanOnePlexServerSections(server, LL, 0, false, []);", { ...known, server, LL });
  }
  return asked;
}
withOff(null);
check("Plex: nothing off, every section is read", (await plexScan([{ name: "A", machineIdentifier: "idA" }])).join() === "A:1,A:2,A:3");
withOff(["idA::2"]);
LS.forgetListings();
check("Plex: an off section is not asked for, the others are", (await plexScan([{ name: "A", machineIdentifier: "idA" }])).join() === "A:1,A:3");
check("Plex: the scan lists all three sections, the off one too, for Settings", await (async () => { LS.forgetListings(); await plexScan([{ name: "A", machineIdentifier: "idA" }]); return LS.listed().map((x) => x.key).join() === "1,2,3" && LS.listed()[0].serverName === "A"; })());
check("Plex: the same key on another server is still read", (await plexScan([{ name: "B", machineIdentifier: "idB" }])).join() === "B:1,B:2,B:3");
withOff(["Den::1"]);
check("Plex: a server without a machineIdentifier is keyed by its name", (await plexScan([{ name: "Den" }])).join() === "Den:2,Den:3");
noStorage();
check("Plex: no storage reads everything (nothing changes on a page that cannot save)", (await plexScan([{ name: "A", machineIdentifier: "idA" }])).join() === "A:1,A:2,A:3");

// ── Jellyfin and Emby ──
const TICKS = (min) => min * 60 * 10000000;
const film = (id) => ({ Id: id, Name: id, Type: "Movie", ProductionYear: 1990, Genres: [], OfficialRating: "PG", RunTimeTicks: TICKS(100), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "", MediaSources: [{ Id: `m${id}`, Container: "mp4", Bitrate: 6000000, MediaStreams: [] }] });
const VIEWS = [{ Id: "lib-a", Name: "Movies", CollectionType: "movies" }, { Id: "lib-b", Name: "Classics", CollectionType: "movies" }, { Id: "lib-c", Name: "Kids", CollectionType: "movies" }];
async function mbScan(backend, url) {
  const parents = [];
  let items = [];
  const known = {
    fetch: async (u) => {
      const x = new URL(u, "http://server.invalid");
      if (/\/(UserViews|Views)$/.test(x.pathname)) return { status: 200, ok: true, json: async () => ({ Items: VIEWS }) };
      const parent = x.searchParams.get("ParentId"); parents.push(parent);
      return { status: 200, ok: true, json: async () => ({ Items: [film(`${parent}-1`)], TotalRecordCount: 1 }) };
    },
    globalThis: { ...globalThis, NostalgexLibraryLoad: LL }, plexServerUrl: url, jellyfinUserId: "u", mediaBackend: backend, bundles: [], enabledBundleIDs: new Set(),
    discoveredGenres: {}, jellyfinAuthHeader: () => "", backendDisplayName: () => backend, adoptMediaBrowserKind: () => {},
    finalizeLibraryWithMusicBrainz: async (list) => { items = list; return list; }, CHANNELS: [], LL, channelFilter: () => ({ onChannels: (list) => list }),
    scanSignal: () => undefined, scanIsAbandoned: () => false, noteScanAnswer: () => {}, startScanWatch: () => {}, endScanWatch: () => {}, abandonedScanError: () => new Error("abandoned"),
  };
  await runLifted([lift(html, "function pickBestVersion("), lift(html, "function formatDuration("), lift(html, "async function fetchJellyfinLibraryFromServer("), lift(html, "async function fetchJellyfinLibraryScan(")], "return fetchJellyfinLibraryFromServer({ background: true });", known);
  return { parents, items };
}
for (const backend of ["jellyfin", "emby"]) {
  const url = "http://Server.invalid:8096/";
  LS.forgetListings();
  withOff(null);
  let r = await mbScan(backend, url);
  check(`${backend}: nothing off, every library is read`, r.parents.join() === "lib-a,lib-b,lib-c" && r.items.length === 3, r.parents.join());
  withOff([`${LS.mediaBrowserServerId(url)}::lib-b`]);
  r = await mbScan(backend, url);
  check(`${backend}: an off library is not read, the others are`, r.parents.join() === "lib-a,lib-c" && r.items.length === 2, r.parents.join());
  check(`${backend}: the scan lists all three libraries, the off one too, for Settings`, LS.listed().map((x) => x.key).join() === "lib-a,lib-b,lib-c" && LS.listed().every((x) => x.serverId === LS.mediaBrowserServerId(url) && x.type === "movie"), JSON.stringify(LS.listed()));
  check(`${backend}: its films are not in the library`, !r.items.some((i) => String(i.id || i.title || "").includes("lib-b")));
  withOff([`http://other.invalid::lib-a`]);
  r = await mbScan(backend, url);
  check(`${backend}: another server's off library changes nothing here`, r.parents.length === 3, r.parents.join());
}
noStorage();

if (failures.length) {
  console.error(`library selection smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`library selection smoke: ${passed} checks passed (off libraries are not scanned on Plex, Jellyfin and Emby; nothing is off by default)`);
