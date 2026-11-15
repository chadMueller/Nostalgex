#!/usr/bin/env node
/**
 * One rule set for which servers and libraries Nostalgex lists, starts on and reads (N-016 option A), held to
 * scripts/library-picker-golden.json. The Apple TV, Roku and Android are to be held to the same file.
 *
 * Two layers, so a port cannot drift from either:
 *   1. The rules (scripts/nostalgex-library-picker.js) against every case of the golden file.
 *   2. The real functions lifted out of plex-tuner.html (as scripts/nostalgex-library-selection-smoke.mjs does) against
 *      the same cases: listLibrarySections lists what `plexListing` and `mediaBrowserListing` say, the Plex scan and the
 *      Jellyfin scan read exactly what `reads` says, discoverServers turns on what `serverDefaults` says, and a Music or
 *      Photo library is never asked for items.
 * The picker is offered at a sign-in only with more than one library or a hidden one, and every sign-in starts the choices again
 * (the Apple TV's behaviour; rules 8 and 9 in scripts/nostalgex-library-picker.js).
 * Plus the upgrade: saved choices from the format before this change (one OFF list, the single hidden-libraries
 * switch, a bare saved listing) carry over, and nothing is lost.
 *
 * No browser, no network. Run: `npm run test:library-picker`.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import "./nostalgex-jellyfin-urls.js";
import "./nostalgex-daily-manifest.js";
import "./nostalgex-music-brainz.js";
import "./nostalgex-library-picker.js";
import "./nostalgex-library-selection.js";

const root = fileURLToPath(new URL("../", import.meta.url));
// NX_TUNER_HTML=/path checks another copy of the page (origin/main's is the negative control: its checks must fail).
const html = readFileSync(process.env.NX_TUNER_HTML || join(root, "plex-tuner.html"), "utf8");
const golden = JSON.parse(readFileSync(join(root, "scripts/library-picker-golden.json"), "utf8"));
const LP = globalThis.NostalgexLibraryPicker;
const LS = globalThis.NostalgexLibrarySelection;
const NJU = globalThis.NostalgexJellyfinUrls;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const sorted = (a) => [...a].sort();
const L2 = (id, hidden = false) => ({ id, hidden });

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
function runLifted(parts, tail, known) {
  const scope = new Proxy(known, {
    has: (t, k) => typeof k === "string" && (k in t || !(k in globalThis)),
    get: (t, k) => (k === Symbol.unscopables ? undefined : (k in t ? t[k] : (k in globalThis ? globalThis[k] : () => undefined))),
  });
  return new Function("scope", `with (scope) { return (async () => { ${parts.join("\n")}\n${tail} })(); }`)(scope);
}

/** A localStorage stand-in. */
function fakeStorage(entries = {}) {
  const store = new Map(Object.entries(entries).map(([k, v]) => [k, typeof v === "string" ? v : JSON.stringify(v)]));
  globalThis.localStorage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => { store.set(k, String(v)); }, removeItem: (k) => { store.delete(k); }, _store: store };
  return globalThis.localStorage;
}
const withState = (off, included) => fakeStorage({ [LS.STORAGE_KEY]: off || [], [LS.INCLUDED_HIDDEN_KEY]: included || [] });
const saved = (ls, key) => JSON.parse(ls._store.get(key) || "[]");

