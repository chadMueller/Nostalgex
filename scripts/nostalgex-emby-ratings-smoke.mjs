#!/usr/bin/env node
/**
 * Emby titles keep their content rating and star rating (GitHub #204, found by @tydude001).
 *
 * Emby 4.10 leaves OfficialRating and CommunityRating out of an /Items answer unless `Fields`
 * names them (measured on Emby 4.10.1.0: 0 of 200 films carried either with the scan's old
 * Fields, 195 and 197 of 200 with them added). Jellyfin sends both either way. The scan asked
 * for neither, so on Emby every title read as unrated:
 *   - SAT MORNING CARTOONS (an allow-list of TV-Y, TV-Y7, TV-G and G, plus unrated) took a TV-MA
 *     cartoon, because an unrated title passes it;
 *   - VHS VAULT's 9 PM hold on R and NC-17 held nothing, and the WATERSHED switch none;
 *   - the channels with `ratingMin` (ALL TIME GREATS, 8.2 and over) saw no star rating.
 *
 * This runs the real loader, lifted out of plex-tuner.html the way roku/tests/gen-mediabrowser.mjs
 * lifts it, as an Emby sign-in, over a stub Emby that withholds both fields unless the request's
 * `Fields` names them, then the real channel filter and the page's own getTimeFilteredPool at 8 PM
 * and 9 PM. No browser, no network. Run: `npm run test:emby-ratings`.
 */
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import "./nostalgex-jellyfin-urls.js";
import "./nostalgex-daily-manifest.js";
import "./nostalgex-music-brainz.js";

const require = createRequire(import.meta.url);
const CF = require("./nostalgex-channel-filter.cjs");
globalThis.NostalgexChannelFilter = CF;
const root = fileURLToPath(new URL("../", import.meta.url));
const html = readFileSync(join(root, "plex-tuner.html"), "utf8");
const channels = JSON.parse(readFileSync(join(root, "channels.json"), "utf8")).channels;

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

async function scan(serve) {
  const requests = [];
  let result = null;
  const env = {
    fetch: async (url) => {
      requests.push(url.replace("http://server.invalid", ""));
      const r = serve(url);
      return { status: r.status, ok: r.status >= 200 && r.status < 300, json: async () => r.body };
    },
    NostalgexLibraryLoad: {
      show() {}, hide() {}, refreshStepRail() {}, async pulsePhase() {}, setPhase() {},
      isFirstLibraryLoad: () => false, state: {},
    },
    NostalgexMusicBrainz: globalThis.NostalgexMusicBrainz,
    finalizeLibraryWithMusicBrainz: async (items) => { result = items; return items; },
  };
  const body = [
    lift(html, "function pickBestVersion("),
    lift(html, "function formatDuration("),
    lift(html, "async function fetchJellyfinLibraryFromServer("),
    "return fetchJellyfinLibraryFromServer({ background: true });",
  ].join("\n");
  const run = new Function(
    "fetch", "globalThis", "plexServerUrl", "jellyfinUserId", "mediaBackend", "bundles", "enabledBundleIDs",
    "discoveredGenres", "jellyfinAuthHeader", "backendDisplayName", "adoptMediaBrowserKind",
    "finalizeLibraryWithMusicBrainz", "NostalgexJellyfinUrls", "CHANNELS", "switchChannel", "console",
    "NostalgexDailyManifest", "channelFilter",
    body,
  );
  const quiet = { log() {}, warn() {} };
  await run(
    env.fetch, { ...globalThis, ...env }, "http://server.invalid", "u", "emby", [], new Set(),
    {}, () => "", () => "Emby", () => {}, env.finalizeLibraryWithMusicBrainz, globalThis.NostalgexJellyfinUrls, [], () => {}, quiet,
    globalThis.NostalgexDailyManifest, () => CF,
  );
  return { items: result || [], requests };
}

// ── The page's own time filter, at a chosen hour ─────────────────────────────

function timeFiltered(pool, channel, hour, watershed) {
  class FixedHour extends Date { getHours() { return hour; } }
  const fn = new Function("Date", `${lift(html, "function getTimeFilteredPool(")}\nreturn getTimeFilteredPool;`)(FixedHour);
  return fn({ ...channel, itemPool: pool }, watershed).map((i) => i.ratingKey);
}

