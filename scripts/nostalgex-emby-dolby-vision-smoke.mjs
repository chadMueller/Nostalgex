#!/usr/bin/env node
/**
 * On Emby, a Dolby Vision profile 5 file goes on no channel. It stays in the library, and
 * profile 8, 7, HDR10, SDR and an unknown profile stay on channels. Jellyfin and Plex are not
 * touched. The rule is isLeftOffChannels in scripts/nostalgex-channel-filter.cjs; the field is
 * point 11 in scripts/nostalgex-jellyfin-urls.js.
 *
 * Runs the page's own scan (fetchJellyfinLibraryFromServer), filterItems and
 * refreshDynamicChannels, cut out of plex-tuner.html, against a fake server answering with
 * the video stream fields Emby 4.10.1.0 and Jellyfin 12.2.0 send (copied from the lab servers,
 * 2026-10-19), over the shipped channels.json. Every "left off" check has a control: the same
 * file from Jellyfin, through the same code, reaching channels.
 * Same cases as Nostalgex/NostalgexTests/EmbyDolbyVisionChannelTests.swift.
 *
 * Run: `npm run test:emby-dolby-vision`. TUNER / FILTER / URLS point at other files for a
 * negative control.
 */
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tunerPath = process.env.TUNER || path.join(root, "plex-tuner.html");
const filterPath = process.env.FILTER || path.join(root, "scripts/nostalgex-channel-filter.cjs");
const urlsPath = process.env.URLS || path.join(root, "scripts/nostalgex-jellyfin-urls.js");
const collectionsPath = path.join(root, "scripts/nostalgex-collections.js");
const franchiseBuilderPath = path.join(root, "scripts/nostalgex-franchise-builder.js");
const franchiseLineupPath = path.join(root, "scripts/nostalgex-franchise-lineup.js");
// The loaders read minutes and dates through the schedule engine, as the page loads it first.
const manifestPath = path.join(root, "scripts/nostalgex-daily-manifest.js");
const tuner = fs.readFileSync(tunerPath, "utf8");
const readJSON = (p) => JSON.parse(fs.readFileSync(path.join(root, p), "utf8"));
const config = readJSON("channels.json");
const manifest = readJSON("channels-memberships.json");
// Same normalisation as plex-tuner.html loadStockChannelsFromJSON.
const exclusiveRules = (config.exclusiveRules || []).map((r) => ({
  channelIDs: r.channelIDs || (r.channelID != null ? [r.channelID] : []),
  genres: r.genres || [],
  titleContains: r.titleContains || [],
  editorialTitles: r.editorialTitles || [],
  manifestExclusive: !!r.manifestExclusive,
}));
const stockChannels = config.channels.filter((ch) => ch.rules);