// ═══ 1. The rules, against the golden file ═══════════════════════════════════
const kind = (type) => type;   // the golden `type` is the listed type
function describeRows(rows, isPlex) {
  const multi = LP.multiServer(rows);
  return rows.map((r) => ({
    id: LP.rowId(r), title: r.title, type: r.type, label: LP.typeLabel(r.type, r.title),
    musicVideo: isPlex ? LP.musicVideoName(r.title) : r.type === "musicvideo", hidden: r.hidden, startsOn: LP.startsOn(r), subtitle: LP.subtitle(r, multi),
  }));
}
check("the golden file is version 1", golden.version === 1);
for (const c of golden.plexListing) {
  const rows = c.servers.flatMap((sv) => (sv.sections === null ? [] : LP.plexListed(sv.id, sv.name, sv.sections)));
  check(`rules, Plex listing: ${c.name}`, same(describeRows(rows, true), c.listed), JSON.stringify(describeRows(rows, true)));
}
for (const c of golden.mediaBrowserListing) {
  const rows = LP.mediaBrowserListed(c.serverId, c.serverName, c.shown, c.all, NJU.sectionType);
  check(`rules, ${c.backend} listing: ${c.name}`, same(describeRows(rows, false), c.listed), JSON.stringify(describeRows(rows, false)));
}
for (const c of golden.serverDefaults) check(`rules, server defaults: ${c.name}`, same(LP.defaultServerIds(c.servers), c.on));
const rowsOf = (libraries) => libraries.map((l) => { const at = l.id.indexOf("::"); return { serverId: l.id.slice(0, at), serverName: "S", key: l.id.slice(at + 2), title: l.id, type: "movie", hidden: l.hidden }; });
for (const c of golden.reads) {
  const read = LP.readable(rowsOf(c.libraries), { off: c.off, includedHidden: c.includedHidden }).map(LP.rowId);
  check(`rules, reads: ${c.name}`, same(read, c.read), JSON.stringify(read));
}
for (const c of golden.choices) {
  const rows = rowsOf(c.libraries);
  let state = { off: c.off, includedHidden: c.includedHidden };
  const before = JSON.stringify(state);
  for (const id of c.toggle) state = LP.toggled(rows.find((r) => LP.rowId(r) === id), state);
  check(`rules, choices: ${c.name}`, same(sorted(state.off), sorted(c.offAfter)) && same(sorted(state.includedHidden), sorted(c.includedHiddenAfter)), JSON.stringify({ off: [...state.off], includedHidden: [...state.includedHidden] }));
  check(`rules, choices leave the saved state they were given alone: ${c.name}`, JSON.stringify({ off: c.off, includedHidden: c.includedHidden }) === before);
}
for (const c of golden.hiddenSwitchUpgrade) {
  const r = LP.carryOverHiddenSwitch(c.switchOn, c.hiddenKnown, rowsOf(c.libraries), { off: c.off, includedHidden: c.includedHidden });
  check(`rules, hidden switch upgrade: ${c.name}`, same(sorted(r.includedHidden), sorted(c.includedHiddenAfter)) && r.done === c.done, JSON.stringify({ included: [...r.includedHidden], done: r.done }));
}

for (const c of golden.pickerOffered) check(`rules, picker offered: ${c.name}`, LP.offersPicker(rowsOf(c.libraries)) === c.offered);
for (const c of golden.signInReset) {
  const ls = fakeStorage({ [LS.STORAGE_KEY]: c.off, [LS.INCLUDED_HIDDEN_KEY]: c.includedHidden, ...(c.legacySwitch ? { [LS.LEGACY_HIDDEN_SWITCH_KEY]: c.legacySwitch === "on" ? "1" : "0" } : {}) });
  const after = LP.afterSignIn({ off: c.off, includedHidden: c.includedHidden });
  check(`rules, sign-in reset: ${c.name}`, same([...after.off], c.offAfter) && same([...after.includedHidden], c.includedHiddenAfter));
  LS.resetForSignIn();
  check(`storage, sign-in reset: ${c.name}`, same(saved(ls, LS.STORAGE_KEY), c.offAfter) && same(saved(ls, LS.INCLUDED_HIDDEN_KEY), c.includedHiddenAfter) && (c.legacySwitchAfter === null) === !ls._store.has(LS.LEGACY_HIDDEN_SWITCH_KEY));
}

// ═══ 2. The page's own functions, against the same cases ═════════════════════
const LL = { show() {}, hide() {}, refreshStepRail() {}, async pulsePhase() {}, setPhase() {}, isFirstLibraryLoad: () => false, state: {} };
const PLEX_PART = [lift(html, "async function listLibrarySections(")];
const PLEX_FN = (name) => lift(html, name);