// ── A stub Emby 4.10 ─────────────────────────────────────────────────────────

const TICKS = (min) => min * 60 * 10000000;
const STREAMS = [
  { Type: "Video", Codec: "h264", Width: 1920, Height: 1080, Index: 0, IsDefault: true },
  { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true, DisplayTitle: "English AAC" },
];
// Stored rating and star rating; the answer leaves them out unless the request's Fields names them.
const row = (id, type, name, minutes, o) => ({
  Id: id, Name: name, Type: type, RunTimeTicks: TICKS(minutes), ProviderIds: {}, Studios: [],
  DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "", Genres: o.genres || ["Drama"], ProductionYear: o.year,
  MediaSources: [{ Id: `ms-${id}`, Container: "mp4", Bitrate: 6000000, MediaStreams: STREAMS }],
  _rating: o.rating, _stars: o.stars, ...(o.extra || {}),
});
const FILMS = [
  row("r1", "Movie", "Rated R One", 100, { year: 1986, rating: "R", stars: 7.0 }),
  row("r2", "Movie", "Rated R Two", 100, { year: 1988, rating: "R", stars: 6.5 }),
  row("r3", "Movie", "Rated R Three", 100, { year: 1991, rating: "R", stars: 6.0 }),
  row("p1", "Movie", "Family Film One", 100, { year: 1987, rating: "PG", stars: 6.8 }),
  row("p2", "Movie", "Family Film Two", 100, { year: 1990, rating: "PG", stars: 6.1 }),
  row("p3", "Movie", "Family Film Three", 100, { year: 1993, rating: "G", stars: 5.9 }),
  row("great", "Movie", "A Great Film", 100, { year: 1994, rating: "PG-13", stars: 8.6 }),
  row("poor", "Movie", "A Poor Film", 100, { year: 1995, rating: "PG-13", stars: 4.2 }),
];
const SERIES = [
  { Id: "toon", Name: "Toon Hour", Type: "Series", ProductionYear: 1995, Genres: ["Animation"], Studios: [], ProviderIds: {}, _rating: "TV-Y7", _stars: 7.0 },
  { Id: "adult", Name: "Late Night Toons", Type: "Series", ProductionYear: 1997, Genres: ["Animation"], Studios: [], ProviderIds: {}, _rating: "TV-MA", _stars: 8.0 },
];
const EPISODES = {
  toon: Array.from({ length: 3 }, (_, i) => ({ ...row(`toon-e${i}`, "Episode", `Toon ${i}`, 22, { year: 1995, genres: ["Animation"], rating: "TV-Y7", stars: 7.0 }), ParentIndexNumber: 1, IndexNumber: i + 1 })),
  adult: Array.from({ length: 3 }, (_, i) => ({ ...row(`adult-e${i}`, "Episode", `Late ${i}`, 22, { year: 1997, genres: ["Animation"], rating: "TV-MA", stars: 8.0 }), ParentIndexNumber: 1, IndexNumber: i + 1 })),
};
const VIEWS = [
  { Id: "lib-movies", Name: "Movies", CollectionType: "movies" },
  { Id: "lib-tv", Name: "Shows", CollectionType: "tvshows" },
];

function emby() {
  const answer = (rows, fields) => rows.map(({ _rating, _stars, ...r }) => {
    if (fields.includes("officialrating") && _rating) r.OfficialRating = _rating;
    if (fields.includes("communityrating") && _stars != null) r.CommunityRating = _stars;
    return r;
  });
  return (url) => {
    const u = new URL(url, "http://server.invalid");
    if (/\/Users\/[^/]+\/Views$/.test(u.pathname)) return { status: 200, body: { Items: VIEWS, TotalRecordCount: VIEWS.length } };
    if (u.pathname.endsWith("/UserViews")) return { status: 404, body: {} };   // Jellyfin's spelling: Emby answers 404
    if (u.pathname.endsWith("/Items")) {
      const parent = u.searchParams.get("ParentId");
      const asked = String(u.searchParams.get("IncludeItemTypes")).split(",");
      const fields = String(u.searchParams.get("Fields") || "").toLowerCase().split(",");
      const held = parent === "lib-movies" ? FILMS : parent === "lib-tv" ? SERIES : (EPISODES[parent] || []);
      const all = answer(held.filter((it) => asked.includes(it.Type)), fields);
      const start = Number(u.searchParams.get("StartIndex") || 0);
      const limit = Number(u.searchParams.get("Limit") || all.length);
      return { status: 200, body: { Items: all.slice(start, start + limit), TotalRecordCount: all.length } };
    }
    return { status: 404, body: {} };
  };
}