let passed = 0;
const failures = [];
async function check(label, fn) {
  try {
    await fn();
    passed += 1;
  } catch (e) {
    failures.push(`${label}: ${e.message}`);
  }
}
function same(actual, expected, msg) {
  const a = JSON.stringify(actual), b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${msg}: got ${a}, want ${b}`);
}
function assert(ok, msg) {
  if (!ok) throw new Error(msg);
}

// Cut a top-level-in-script function out of the page by matching braces, skipping strings,
// template literals and comments. (Same as nostalgex-jellyfin-subtitles-smoke.mjs.)
function extractFunction(src, name) {
  const start = src.search(new RegExp(`(async\\s+)?function\\s+${name}\\s*\\(`));
  if (start < 0) throw new Error(`${name} not found in ${path.basename(tunerPath)}`);
  let i = src.indexOf("{", src.indexOf(")", start));
  let depth = 0;
  const stack = [];
  for (; i < src.length; i++) {
    const c = src[i], n = src[i + 1];
    const mode = stack[stack.length - 1];
    if (mode === "line") { if (c === "\n") stack.pop(); continue; }
    if (mode === "block") { if (c === "*" && n === "/") { stack.pop(); i++; } continue; }
    if (mode === "'" || mode === '"') { if (c === "\\") i++; else if (c === mode) stack.pop(); continue; }
    if (mode === "`") {
      if (c === "\\") i++;
      else if (c === "`") stack.pop();
      else if (c === "$" && n === "{") { stack.push("${"); depth++; i++; }
      continue;
    }
    if (c === "/" && n === "/") { stack.push("line"); i++; continue; }
    if (c === "/" && n === "*") { stack.push("block"); i++; continue; }
    if (c === "'" || c === '"' || c === "`") { stack.push(c); continue; }
    if (c === "{") depth++;
    if (c === "}") {
      depth--;
      if (mode === "${") stack.pop();
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error(`${name}: unbalanced braces`);
}

// ── A fake server ──────────────────────────────────────────────────────────

// Video stream fields as each server sends them for each kind of file (lab, 2026-10-19).
const EMBY_VIDEO = {
  dv5: { VideoRange: "DolbyVision", ExtendedVideoType: "DolbyVision", ExtendedVideoSubType: "DoviProfile50", ExtendedVideoSubTypeDescription: "Profile 5.0" },
  dv5mp4: { CodecTag: "dvh1", VideoRange: "DolbyVision", ExtendedVideoType: "DolbyVision", ExtendedVideoSubType: "DoviProfile50", ExtendedVideoSubTypeDescription: "Profile 5.0" },
  dv81: { VideoRange: "DolbyVision", ExtendedVideoType: "DolbyVision", ExtendedVideoSubType: "DoviProfile81", ExtendedVideoSubTypeDescription: "Profile 8.1 (HDR10 compatible)" },
  dv76: { VideoRange: "DolbyVision", ExtendedVideoType: "DolbyVision", ExtendedVideoSubType: "DoviProfile76", ExtendedVideoSubTypeDescription: "Profile 7.6 (Bluray)" },
  hdr10: { VideoRange: "HDR 10", ExtendedVideoType: "Hdr10", ExtendedVideoSubType: "Hdr10", ExtendedVideoSubTypeDescription: "HDR 10" },
  sdr: { VideoRange: "SDR", ExtendedVideoType: "None", ExtendedVideoSubType: "None", ExtendedVideoSubTypeDescription: "None" },
  unknown: { VideoRange: "DolbyVision", ExtendedVideoType: "DolbyVision" },
};
const JELLYFIN_VIDEO = {
  dv5: { DvVersionMajor: 1, DvProfile: 5, DvBlSignalCompatibilityId: 0, VideoRange: "HDR", VideoRangeType: "DOVI" },
  dv5mp4: { CodecTag: "dvh1", DvVersionMajor: 1, DvProfile: 5, DvBlSignalCompatibilityId: 0, VideoRange: "HDR", VideoRangeType: "DOVI" },
  dv81: { DvVersionMajor: 1, DvProfile: 8, DvBlSignalCompatibilityId: 1, VideoRange: "HDR", VideoRangeType: "DOVIWithHDR10" },
  dv76: { DvVersionMajor: 1, DvProfile: 7, DvBlSignalCompatibilityId: 6, VideoRange: "HDR", VideoRangeType: "DOVIWithEL" },
  hdr10: { VideoRange: "HDR", VideoRangeType: "HDR10" },
  sdr: { VideoRange: "SDR", VideoRangeType: "SDR" },
  unknown: { VideoRange: "HDR", VideoRangeType: "DOVI" },
};
const FILM_KINDS = ["dv5", "dv5mp4", "dv81", "dv76", "hdr10", "sdr", "unknown"];
const EPISODE_KINDS = ["dv5", "dv81", "sdr"];
const LEFT_OFF = ["f-dv5", "f-dv5mp4", "e-dv5"];
const MIN = 600000000; // ticks

function fakeServer(video) {
  const source = (id, kind) => ({
    Id: `src-${id}`, Container: kind === "dv5mp4" ? "mp4" : "mkv", Bitrate: 20000000,
    MediaStreams: [
      { Index: 0, Type: "Video", Codec: "hevc", Profile: "Main 10", BitDepth: 10, Height: 2160, Width: 3840, ...video[kind] },
      { Index: 1, Type: "Audio", Codec: "aac", Language: "eng", Channels: 2 },
    ],
  });
  const films = FILM_KINDS.map((kind) => ({
    Id: `f-${kind}`, Name: `Lab Clip ${kind}`, Type: "Movie", RunTimeTicks: 100 * MIN, Genres: ["Comedy", "Action"],
    ProductionYear: 2003, OfficialRating: "PG", MediaSources: [source(`f-${kind}`, kind)],
  }));
  const series = [{ Id: "show1", Name: "Lab Clip Show", Type: "Series", Genres: ["Comedy", "Action"], ProductionYear: 2003, OfficialRating: "TV-PG" }];
  const episodes = EPISODE_KINDS.map((kind, i) => ({
    Id: `e-${kind}`, Name: "Pilot", Type: "Episode", SeriesName: "Lab Clip Show", ParentIndexNumber: 1, IndexNumber: i + 1,
    RunTimeTicks: 25 * MIN, MediaSources: [source(`e-${kind}`, kind)],
  }));
  const views = [{ Id: "lib-films", Name: "Films", CollectionType: "movies" }, { Id: "lib-tv", Name: "Shows", CollectionType: "tvshows" }];
  const requests = [];
  async function fetch(url) {
    const u = new URL(url);
    requests.push(u);
    let body = null;
    if (/^\/Users\/[^/]+\/Views$/.test(u.pathname) || u.pathname === "/UserViews") body = { Items: views };
    else if (u.pathname === "/Items") {
      const parent = u.searchParams.get("ParentId"), types = u.searchParams.get("IncludeItemTypes");
      const all = parent === "lib-films" && types === "Movie" ? films
        : parent === "lib-tv" && types === "Series" ? series
          : parent === "show1" && types === "Episode" ? episodes : [];
      const start = Number(u.searchParams.get("StartIndex") || 0), limit = Number(u.searchParams.get("Limit") || 200);
      body = { Items: all.slice(start, start + limit), TotalRecordCount: all.length };
    }
    const text = JSON.stringify(body ?? {});
    return { status: body ? 200 : 404, ok: !!body, json: async () => JSON.parse(text) };
  }
  return { fetch, requests };
}

// ── The page's own functions, in a context of their own ───────────────────

const PAGE_FUNCTIONS = [
  "backendDisplayName", "pickBestVersion", "formatDuration", "channelFilter", "filterItems",
  "fetchJellyfinLibraryFromServer", "isMediaBrowserBackend", "collectionServerKeyForItem",
  "refreshDynamicChannels", "franchiseItemKey", "franchisePackageOn", "franchiseBundleChannelIDs", "rulePoolOf", "isRuntimeChannel",
];

function page(backend, server) {
  const logs = [];
  const ctx = {
    console: { log: (...a) => logs.push(a.join(" ")), warn: () => {}, error: (...a) => logs.push(`ERROR ${a.join(" ")}`) },
    URL, URLSearchParams, Promise, Set, Map, Math, Number, String, JSON, Date, Array, Object, RegExp, Error,
    fetch: server.fetch,
    mediaBackend: backend,
    plexServerUrl: "http://lab.local:8096",
    jellyfinUserId: "u1",
    jellyfinAuthHeader: () => 'MediaBrowser Client="Nostalgex", Token="TKN"',
    adoptMediaBrowserKind(kind) { ctx.mediaBackend = kind; },
    bundles: [],
    enabledBundleIDs: new Set(),
    discoveredGenres: {},
    CHANNELS: [],
    switchChannel() {},
    finalizeLibraryWithMusicBrainz: async (items) => { ctx.scanned = items; return items; },
    NostalgexLibraryLoad: {
      state: {}, show() {}, hide() {}, refreshStepRail() {}, async pulsePhase() {}, setPhase() {},
      isFirstLibraryLoad: () => false,
    },
    channelMembershipManifest: manifest,
    exclusiveRules,
    // refreshDynamicChannels
    allItemsCache: [], allChannelsUnfiltered: [], rawCollections: null, collectionCandidates: [],
    collectionsOverCap: 0, enabledCollectionKeys: new Set(), currentChannel: null,
    franchiseDefinitions: [], enabledFranchiseIDs: new Set(), disabledFranchiseIDs: new Set(), foundFranchises: [], franchiseRows: [], franchiseOverCap: 0, FRANCHISES_BUNDLE_ID: "franchises",
    guideVisible: false, configVisible: false, configTab: "",
    applyBundleFilter() {}, renderConfig() {}, renderActiveGuide() {}, renderBundleList() {}, buildChannelSchedule() {},
  };
  vm.createContext(ctx);
  for (const p of [manifestPath, urlsPath, filterPath, collectionsPath, franchiseBuilderPath, franchiseLineupPath]) vm.runInContext(fs.readFileSync(p, "utf8"), ctx, { filename: p });
  vm.runInContext((/const BACKEND_NAMES = \{[^}]*\};/.exec(tuner) || [""])[0].replace("const ", "var "), ctx);
  for (const name of PAGE_FUNCTIONS) vm.runInContext(extractFunction(tuner, name), ctx, { filename: `plex-tuner.html#${name}` });
  ctx.logs = logs;
  return ctx;
}

