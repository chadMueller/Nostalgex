#!/usr/bin/env node
/**
 * Only videos reach the guide from a Jellyfin or Emby library: a playlist, a song, an album, an
 * artist or a collection never becomes a programme (Discord report: a workout playlist of eight
 * songs aired on CH 07 VHS VAULT as a 33 minute film, and playing it answered HTTP 500).
 *
 * What went wrong. The scan treats every library view that is not TV or Music Videos as a movie
 * library and asks it for IncludeItemTypes=Movie. The Playlists view is such a view. Jellyfin's
 * PlaylistsFolder.GetItemsInternal (Emby.Server.Implementations/Playlists/PlaylistsFolder.cs)
 * overwrites the request with `Recursive = true; IncludeItemTypes = [Playlist]`, so the answer to
 * "Movie" under that view is the playlists. The loader labelled every row `type: 'movie'`, so a
 * playlist with no year and no genre passed every rule that only says "a movie" and "1980 to 1999
 * or no year" (passesYearRange lets an item with no year through): VHS VAULT, among others.
 *
 * This runs the real loader, lifted out of plex-tuner.html the way roku/tests/gen-mediabrowser.mjs
 * lifts it, over a stubbed Jellyfin that answers like the real one (Playlists view included), then
 * the real channel filter over every channel in channels.json. Two servers: one that answers as
 * Jellyfin does, and one that ignores IncludeItemTypes altogether, with a song, an album, an
 * artist, a playlist and a collection filed in every library. In both:
 *   - no playlist, song, album, artist or collection is in the scanned library or in any channel;
 *   - the films, the episodes and the music videos load exactly as before, and HIGH ROTATION
 *     still gets the music videos (I-067: a music video library is asked for Movie and MusicVideo);
 *   - the Playlists, Music and Collections views are not asked for items at all.
 *
 * No browser, no network. Run: `npm run test:jellyfin-library`.
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
const root = fileURLToPath(new URL("../", import.meta.url));
const html = readFileSync(join(root, "plex-tuner.html"), "utf8");
const channels = JSON.parse(readFileSync(join(root, "channels.json"), "utf8")).channels;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

// ── The loader, lifted out of the page ───────────────────────────────────────

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
    "NostalgexDailyManifest",
    body,
  );
  const quiet = { log() {}, warn() {} };
  await run(
    env.fetch, { ...globalThis, ...env }, "http://server.invalid", "u", "jellyfin", [], new Set(),
    {}, () => "", () => "Jellyfin", () => {}, env.finalizeLibraryWithMusicBrainz, globalThis.NostalgexJellyfinUrls, [], () => {}, quiet,
    globalThis.NostalgexDailyManifest,
  );
  return { items: result || [], requests };
}

// ── The server's library ─────────────────────────────────────────────────────

const TICKS = (min) => min * 60 * 10000000;
const STREAMS = [
  { Type: "Video", Codec: "h264", Width: 1920, Height: 1080, Index: 0, IsDefault: true },
  { Type: "Audio", Codec: "aac", Language: "eng", Channels: 2, Index: 1, IsDefault: true, DisplayTitle: "English AAC" },
];
const base = (id, type, name, minutes, extra = {}) => ({
  Id: id, Name: name, Type: type, RunTimeTicks: TICKS(minutes), ProviderIds: {}, Studios: [],
  DateCreated: "2020-01-01T00:00:00.0000000Z", Overview: "", ...extra,
});
const video = (id, type, name, minutes, extra = {}) => base(id, type, name, minutes, {
  ProductionYear: 1988, Genres: ["Drama"], OfficialRating: "PG", CommunityRating: 7,
  MediaSources: [{ Id: `ms-${id}`, Container: "mp4", Bitrate: 6000000, MediaStreams: STREAMS }], ...extra,
});

const FILMS = Array.from({ length: 6 }, (_, i) => video(`mv${i}`, "Movie", `Feature Film ${i}`, 100));
const CLIPS = [
  ...Array.from({ length: 4 }, (_, i) => video(`vid${i}`, "MusicVideo", `Artist ${i} - Song ${i}`, 4, { Genres: ["Pop"] })),
  video("vidm0", "Movie", "Old Artist - Old Song", 4, { Genres: ["Pop"] }),
];
const EPISODES = Array.from({ length: 4 }, (_, i) => ({ ...video(`ep${i}`, "Episode", `Pilot ${i}`, 45), ParentIndexNumber: 1, IndexNumber: i + 1 }));
const SERIES = [{ Id: "show1", Name: "Test Show", Type: "Series", ProductionYear: 1995, Genres: ["Drama"], Studios: [], ProviderIds: {}, OfficialRating: "TV-PG" }];

// What a Jellyfin library view holds that is not a video. The playlist is what the report shows:
// eight songs, 33 minutes, no year, no genre, no media source, filed under the Playlists view.
const PLAYLIST_AUDIO = base("pl-audio", "Playlist", "Workout Mix", 33, { MediaType: "Audio", IsFolder: true, ChildCount: 8 });
const PLAYLIST_VIDEO = base("pl-video", "Playlist", "Movie Night", 190, { MediaType: "Video", IsFolder: true, ChildCount: 2 });
const SONGS = Array.from({ length: 8 }, (_, i) => base(`song${i}`, "Audio", `Track ${i}`, 4, { ProductionYear: 1994, Genres: ["Rock"], MediaType: "Audio" }));
const ALBUM = base("album1", "MusicAlbum", "Some Album", 33, { ProductionYear: 1994, Genres: ["Rock"], IsFolder: true });
const ARTIST = base("artist1", "MusicArtist", "Some Artist", 0, { IsFolder: true });
const BOXSET = base("box1", "BoxSet", "Rocky Collection", 600, { ProductionYear: 1985, Genres: ["Drama"], IsFolder: true });
const NON_VIDEO_IDS = ["pl-audio", "pl-video", ...SONGS.map((s) => s.Id), "album1", "artist1", "box1"];

const VIEWS = [
  { Id: "lib-movies", Name: "Movies", CollectionType: "movies" },
  { Id: "lib-tv", Name: "Shows", CollectionType: "tvshows" },
  { Id: "lib-clips", Name: "Music Videos", CollectionType: "musicvideos" },
  { Id: "lib-music", Name: "Music", CollectionType: "music" },
  { Id: "lib-boxsets", Name: "Collections", CollectionType: "boxsets" },
  { Id: "lib-playlists", Name: "Playlists", CollectionType: "playlists" },
];

/**
 * A stubbed Jellyfin. `ignoresTypes`: answers every /Items with everything filed under the parent,
 * whatever IncludeItemTypes says, and files a song, an album, an artist, a playlist and a
 * collection in every library as well.
 */