// ── The checks ───────────────────────────────────────────────────────────────

const { items, requests } = await scan(emby());
const byKey = Object.fromEntries(items.map((i) => [i.ratingKey, i]));
const opts = { backend: "emby", nowSec: 1730000000, exclusiveRules: [] };
const channel = (name) => channels.find((c) => c.name === name);
const poolOf = (name) => CF.filterPool(items, channel(name), opts).items;
const keysOf = (name) => poolOf(name).map((i) => i.ratingKey).sort();

const itemAsks = requests.filter((r) => r.includes("/Items"));
const fieldsOf = (r) => String(new URL(r, "http://x").searchParams.get("Fields")).split(",");
check("the scan's Fields name OfficialRating on every Items request (films, shows, episodes)",
  itemAsks.length > 0 && itemAsks.every((r) => fieldsOf(r).includes("OfficialRating")), `${itemAsks.filter((r) => !fieldsOf(r).includes("OfficialRating")).length} of ${itemAsks.length} lack it`);
check("the scan's Fields name CommunityRating on every Items request",
  itemAsks.length > 0 && itemAsks.every((r) => fieldsOf(r).includes("CommunityRating")), `${itemAsks.filter((r) => !fieldsOf(r).includes("CommunityRating")).length} of ${itemAsks.length} lack it`);

check("a film keeps its content rating (R) and star rating", byKey.r1 && byKey.r1.contentRating === "R" && byKey.r1.rating === 7, JSON.stringify(byKey.r1 && [byKey.r1.contentRating, byKey.r1.rating]));
check("an episode takes its show's rating (TV-MA)", byKey["adult-e0"] && byKey["adult-e0"].contentRating === "TV-MA", JSON.stringify(byKey["adult-e0"] && byKey["adult-e0"].contentRating));
check("an episode takes its show's star rating", byKey["toon-e0"] && byKey["toon-e0"].rating === 7, JSON.stringify(byKey["toon-e0"] && byKey["toon-e0"].rating));

const cartoons = keysOf("SAT MORNING CARTOONS");
check("SAT MORNING CARTOONS airs the TV-Y7 show", ["toon-e0", "toon-e1", "toon-e2"].every((k) => cartoons.includes(k)), JSON.stringify(cartoons));
check("SAT MORNING CARTOONS does not take the TV-MA show", !cartoons.some((k) => k.startsWith("adult-")), JSON.stringify(cartoons.filter((k) => k.startsWith("adult-"))));

const vhs = poolOf("VHS VAULT");
const vhs8pm = timeFiltered(vhs, channel("VHS VAULT"), 20, false);
const vhs9pm = timeFiltered(vhs, channel("VHS VAULT"), 21, false);
check("VHS VAULT holds its R films before 9 PM", vhs.length >= 4 && !vhs8pm.some((k) => k.startsWith("r")), JSON.stringify(vhs8pm));
check("VHS VAULT has its R films again at 9 PM", ["r1", "r2", "r3"].every((k) => vhs9pm.includes(k)), JSON.stringify(vhs9pm));

const flicks = poolOf("FLICKS");
check("WATERSHED on holds the R films on a channel with no hold of its own, before 9 PM",
  flicks.some((i) => i.contentRating === "R") && !timeFiltered(flicks, channel("FLICKS"), 20, true).some((k) => k.startsWith("r")));

const great = keysOf("ALL TIME GREATS");
check("ALL TIME GREATS (ratingMin 8.2) sees the 8.6 star film and not the 4.2 one", great.includes("great") && !great.includes("poor"), JSON.stringify(great));

if (failures.length) {
  console.error(`emby ratings smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`emby ratings smoke: ${passed} checks passed (ratings and star ratings reach the rules on Emby)`);