async function scan(backend) {
  const server = fakeServer(backend === "emby" ? EMBY_VIDEO : JELLYFIN_VIDEO);
  const ctx = page(backend, server);
  await vm.runInContext("fetchJellyfinLibraryFromServer({ background: true })", ctx);
  return { ctx, server, items: ctx.scanned || [] };
}

/** Stock channel ids the page's own filterItems puts `id` on. */
function channelsHolding(ctx, items, id) {
  return stockChannels
    .filter((ch) => ctx.filterItems(items, ch.rules, ch.id, ch.category).some((it) => it.ratingKey === id))
    .map((ch) => ch.id);
}

const byKey = (items) => Object.fromEntries(items.map((i) => [i.ratingKey, i]));
const ALL_IDS = [...FILM_KINDS.map((k) => `f-${k}`), ...EPISODE_KINDS.map((k) => `e-${k}`)];

const emby = await scan("emby");
const jellyfin = await scan("jellyfin");

// ── Emby's field and the rule, on their own ───────────────────────────────

await check("embyDoviProfile reads Emby's ExtendedVideoSubType", () => {
  const JU = emby.ctx.NostalgexJellyfinUrls;
  const table = [["DoviProfile50", 5], ["DoviProfile81", 8], ["DoviProfile84", 8], ["DoviProfile76", 7], ["doviprofile50", 5],
    ["DoviProfile100", 10], ["Hdr10", null], ["None", null], ["", null], [null, null], [undefined, null],
    ["DoviProfile5", null], ["DoviProfile", null], ["DoviProfile5x", null], ["Profile 5.0", null]];
  same(table.map(([v]) => JU.embyDoviProfile(v)), table.map(([, p]) => p), "profiles");
});