function server({ ignoresTypes = false } = {}) {
  const junk = [SONGS[0], ALBUM, ARTIST, PLAYLIST_AUDIO, BOXSET];
  const held = {
    "lib-movies": [...FILMS, ...(ignoresTypes ? junk : [])],
    "lib-clips": [...CLIPS, ...(ignoresTypes ? junk : [])],
    "lib-music": [ALBUM, ...SONGS, ARTIST],
    "lib-boxsets": [BOXSET],
    "lib-playlists": [PLAYLIST_AUDIO, PLAYLIST_VIDEO],
    "lib-tv": ignoresTypes ? [...SERIES, PLAYLIST_AUDIO, ALBUM] : SERIES,
    show1: [...EPISODES, ...(ignoresTypes ? [SONGS[1], ALBUM] : [])],
    [PLAYLIST_AUDIO.Id]: SONGS,
    [ALBUM.Id]: SONGS,
  };
  return (url) => {
    const u = new URL(url, "http://server.invalid");
    if (u.pathname.endsWith("/UserViews") || /\/Users\/[^/]+\/Views$/.test(u.pathname)) {
      return { status: 200, body: { Items: VIEWS, TotalRecordCount: VIEWS.length } };
    }
    if (u.pathname.endsWith("/Items")) {
      const parent = u.searchParams.get("ParentId");
      const asked = String(u.searchParams.get("IncludeItemTypes")).split(",");
      let all;
      if (parent === "lib-playlists") {
        // PlaylistsFolder.GetItemsInternal: `query.Recursive = true; query.IncludeItemTypes = [Playlist];`
        all = held[parent];
      } else if (ignoresTypes) {
        all = held[parent] || [];
      } else {
        all = (held[parent] || []).filter((it) => asked.includes(it.Type));
      }
      const start = Number(u.searchParams.get("StartIndex") || 0);
      const limit = Number(u.searchParams.get("Limit") || all.length);
      return { status: 200, body: { Items: all.slice(start, start + limit), TotalRecordCount: all.length } };
    }
    return { status: 404, body: {} };
  };
}

// ── What the channel rules do with the scanned items ─────────────────────────

