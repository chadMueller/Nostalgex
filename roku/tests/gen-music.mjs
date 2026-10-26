// Music-video vectors (#73): upstream's own scripts/nostalgex-music-brainz.js
// (the web tuner's MusicBrainz and Deezer lookup, which mirrors the Apple TV's
// MusicEnrichmentService, MusicBrainzService and DeezerService) run over
// fixture titles, tags, Deezer genres and canned server answers, so the port's
// mapping, ranking, merging and whole lookup order answer as the web tuner's.
//
// The module talks to MusicBrainz with fetch and to Deezer by JSONP. Here both
// are fakes that answer from CANNED by a logical key (mb:search:<query>,
// mb:recording:<id>, dz:search:<q>, dz:album:<id>), and record the keys in
// the order asked. Its rate limits are set to 0 so the run is quick; the
// limits themselves are checked by hand-written cases in tests/MusicTests.brs.
//
// Rows are written in the Roku's cache shape (lowercase keys: title, artist,
// mbid, genres, year, useful, deezerchecked, deezerid) as canonical JSON.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { canon } from "./gen-enrichment.mjs";

const TAGS = [
  ["pop"], ["k-pop"], ["alternative rock"], ["indie rock", "rock"], ["hard rock"], ["classic rock"],
  ["country rock"], ["country"], ["hip hop", "gangsta rap"], ["rap"], ["rhythm and blues"], ["soul"],
  ["acoustic"], ["electronic", "house"], ["trance"], ["heavy metal"], ["punk rock"], ["folk"],
  ["latin pop"], ["reggaeton"], ["reggaetón"], ["funk"], ["disco"], ["synth-pop", "new wave"],
  ["Pop", "POP rock"], [], ["jazz"],
];
const DEEZER_GENRES = [
  ["Pop"], ["International Pop"], ["Indie Pop"], ["K-Pop"], ["J-Pop"], ["Latin Pop"], ["Rock"],
  ["Hard Rock"], ["Classic Rock"], ["Indie Rock"], ["Indie Rock/Rock pop"], ["Alternative"], ["Punk"],
  ["Metal"], ["Rap/Hip Hop"], ["R&B"], ["Soul & Funk"], ["Disco"], ["Dance"], ["Dancefloor"], ["Electro"],
  ["Dubstep"], ["Chill Out/Trip-Hop/Lounge"], ["Electro Pop/Electro Rock"], ["Techno/House"], ["Country"],
  ["Latin Music"], ["Brazilian Music"], ["Reggaeton"], ["Reggae"], ["Folk"], ["Jazz"], ["Blues"],
  ["Films/Games"], ["Pop", "Rock", "pop"], [],
];
const HITS = [
  [[{ id: 1, artist: { name: "Someone Else" } }, { id: 2, artist: { name: "The Cure" } }], "The Cure"],
  [[{ id: 1, artist: { name: "Someone Else" } }, { id: 2, artist: { name: "The Cure" } }], "Cure"],
  [[{ id: 1, artist: { name: "A" } }], ""],
  [[{ id: 1, artist: { name: "A" } }, { id: 2, artist: { name: "B" } }], "Zz"],
  [[{ id: 1, artist: { name: "AC/DC" } }, { id: 2, artist: { name: "ACDC tribute" } }], "AC/DC"],
  [[], "Anyone"],
];

// Recording search answers, for the ranking: [song, artist, year, recordings].
const RANKS = [
  ["Take On Me", "a-ha", 1985, [
    { id: "r1", title: "Take On Me (live)", score: 100, "artist-credit": [{ name: "a-ha" }], releases: [{ date: "1990-01-01" }] },
    { id: "r2", title: "Take On Me", score: 90, "artist-credit": [{ name: "a-ha" }], releases: [{ date: "1985-04-01" }] },
    { id: "r3", title: "Take On Me", score: 95, "artist-credit": [{ artist: { name: "Cover Band" } }] },
  ]],
  ["Song", null, null, [
    { id: "a", title: "Other", score: 60 },
    { id: "b", title: "Song Remix", score: 50 },
  ]],
  ["Hello", "Adele", 2015, [
    { id: "x", title: "Hello", score: 100, "artist-credit": [{ name: "Lionel Richie" }], releases: [{ date: "1984" }] },
    { id: "y", title: "Hello", score: 98, "artist-credit": [{ name: "Adele" }], releases: [{ date: "2016-01-01" }] },
    { id: "z", title: "", score: 100 },
  ]],
  ["Nothing", "Nobody", null, []],
];