/** listLibrarySections on Plex: the servers answer /library/sections; returns the listed rows as the page builds them. */
async function pageListPlex(servers) {
  const byMachine = Object.fromEntries(servers.map((sv) => [sv.id, sv]));
  const known = {
    mediaBackend: "plex", isMediaBrowserBackend: (b) => b === "jellyfin" || b === "emby",
    selectedServers: servers.map((sv) => ({ name: sv.name, machineIdentifier: sv.id, url: "http://x" })),
    plexServerUrl: "http://x", plexServerName: "x", plexToken: "t", plexConnections: [],
    globalThis: { ...globalThis, NostalgexCollections: { fetchPlexPaged: async (get) => get("/library/sections"), plexWindowPath: (p) => p } },
    plexLibraryFetchForServer: async (path, server) => { const sv = byMachine[server.machineIdentifier]; if (sv.sections === null) throw new Error("no answer"); return sv.sections; },
  };
  return runLifted(PLEX_PART, "return listLibrarySections();", known);
}
/** listLibrarySections on Jellyfin or Emby against a stub that answers the two asks; returns { rows, asked }. */
async function pageListMediaBrowser(c) {
  const asked = [];
  const known = {
    mediaBackend: c.backend, isMediaBrowserBackend: (b) => b === "jellyfin" || b === "emby", jellyfinUserId: "u", plexServerUrl: c.serverId, plexServerName: c.serverName,
    jellyfinAuthHeader: () => "", backendDisplayName: () => c.serverName,
    fetch: async (url) => {
      asked.push(url.replace(c.serverId, ""));
      const hiddenAsk = /includeHidden=true/.test(url);
      const items = hiddenAsk ? c.all : c.shown;
      if (items === null) return { ok: false, status: 500, json: async () => ({}) };
      return { ok: true, status: 200, json: async () => ({ Items: items }) };
    },
  };
  const rows = await runLifted(PLEX_PART, "return listLibrarySections();", known);
  return { rows, asked };
}

withState([], []);
LS.forgetListings();
for (const c of golden.plexListing) {
  const rows = await pageListPlex(c.servers);
  check(`page, Plex listing: ${c.name}`, same(describeRows(rows, true), c.listed), JSON.stringify(describeRows(rows, true)));
}
for (const c of golden.mediaBrowserListing) {
  withState([], []);
  const { rows, asked } = await pageListMediaBrowser(c);
  check(`page, ${c.backend} listing: ${c.name}`, same(describeRows(rows, false), c.listed), JSON.stringify(describeRows(rows, false)));
  const plainPath = c.backend === "emby" ? "/Users/u/Views" : "/UserViews?userId=u";
  check(`page, ${c.backend} asks the plain list exactly as it always did${c.backend === "jellyfin" ? ", then the hidden list" : ", and nothing else"}`,
    asked[0] === plainPath && (c.backend === "jellyfin" ? asked.length === 2 && asked[1] === "/UserViews?userId=u&includeHidden=true" : asked.length === 1), JSON.stringify(asked));
}

// The Plex scan: what it asks items of is what `reads` says, and never a Music or Photo library.
async function pageScanPlex(servers, state) {
  const asked = [];
  withState(state.off, state.includedHidden);
  LS.forgetListings();
  for (const sv of servers) {
    const known = {
      server: { name: sv.name, machineIdentifier: sv.id }, LL,
      globalThis: { ...globalThis, NostalgexCollections: { fetchPlexPaged: async () => sv.sections, plexWindowPath: (p) => p } },
      plexLibraryFetchForServer: async () => ({}),
      fetchPlexSectionPaged: async (server, section) => { asked.push(`${sv.id}::${section.key}`); return []; },
    };
    await runLifted([PLEX_FN("async function scanOnePlexServerSections(")], "return scanOnePlexServerSections(server, LL, 0, false, []);", known);
  }
  return asked;
}
for (const c of golden.plexListing) {
  const servers = c.servers.filter((sv) => sv.sections !== null);
  const asked = await pageScanPlex(servers, { off: [], includedHidden: [] });
  check(`page, Plex scan reads exactly what is listed (never Music or Photos): ${c.name}`, same(asked, c.listed.map((r) => r.id)), JSON.stringify(asked));
  check(`page, Plex scan notes the same list for Settings: ${c.name}`, same(LS.listed().map((r) => `${r.serverId}::${r.key}`), c.listed.map((r) => r.id)));
}
for (const c of golden.reads.filter((x) => x.libraries.every((l) => l.id.startsWith("machine-")))) {
  const ids = [...new Set(c.libraries.map((l) => l.id.split("::")[0]))];
  const servers = ids.map((id) => ({ id, name: id, sections: c.libraries.filter((l) => l.id.startsWith(`${id}::`)).map((l) => ({ key: l.id.split("::")[1], title: l.id, type: "movie" })) }));
  const asked = await pageScanPlex(servers, c);
  check(`page, Plex scan: ${c.name}`, same(asked, c.read), JSON.stringify(asked));
}