await check("isLeftOffChannels: Emby profile 5 only", () => {
  const CF = emby.ctx.NostalgexChannelFilter;
  const cases = [["emby", 5, true], ["emby", 8, false], ["emby", 7, false], ["emby", null, false], ["emby", undefined, false],
    ["jellyfin", 5, false], ["plex", 5, false], [undefined, 5, false]];
  same(cases.map(([b, p]) => CF.isLeftOffChannels({ doviProfile: p }, b)), cases.map((c) => c[2]), "rule");
  same(CF.onChannels([{ doviProfile: 5, n: 1 }, { doviProfile: 8, n: 2 }, { n: 3 }], "emby").map((i) => i.n), [2, 3], "onChannels emby");
  same(CF.onChannels([{ doviProfile: 5, n: 1 }], "jellyfin").map((i) => i.n), [1], "onChannels jellyfin");
});

// ── The page's scan ───────────────────────────────────────────────────────

await check("Emby scan: every file is in the library, with Emby's profile", () => {
  const items = byKey(emby.items);
  same(Object.keys(items).sort(), [...ALL_IDS].sort(), "library");
  same(ALL_IDS.map((id) => items[id].doviProfile),
    [5, 5, 8, 7, null, null, null, 5, 8, null], "doviProfile (f-dv5 f-dv5mp4 f-dv81 f-dv76 f-hdr10 f-sdr f-unknown e-dv5 e-dv81 e-sdr)");
});