const NOW_YEAR = new Date().getFullYear();
const ITEMS_APPLY = [
  [{ ratingKey: "1", title: "Take On Me (1985)", artist: null, genres: ["Music Video"], year: 1970, librarySource: "musicVideo", type: "movie" },
    { recordingTitle: "Take On Me", artist: "a-ha", genres: ["Pop"], releaseYear: 1985 }],
  [{ ratingKey: "2", title: "Thriller", artist: "Michael Jackson", genres: [], year: 2012, librarySource: "musicVideo", type: "movie" },
    { recordingTitle: " ", artist: null, genres: ["Pop", "Dance"], releaseYear: null }],
  [{ ratingKey: "3", title: "Episode", artist: null, genres: [], year: 1990, librarySource: "musicVideo", type: "episode" },
    { recordingTitle: "X", artist: "Y", genres: ["Rock"], releaseYear: 1991 }],
  [{ ratingKey: "4", title: "Film", artist: null, genres: ["Drama"], year: 1999, librarySource: "movie", type: "movie" },
    { recordingTitle: "X", artist: "Y", genres: ["Rock"], releaseYear: 1991 }],
  [{ ratingKey: "5", title: "Song", artist: "Band", genres: ["rock"], year: "", librarySource: "musicVideo", type: "movie" },
    { recordingTitle: "Song", artist: null, genres: ["Rock", "Pop"], releaseYear: 1979 }],
];
const ITEMS_NOCACHE = [
  { ratingKey: "6", title: "Old Song (1977)", artist: "Band", genres: [], year: 2015, librarySource: "musicVideo", type: "movie" },
  { ratingKey: "7", title: "Plain", artist: "Band", genres: [], year: 1970, librarySource: "musicVideo", type: "movie" },
  { ratingKey: "8", title: "Plain Two", artist: "Band", genres: [], year: 1994, librarySource: "musicVideo", type: "movie" },
  { ratingKey: "9", title: "Film", genres: [], year: 1970, librarySource: "movie", type: "movie" },
];

// A whole lookup pass: the library's music videos, a cache to start from,
// and canned answers. Every case starts from an empty request log.
const PASSES = [
  {
    name: "musicbrainz names and tags it",
    items: [{ ratingKey: "10", title: "Take On Me", artist: "a-ha", genres: ["Music Video"], year: 1985, librarySource: "musicVideo", type: "movie" }],
    cache: {},
    canned: {
      'mb:search:recording:"Take On Me" AND video:true AND artist:"a-ha"': { recordings: [{ id: "m1", title: "Take On Me", score: 100, "artist-credit": [{ name: "a-ha" }], releases: [{ date: "1985-04-01" }] }] },
      "mb:recording:m1": { title: "Take On Me", "artist-credit": [{ name: "a-ha" }], tags: [{ name: "synth-pop" }, { name: "new wave" }], releases: [{ date: "1985-04-01" }] },
    },
  },
  {
    name: "musicbrainz has no genre, deezer fills it",
    items: [{ ratingKey: "11", title: "Song", artist: "Band", genres: [], year: 1990, librarySource: "musicVideo", type: "movie" }],
    cache: {},
    canned: {
      'mb:search:recording:"Song" AND video:true AND artist:"Band"': { recordings: [{ id: "m2", title: "Song", score: 80, "artist-credit": [{ name: "Band" }] }] },
      "mb:recording:m2": { title: "Song", "artist-credit": [{ name: "Band" }], tags: [] },
      "dz:search:Band Song": { data: [{ id: 501, title: "Song", artist: { name: "Band" }, album: { id: 77 } }] },
      "dz:album:77": { genres: { data: [{ name: "Rock" }, { name: "Alternative" }] }, release_date: "2003-05-01" },
    },
  },
  {
    name: "nothing anywhere: deezer asked once, the row kept",
    items: [{ ratingKey: "12", title: "Mystery - Track", artist: null, genres: ["Music"], year: "", librarySource: "musicVideo", type: "movie" }],
    cache: {},
    canned: {},
  },
  {
    name: "musicbrainz lookup fails, search hit stands",
    items: [{ ratingKey: "13", title: "Hello", artist: "Adele", genres: [], year: 2015, librarySource: "musicVideo", type: "movie" }],
    cache: {},
    canned: {
      'mb:search:recording:"Hello" AND video:true AND artist:"Adele"': { recordings: [{ id: "m3", title: "Hello", score: 100, "artist-credit": [{ name: "Adele" }], releases: [{ date: "2015-10-23" }] }] },
      "dz:search:Adele Hello": { data: [{ id: 601, title: "Hello", artist: { name: "Adele" }, album: { id: 88 } }] },
      "dz:album:88": { genres: { data: [{ name: "Pop" }] }, release_date: "2015-11-20" },
    },
  },
  {
    name: "settled rows and films are skipped",
    items: [
      { ratingKey: "14", title: "Done", artist: "A", genres: [], year: 1990, librarySource: "musicVideo", type: "movie" },
      { ratingKey: "15", title: "Checked", artist: "B", genres: [], year: 1990, librarySource: "musicVideo", type: "movie" },
      { ratingKey: "16", title: "Film", artist: null, genres: [], year: 1990, librarySource: "movie", type: "movie" },
      { ratingKey: "17", title: "Ep", artist: null, genres: [], year: 1990, librarySource: "musicVideo", type: "episode" },
    ],
    cache: {
      14: { title: "Done", artist: "A", mbid: "q", genres: ["Rock"], year: 1990, useful: true, deezerchecked: false },
      15: { title: "Checked", artist: "B", mbid: null, genres: [], year: null, useful: false, deezerchecked: true },
    },
    canned: {},
  },
  {
    name: "named but genreless: deezer only",
    items: [{ ratingKey: "18", title: "Named", artist: "C", genres: [], year: 1990, librarySource: "musicVideo", type: "movie" }],
    cache: { 18: { title: "Named Song", artist: "C", mbid: "n1", genres: [], year: 1991, useful: false, deezerchecked: false } },
    canned: {
      "dz:search:C Named Song": { data: [{ id: 701, title: "Named Song", artist: { name: "C" }, album: { id: 99 } }] },
      "dz:album:99": { genres: { data: [{ name: "Country" }] } },
    },
  },
  {
    name: "a named row: deezer only, even with server genres",
    items: [{ ratingKey: "19", title: "Has", artist: "D", genres: ["Rock"], year: 1990, librarySource: "musicVideo", type: "movie" }],
    cache: { 19: { title: "Has", artist: "D", mbid: null, genres: [], year: null, useful: false, deezerchecked: false } },
    canned: {},
  },
  {
    name: "deezer bare song after the artist query misses",
    items: [{ ratingKey: "20", title: "Lonely", artist: "E", genres: [], year: 2001, librarySource: "musicVideo", type: "movie" }],
    cache: {},
    canned: {
      "dz:search:E Lonely": { data: [] },
      "dz:search:Lonely": { data: [{ id: 801, title: "Lonely", artist: { name: "Someone" }, album: { id: 55 } }] },
      "dz:album:55": { genres: { data: [{ name: "R&B" }] } },
    },
  },
];