// The Jellyfin scan: which views it asks items of.
const TICKS = (min) => min * 60 * 10000000;
const film = (id) => ({ Id: id, Name: id, Type: "Movie", ProductionYear: 1990, Genres: [], OfficialRating: "PG", RunTimeTicks: TICKS(100), ProviderIds: {}, Studios: [], DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "", MediaSources: [{ Id: `m${id}`, Container: "mp4", Bitrate: 6000000, MediaStreams: [] }] });
async function pageScanJellyfin(libraries, { backend = "jellyfin", hiddenAnswerFails = false, url = "jelly" } = {}) {
  const parents = [];
  const asks = [];
  const keyOf = (l) => l.id.slice(l.id.indexOf("::") + 2);
  const views = libraries.map((l) => ({ Id: keyOf(l), Name: keyOf(l), CollectionType: "movies" }));
  const plain = libraries.filter((l) => !l.hidden).map((l) => views.find((v) => v.Id === keyOf(l)));
  const known = {
    fetch: async (u) => {
      const x = new URL(u, "http://server.invalid");
      if (/\/(UserViews|Views)$/.test(x.pathname)) {
        asks.push((x.pathname + x.search).replace(/^\/jelly/, ""));
        if (x.searchParams.get("includeHidden") === "true") return hiddenAnswerFails ? { status: 500, ok: false, json: async () => ({}) } : { status: 200, ok: true, json: async () => ({ Items: views }) };
        return { status: 200, ok: true, json: async () => ({ Items: plain }) };
      }
      const parent = x.searchParams.get("ParentId"); parents.push(parent);
      return { status: 200, ok: true, json: async () => ({ Items: [film(`${parent}-1`)], TotalRecordCount: 1 }) };
    },
    globalThis: { ...globalThis, NostalgexLibraryLoad: LL }, plexServerUrl: url, plexServerName: "Jelly", jellyfinUserId: "u", mediaBackend: backend, bundles: [], enabledBundleIDs: new Set(),
    discoveredGenres: {}, jellyfinAuthHeader: () => "", backendDisplayName: () => backend, adoptMediaBrowserKind: () => {},
    finalizeLibraryWithMusicBrainz: async (list) => list, CHANNELS: [], LL, channelFilter: () => ({ onChannels: (list) => list }),
    scanSignal: () => undefined, scanIsAbandoned: () => false, noteScanAnswer: () => {}, startScanWatch: () => {}, endScanWatch: () => {}, abandonedScanError: () => new Error("abandoned"),
  };
  await runLifted([PLEX_FN("function pickBestVersion("), PLEX_FN("function formatDuration("), PLEX_FN("async function fetchJellyfinLibraryFromServer("), PLEX_FN("async function fetchJellyfinLibraryScan(")], "return fetchJellyfinLibraryFromServer({ background: true });", known);
  return { read: parents, asks };
}
for (const c of golden.reads.filter((x) => x.libraries.every((l) => l.id.startsWith("jelly::")))) {
  withState(c.off, c.includedHidden);
  LS.forgetListings();
  const r = await pageScanJellyfin(c.libraries);
  check(`page, Jellyfin scan: ${c.name}`, same(r.read.map((k) => `jelly::${k}`), c.read), JSON.stringify(r.read));
}
{
  // The two asks, in order; and when the second fails the plain list is read and nothing hidden is.
  const libs = [{ id: "jelly::a", hidden: false }, { id: "jelly::h", hidden: true }];
  withState([], ["jelly::h"]);
  let r = await pageScanJellyfin(libs);
  check("page, Jellyfin scan asks /UserViews?userId=u (what it always asked), then the same with includeHidden=true", same(r.asks, ["/UserViews?userId=u", "/UserViews?userId=u&includeHidden=true"]), JSON.stringify(r.asks));
  withState([], ["jelly::h"]);
  r = await pageScanJellyfin(libs, { hiddenAnswerFails: true });
  check("page, Jellyfin scan: the second ask failing leaves the plain list, read as before", same(r.read, ["a"]), JSON.stringify(r.read));
  withState([], []);
  r = await pageScanJellyfin(libs, { backend: "emby" });
  check("page, Emby scan asks /Users/u/Views once and never includeHidden", same(r.asks, ["/Users/u/Views"]), JSON.stringify(r.asks));
}