await check("Emby scan asks for nothing new", () => {
  const fields = new Set(emby.server.requests.filter((u) => u.pathname === "/Items").map((u) => u.searchParams.get("Fields")));
  same([...fields], ["ProviderIds,Overview,Genres,Studios,MediaSources,ProductionYear,PremiereDate,DateCreated,UserData"], "Fields");
});

await check("Emby scan logs one count line, no titles", () => {
  const lines = emby.ctx.logs.filter((l) => l.includes("CHANNELS"));
  same(lines, ["[Emby] CHANNELS: 3 Dolby Vision profile 5 item(s) left off channels"], "log");
  assert(!emby.ctx.logs.some((l) => /Lab Clip/.test(l)), "a title reached the log");
});

await check("Jellyfin scan is unchanged: no profile read, no count line", () => {
  const items = byKey(jellyfin.items);
  same(Object.keys(items).sort(), [...ALL_IDS].sort(), "library");
  same(ALL_IDS.map((id) => items[id].doviProfile ?? null), ALL_IDS.map(() => null), "doviProfile");
  assert(!jellyfin.ctx.logs.some((l) => l.includes("CHANNELS")), "Jellyfin logged a count");
});

// ── Channels: the page's own filterItems over channels.json ───────────────

const control = Object.fromEntries(ALL_IDS.map((id) => [id, channelsHolding(jellyfin.ctx, jellyfin.items, id)]));

await check("control: every file reaches channels from Jellyfin", () => {
  for (const id of ALL_IDS) assert(control[id].length > 0, `${id} reaches no channel from Jellyfin`);
});

for (const id of ALL_IDS) {
  const leftOff = LEFT_OFF.includes(id);
  await check(`Emby ${id}: ${leftOff ? "on no channel" : "same channels as from Jellyfin"}`, () => {
    same(channelsHolding(emby.ctx, emby.items, id), leftOff ? [] : control[id], "channels");
  });
}

await check("a channel without rules leaves Emby profile 5 out, and keeps it on Jellyfin", () => {
  same(emby.ctx.filterItems(emby.items, null).map((i) => i.ratingKey).sort(),
    ALL_IDS.filter((id) => !LEFT_OFF.includes(id)).sort(), "emby");
  same(jellyfin.ctx.filterItems(jellyfin.items, null).map((i) => i.ratingKey).sort(), [...ALL_IDS].sort(), "jellyfin");
});

await check("Plex profile 5 stays on channels", () => {
  const plex = page("plex", fakeServer(EMBY_VIDEO));
  const items = emby.items.map((i) => ({ ...i }));   // doviProfile 5 on three of them
  for (const id of LEFT_OFF) same(channelsHolding(plex, items, id), control[id], id);
});

// ── Server collections: the page's own refreshDynamicChannels ─────────

function collectionPool(scanned) {
  const ctx = scanned.ctx;
  ctx.allItemsCache = scanned.items;
  ctx.allChannelsUnfiltered = [];
  ctx.rawCollections = [{ id: "jellyfin:c-lab", title: "Lab Set", childKeys: ["f-dv5", "f-dv81", "f-hdr10", "f-sdr"], serverKey: "jellyfin" }];
  ctx.enabledCollectionKeys = new Set(["jellyfin:c-lab"]);
  vm.runInContext("refreshDynamicChannels()", ctx);
  const ch = ctx.allChannelsUnfiltered.find((c) => c.collection && c.collectionID === "jellyfin:c-lab");
  return ch ? ch.itemPool.map((i) => i.ratingKey).sort() : null;
}

await check("server collection: Emby leaves profile 5 out, Jellyfin keeps it", () => {
  same(collectionPool(jellyfin), ["f-dv5", "f-dv81", "f-hdr10", "f-sdr"], "jellyfin (control)");
  same(collectionPool(emby), ["f-dv81", "f-hdr10", "f-sdr"], "emby");
});

if (failures.length) {
  console.error(`emby dolby vision: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`emby dolby vision: ${passed} checks passed`);