/** Names of the channels whose pool holds any of `ids`, by the real filter. */
function channelsHolding(items, ids) {
  const out = [];
  for (const ch of channels) {
    const pool = CF.filterPool(items, ch, { backend: "jellyfin", nowSec: 1730000000, exclusiveRules: [] }).items;
    if (pool.some((it) => ids.includes(it.ratingKey))) out.push(`CH ${ch.number} ${ch.name}`);
  }
  return out;
}
const poolOf = (items, name) => CF.filterPool(items, channels.find((c) => c.name === name), { backend: "jellyfin", nowSec: 1730000000, exclusiveRules: [] }).items.map((i) => i.ratingKey).sort();
const typesAsked = (requests, parent) => requests
  .filter((r) => r.includes("/Items") && new URL(r, "http://x").searchParams.get("ParentId") === parent)
  .map((r) => new URL(r, "http://x").searchParams.get("IncludeItemTypes").split(",").sort().join(","));

for (const [label, options] of [["server answers as Jellyfin does", {}], ["server ignores IncludeItemTypes", { ignoresTypes: true }]]) {
  const { items, requests } = await scan(server(options));
  const keys = items.map((i) => i.ratingKey);
  const tag = `${label}`;

  const leaked = NON_VIDEO_IDS.filter((id) => keys.includes(id));
  check(`${tag}: no playlist, song, album, artist or collection is in the scanned library`, leaked.length === 0, leaked.join(", "));
  const holders = channelsHolding(items, NON_VIDEO_IDS);
  check(`${tag}: none of them is in any channel's pool`, holders.length === 0, holders.join(", "));

  const films = items.filter((i) => FILMS.some((f) => f.Id === i.ratingKey));
  check(`${tag}: the six films load as films`, films.length === 6 && films.every((i) => i.type === "movie" && i.librarySource === "movie" && i.year === 1988 && i.duration === 100), JSON.stringify(films.map((i) => i.ratingKey)));
  check(`${tag}: VHS VAULT has the six films and nothing else`, JSON.stringify(poolOf(items, "VHS VAULT")) === JSON.stringify(FILMS.map((f) => f.Id).sort()), JSON.stringify(poolOf(items, "VHS VAULT")));
  const clips = items.filter((i) => i.librarySource === "musicVideo").map((i) => i.ratingKey).sort();
  check(`${tag}: the four MusicVideo items and the clip filed as a Movie load as music videos`, JSON.stringify(clips) === JSON.stringify(["vid0", "vid1", "vid2", "vid3", "vidm0"]), JSON.stringify(clips));
  const hr = poolOf(items, "HIGH ROTATION");
  check(`${tag}: HIGH ROTATION still gets the music videos`, ["vid0", "vid1", "vid2", "vid3"].every((k) => hr.includes(k)), JSON.stringify(hr));
  check(`${tag}: the four episodes load`, items.filter((i) => i.type === "episode").length === 4, String(items.filter((i) => i.type === "episode").length));
  check(`${tag}: nothing else is in the library`, items.length === 6 + 5 + 4, `${items.length} items: ${keys.join(", ")}`);

  const movies = typesAsked(requests, "lib-movies");
  check(`${tag}: Movies is asked for Movie and nothing else`, movies.length > 0 && movies.every((t) => t === "Movie"), JSON.stringify(movies));
  const clipAsk = typesAsked(requests, "lib-clips");
  check(`${tag}: Music Videos is asked for Movie and MusicVideo (I-067)`, clipAsk.length > 0 && clipAsk.every((t) => t === "Movie,MusicVideo"), JSON.stringify(clipAsk));
  const tv = [...typesAsked(requests, "lib-tv"), ...typesAsked(requests, "show1")];
  check(`${tag}: TV is asked for Series, then Episode`, JSON.stringify([...new Set(tv)].sort()) === JSON.stringify(["Episode", "Series"]), JSON.stringify(tv));
  for (const [view, name] of [["lib-playlists", "Playlists"], ["lib-music", "Music"], ["lib-boxsets", "Collections"]]) {
    const asked = typesAsked(requests, view);
    check(`${tag}: the ${name} view is not asked for items`, asked.length === 0, JSON.stringify(asked));
  }
}

if (failures.length) {
  console.error(`jellyfin library smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`jellyfin library smoke: ${passed} checks passed (playlists, songs, albums, artists and collections stay out; films, episodes and music videos load as before)`);