// Whether the page opens CHOOSE YOUR LIBRARIES: lifted maybeChooseLibraries, with the listing and the screen stubbed.
async function pageOffersPicker(libraries, { signIn, firstLoad = false, seen = false }) {
  let shown = false;
  const el = { style: {}, classList: { add() {}, remove() {} }, innerHTML: "", textContent: "" };
  const known = {
    libraryPickAllowed: true, signInPending: signIn, document: { getElementById: () => el }, localStorage: { getItem: () => (seen ? "1" : null) },
    backendDisplayName: () => "Jellyfin", mediaBackend: "jellyfin", isMediaBrowserBackend: () => true, discoveredServers: [], knownLibrarySections: [],
    listLibrarySections: async () => rowsOf(libraries), showLibrarySelection: async () => { shown = true; return "continue"; }, lsSet() {}, showServerPicker() {},
    globalThis: { ...globalThis, NostalgexLibraryLoad: { isFirstLibraryLoad: () => firstLoad } },
  };
  await runLifted([PLEX_FN("async function maybeChooseLibraries(")], "return maybeChooseLibraries();", known);
  return { shown, signInPending: known.signInPending };
}
for (const c of golden.pickerOffered) {
  const r = await pageOffersPicker(c.libraries, { signIn: true });
  check(`page, picker at a sign-in: ${c.name}`, r.shown === c.offered && r.signInPending === false, JSON.stringify(r));
}
{
  const two = [L2("machine-a::1"), L2("machine-a::2")];
  check("page, picker: a reload or a saved login on an install that has loaded before does not open it", (await pageOffersPicker(two, { signIn: false, firstLoad: false })).shown === false);
  check("page, picker: a first setup that was not finished (a reload on the picker) opens it again", (await pageOffersPicker(two, { signIn: false, firstLoad: true })).shown === true);
  check("page, picker: a first setup already confirmed does not open it again", (await pageOffersPicker(two, { signIn: false, firstLoad: true, seen: true })).shown === false);
  check("page, picker: a sign-in opens it even on an install that has loaded before", (await pageOffersPicker(two, { signIn: true, firstLoad: false, seen: true })).shown === true);
}

// Server defaults on the page: discoverServers turns on what the golden says.
for (const c of golden.serverDefaults.filter((x) => x.servers.length > 0)) {
  const known = {
    fetch: async () => ({ json: async () => c.servers.map((s) => ({ provides: "server", name: s.id, clientIdentifier: s.id, owned: s.owned, connections: [] })) }),
    plexHeaders: () => ({}), discoveredServers: [], selectedServerIndices: new Set(), confirmMultiServerSelection: () => { known.confirmed = [...known.selectedServerIndices]; }, showServerPicker: () => { known.picked = true; },
  };
  await runLifted([PLEX_FN("async function discoverServers(")], "return discoverServers();", known);
  const on = [...known.selectedServerIndices].map((i) => c.servers[i].id);
  check(`page, first-setup servers: ${c.name}`, same(on, c.on) && (c.servers.length === 1 ? known.confirmed !== undefined : known.picked === true), JSON.stringify(on));
}