const toRoku = (r) => r ? ({
  title: r.recordingTitle ?? null, artist: r.artist ?? null, mbid: r.musicBrainzID ?? null,
  genres: r.genres || [], year: r.releaseYear ?? null, useful: !!r.hasUsefulGenres,
  deezerchecked: !!r.deezerCheckedAt, deezerid: r.deezerID ?? null,
}) : null;
const fromRoku = (r) => ({
  ratingKey: "x", recordingTitle: r.title, artist: r.artist, musicBrainzID: r.mbid, genres: r.genres,
  releaseYear: r.year, hasUsefulGenres: r.useful, deezerCheckedAt: r.deezerchecked ? Date.now() : undefined,
  deezerID: r.deezerid ?? undefined, fetchedAt: Date.now(),
});

function load(upstream) {
  let source = readFileSync(join(upstream, "scripts", "nostalgex-music-brainz.js"), "utf8");
  const swaps = [
    ["const MIN_INTERVAL_MS = 1050;", "const MIN_INTERVAL_MS = 0;"],
    ["const DEEZER_MIN_INTERVAL_MS = 250;", "const DEEZER_MIN_INTERVAL_MS = 0;"],
    ["  global.NostalgexMusicBrainz = {",
      "  global.__nxMusic = { deezerBestHit, usefulGenres, isSettled, needsOnlyGenres, mergeGenres, plexGenresAreThin, searchBestRecording, setCache: (c) => { cache = c; }, getCache: () => cache };\n  global.NostalgexMusicBrainz = {"],
    ["  function loadDiskCache() {", "  function loadDiskCache() { if (global.__nxKeepCache) return;"],
    ["  function saveDiskCache() {", "  function saveDiskCache() { return;"],
  ];
  for (const [a, b] of swaps) {
    if (!source.includes(a)) throw new Error(`upstream music module changed shape: no ${a}`);
    source = source.replace(a, b);
  }
  const scope = { __nxKeepCache: true, console: { warn() {}, log() {} } };
  const log = [];
  let canned = {};
  scope.fetch = async (url) => {
    const u = new URL(url);
    let key;
    if (u.pathname.endsWith("/recording")) key = `mb:search:${u.searchParams.get("query")}`;
    else key = `mb:recording:${u.pathname.split("/").pop()}`;
    log.push(key);
    const body = canned[key];
    return body ? { ok: true, status: 200, json: async () => body } : { ok: false, status: 503, json: async () => ({}) };
  };
  const head = { appendChild(script) {
    const u = new URL(script.src);
    const cb = u.searchParams.get("callback");
    const key = u.pathname === "/search" ? `dz:search:${u.searchParams.get("q")}` : `dz:album:${u.pathname.split("/").pop()}`;
    log.push(key);
    const body = canned[key];
    setTimeout(() => { if (body) scope[cb](body); else script.onerror(); }, 0);
  } };
  scope.document = { head, querySelector: () => null, createElement: () => ({ remove() {} }) };
  scope.setTimeout = setTimeout; scope.clearTimeout = clearTimeout;
  new Function("globalThis", "window", "document", "fetch", "setTimeout", "clearTimeout", "console", `${source.replace("(typeof globalThis !== 'undefined' ? globalThis : window)", "(globalThis)")}`)(
    scope, scope, scope.document, scope.fetch, setTimeout, clearTimeout, scope.console);
  return { MB: scope.NostalgexMusicBrainz, X: scope.__nxMusic, log, setCanned: (c) => { canned = c; log.length = 0; } };
}