// ═══ 3. Upgrade: choices saved before this change carry over ═════════════════
{
  // A browser as it is today: the OFF list, the one hidden switch ON, and a bare saved listing that holds a Music library.
  const OLD_LISTING = [
    { serverId: "mach-1", serverName: "Den", key: "1", title: "Movies", type: "movie" },
    { serverId: "mach-1", serverName: "Den", key: "2", title: "Music", type: "artist" },
  ];
  let ls = fakeStorage({ [LS.STORAGE_KEY]: ["mach-1::2", "jelly::off1"], [LS.LEGACY_HIDDEN_SWITCH_KEY]: "1", nostalgex_library_listing: OLD_LISTING });
  LS.forgetListings();
  check("upgrade: the saved OFF list is read as it was (same key, same ids)", LS.isOff("mach-1", "2") && LS.isOff("jelly", "off1") && !LS.isOff("mach-1", "1"));
  check("upgrade: a bare saved listing from the old version is not used (Settings asks the server once)", LS.listed().length === 0);
  const jfShown = [{ Id: "m1", Name: "Movies", CollectionType: "movies" }, { Id: "off1", Name: "Kids", CollectionType: "movies" }];
  const jfAll = [...jfShown, { Id: "h1", Name: "Hidden Films", CollectionType: "movies" }, { Id: "h2", Name: "Adult", CollectionType: "movies" }];
  // The viewer had turned Adult off by hand while the switch was on (it is in the OFF list).
  ls.setItem(LS.STORAGE_KEY, JSON.stringify(["jelly::off1", "jelly::h2"]));
  let r = LS.mediaBrowserViews("jellyfin", "http://Jelly/", "Jelly", jfShown, null);
  check("upgrade: the hidden libraries are not known yet (second ask failed): nothing included, the old switch kept", saved(ls, LS.INCLUDED_HIDDEN_KEY).length === 0 && ls._store.get(LS.LEGACY_HIDDEN_SWITCH_KEY) === "1");
  r = LS.mediaBrowserViews("jellyfin", "jelly", "Jelly", jfShown, jfAll);
  check("upgrade: switch on, hidden libraries known: the one not turned off stays on, the one turned off stays off", same(saved(ls, LS.INCLUDED_HIDDEN_KEY), ["jelly::h1"]), JSON.stringify(saved(ls, LS.INCLUDED_HIDDEN_KEY)));
  check("upgrade: the old switch is removed once carried over", !ls._store.has(LS.LEGACY_HIDDEN_SWITCH_KEY));
  check("upgrade: the OFF list is exactly as it was", same(sorted(saved(ls, LS.STORAGE_KEY)), ["jelly::h2", "jelly::off1"]));
  check("upgrade: what the scan reads is what it read before (Movies, Hidden Films; not Kids, not Adult)",
    same(r.rows.filter((row) => LS.sectionOn(row)).map((row) => row.key), ["m1", "h1"]), JSON.stringify(r.rows.filter((row) => LS.sectionOn(row)).map((row) => row.key)));
  check("upgrade: carried over once: a hidden library the viewer later switches off stays off", (() => {
    const h1 = r.rows.find((row) => row.key === "h1");
    LS.setSectionOn(h1, false);
    LS.mediaBrowserViews("jellyfin", "jelly", "Jelly", jfShown, jfAll);
    return !LS.sectionOn(h1);
  })());

  // Switch off (the default) or never set: hidden libraries stay off, nothing changes.
  ls = fakeStorage({ [LS.LEGACY_HIDDEN_SWITCH_KEY]: "0" });
  r = LS.mediaBrowserViews("jellyfin", "jelly", "Jelly", jfShown, jfAll);
  check("upgrade: switch off: hidden libraries are listed, marked, and off", r.rows.filter((row) => row.hidden).map((row) => LS.sectionOn(row)).every((on) => on === false) && r.rows.filter((row) => row.hidden).length === 2);
  check("upgrade: switch off: nothing included, the old value cleared", saved(ls, LS.INCLUDED_HIDDEN_KEY).length === 0 && !ls._store.has(LS.LEGACY_HIDDEN_SWITCH_KEY));
  ls = fakeStorage({});
  r = LS.mediaBrowserViews("jellyfin", "jelly", "Jelly", jfShown, jfAll);
  check("upgrade: switch never set: nothing written", !ls._store.has(LS.INCLUDED_HIDDEN_KEY) && !ls._store.has(LS.LEGACY_HIDDEN_SWITCH_KEY));

  // Emby never had hidden libraries, so its listing leaves the old switch alone.
  ls = fakeStorage({ [LS.LEGACY_HIDDEN_SWITCH_KEY]: "1" });
  LS.mediaBrowserViews("emby", "emby", "Emby", jfShown, null);
  check("upgrade: Emby leaves the old switch alone", ls._store.get(LS.LEGACY_HIDDEN_SWITCH_KEY) === "1");

  // A storage that refuses writes: the old switch stays, so the carry over is tried again.
  ls = fakeStorage({ [LS.LEGACY_HIDDEN_SWITCH_KEY]: "1" });
  ls.setItem = () => { throw new Error("quota"); };
  LS.mediaBrowserViews("jellyfin", "jelly", "Jelly", jfShown, jfAll);
  check("upgrade: storage that refuses to save keeps the old switch for the next try", ls._store.get(LS.LEGACY_HIDDEN_SWITCH_KEY) === "1");

  // Nothing saved at all: Plex and Jellyfin libraries are all on, hidden ones off; no storage at all does not throw.
  fakeStorage({});
  check("nothing saved: every library is on, a hidden one off", LS.sectionOn({ serverId: "s", key: "1", hidden: false }) && !LS.sectionOn({ serverId: "s", key: "2", hidden: true }));
  delete globalThis.localStorage;
  check("no storage: every library is on, a hidden one off, and nothing throws", LS.sectionOn({ serverId: "s", key: "1", hidden: false }) && !LS.sectionOn({ serverId: "s", key: "2", hidden: true }) && LS.setSectionOn({ serverId: "s", key: "1", hidden: false }, false) === false);
  fakeStorage({ [LS.STORAGE_KEY]: "not json", [LS.INCLUDED_HIDDEN_KEY]: { not: "a list" } });
  check("a damaged saved value reads as nothing saved", LS.sectionOn({ serverId: "s", key: "1", hidden: false }) && !LS.sectionOn({ serverId: "s", key: "2", hidden: true }));

  // The new listing is kept and read back with `hidden`, and a Music row from an older write is dropped on read.
  ls = fakeStorage({});
  LS.forgetListings();
  LS.noteListing("jelly", [{ serverId: "jelly", serverName: "Jelly", key: "h1", title: "Hidden", type: "movie", hidden: true }]);
  LS.forgetListings();
  fakeStorage({ nostalgex_library_listing: { v: 2, rows: [{ serverId: "jelly", serverName: "J", key: "h1", title: "Hidden", type: "movie", hidden: true }, { serverId: "m", serverName: "D", key: "2", title: "Music", type: "artist" }] } });
  check("the saved listing keeps `hidden` and drops a library type that is not listed", same(LS.listed().map((x) => [x.key, x.hidden]), [["h1", true]]));
}

// ═══ 4. The page carries none of the old switch ═══════════════════════════════
check("the old switch's storage key is the one the urls module names", LS.LEGACY_HIDDEN_SWITCH_KEY === NJU.INCLUDE_HIDDEN_KEY);
check("the page no longer has the one hidden-libraries switch", !/cfg-include-hidden|toggleIncludeHiddenLibraries|updateIncludeHiddenControls/.test(html));
check("the page loads the picker rules before the selection storage", html.indexOf("scripts/nostalgex-library-picker.js") > 0 && html.indexOf("scripts/nostalgex-library-picker.js") < html.indexOf("scripts/nostalgex-library-selection.js"));
check("the page's Plex library signature reads the same library types the scan does", /isPlexVideoType\(d\.type\)/.test(html));

if (failures.length) {
  console.error(`library picker smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`library picker smoke: ${passed} checks passed (the golden file's ${golden.plexListing.length} Plex listings, ${golden.mediaBrowserListing.length} Jellyfin and Emby listings, ${golden.serverDefaults.length} server defaults, ${golden.reads.length} reads, ${golden.choices.length} choices and ${golden.hiddenSwitchUpgrade.length} upgrades, ${golden.pickerOffered.length} picker rules and ${golden.signInReset.length} sign-in resets, in the rules and in the page; saved choices carry over)`);