export async function musicVectors(upstream) {
  const { MB, X, log, setCanned } = load(upstream);
  if (!MB || !X) throw new Error("upstream music module changed shape");
  const tags = TAGS.map((t) => ({ tags: t, want: canon(MB.mapTagsToChannelGenres(t)) }));
  const deezer = DEEZER_GENRES.map((g) => ({ genres: g, want: canon(MB.mapDeezerGenres(g)) }));
  const hits = HITS.map(([h, a]) => ({ hits: JSON.stringify(h), artist: a, want: canon(X.deezerBestHit(h, a) ? X.deezerBestHit(h, a).id : null) }));
  const ranks = [];
  for (const [song, artist, year, recordings] of RANKS) {
    const parts = [`recording:"${song}"`, "video:true"];
    if (artist) parts.push(`artist:"${artist}"`);
    setCanned({ [`mb:search:${parts.join(" AND ")}`]: { recordings } });
    const best = await X.searchBestRecording(song, artist, year);
    ranks.push({ song, artist, year, recordings: JSON.stringify(recordings), want: canon(best ? best.mbid : null) });
  }
  const years = [];
  for (const t of [null, 1985]) for (const mb of [null, 1990]) for (const p of [null, "", 1970, 1971, 1999, NOW_YEAR - 1, NOW_YEAR, "1988"]) {
    years.push({ title: t, mb, plex: p, want: canon(MB.resolveMusicYear(t, mb, p)) });
  }
  const titleYears = ["Song (1988)", "Song (2021) live", "Song 1988", "(1899) x", "A (19xx)", ""].map((s) => ({ title: s, want: canon(MB.yearInTitle(s)) }));
  const apply = ITEMS_APPLY.map(([item, enr]) => {
    const got = MB.applyEnrichmentToItem(item, enr);
    return { item: JSON.stringify(item), enr: JSON.stringify(toRoku(enr)), want: canon({ title: got.title, artist: got.artist ?? null, genres: got.genres, year: got.year }) };
  });
  const display = ITEMS_NOCACHE.map((item) => {
    const got = MB.itemsWithDisplayMetadata([item])[0];
    return { item: JSON.stringify(item), want: canon({ title: got.title, artist: got.artist ?? null, genres: got.genres, year: got.year }) };
  });
  const useful = [["Music Video"], ["Music"], ["musical"], ["Rock"], [], ["music video clip", "Pop"]].map((g) => ({ genres: g, want: X.usefulGenres(g) }));
  const merges = [[["Rock"], ["rock", "Pop"]], [[], ["A"]], [["A", "B"], []], [null, ["X"]]].map(([a, b]) => ({ a, b, want: canon(X.mergeGenres(a, b)) }));
  const passes = [];
  for (const p of PASSES) {
    const cache = {};
    for (const [k, v] of Object.entries(p.cache)) cache[k] = fromRoku(v);
    X.setCache(cache);
    setCanned(p.canned);
    await MB.enrichMusicVideos(p.items, () => {});
    const rows = {};
    const after = X.getCache();
    for (const k of Object.keys(after).sort()) rows[k] = toRoku(after[k]);
    passes.push({ name: p.name, items: JSON.stringify(p.items), cache: JSON.stringify(p.cache), canned: JSON.stringify(p.canned), requests: [...log], want: canon(rows) });
  }
  return { music: { nowYear: NOW_YEAR, tags, deezer, hits, ranks, years, titleYears, apply, display, useful, merges, passes } };
}
