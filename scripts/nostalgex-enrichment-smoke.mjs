#!/usr/bin/env node
/**
 * Smoke test for scripts/nostalgex-enrichment.js (the web tuner's TMDB enrichment).
 *
 * Guards parity with the Apple TV app: the TMDB document -> record parse mirrors
 * TMDBService.parseResponse, the Supabase read/upsert mirrors SupabaseService, and
 * the attached record is what scripts/nostalgex-channel-filter.cjs reads. Stubs
 * fetch, so nothing leaves the machine. Run: `npm run test:enrichment`.
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import "./nostalgex-enrichment.js";
const require = createRequire(import.meta.url);
const CF = require("./nostalgex-channel-filter.cjs");
const E = globalThis.NostalgexEnrichment;

let pass = 0;
const failures = [];
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) pass++;
  else failures.push(`${name}: expected ${e}, got ${a}`);
}

const NOW = new Date("2026-10-11T12:00:00.000Z");
const quiet = { log: console.log, warn: console.warn };
console.log = () => {};
console.warn = () => {};

// ---- parseTMDBResponse (TMDBService.parseResponse) ----
{
  const movie = {
    id: 603,
    belongs_to_collection: { id: 2344, name: "The Matrix Collection", poster_path: "/x.jpg" },
    genres: [{ id: 28, name: "Action" }, { id: 878, name: "Science Fiction" }],
    production_companies: [{ id: 79, name: "Village Roadshow Pictures" }, { id: 174, name: "Warner Bros. Pictures" }],
    keywords: { keywords: [{ id: 1, name: "artificial intelligence" }, { id: 2, name: "dystopia" }] },
  };
  const e = E.parseTMDBResponse(movie, "603", null, "movie", NOW);
  check("movie keywords from keywords.keywords", e.keywords, ["artificial intelligence", "dystopia"]);
  check("movie companies", e.productionCompanies, ["Village Roadshow Pictures", "Warner Bros. Pictures"]);
  check("movie genres", e.tmdbGenres, ["Action", "Science Fiction"]);
  check("movie networks empty", e.networks, []);
  check("movie franchise id", e.franchiseID, 2344);
  check("movie franchise name", e.franchiseName, "The Matrix Collection");
  check("movie omdb null", [e.imdbRating, e.imdbVotes, e.rottenTomatoesScore, e.metacriticScore, e.awards], [null, null, null, null, null]);
  check("movie ids", [e.tmdbID, e.imdbID, e.mediaType], ["603", null, "movie"]);
  check("movie fetchedAt", e.fetchedAt, NOW.toISOString());
}
{
  const movie = { id: 550, belongs_to_collection: null, keywords: { keywords: [{ name: "fight" }] } };
  const e = E.parseTMDBResponse(movie, 550, null, "movie", NOW);
  check("movie without collection: franchise null", [e.franchiseID, e.franchiseName], [null, null]);
  check("movie without collection: id stringified", e.tmdbID, "550");
}
{
  // A movie document read as tv (or the reverse) finds no keywords, exactly as Swift.
  const movie = { keywords: { keywords: [{ name: "heist" }] } };
  check("movie doc parsed as tv has no keywords", E.parseTMDBResponse(movie, "1", null, "tv", NOW).keywords, []);
}
{
  const tv = {
    id: 1399,
    genres: [{ name: "Sci-Fi & Fantasy" }, { name: "Drama" }],
    networks: [{ id: 49, name: "HBO" }],
    production_companies: [{ name: "Revolution Sun Studios" }],
    keywords: { results: [{ id: 1, name: "based on novel or book" }, { id: 2, name: "dragon" }] },
  };
  const e = E.parseTMDBResponse(tv, "1399", null, "tv", NOW);
  check("tv keywords from keywords.results", e.keywords, ["based on novel or book", "dragon"]);
  check("tv networks", e.networks, ["HBO"]);
  check("tv no franchise", [e.franchiseID, e.franchiseName], [null, null]);
  check("tv media type", e.mediaType, "tv");
}
{
  // Swift: `collection["id"] as? Int`. A string id is not an Int.
  const odd = { belongs_to_collection: { id: "12", name: 7 }, keywords: { keywords: [{ name: 3 }, { name: "ok" }] } };
  const e = E.parseTMDBResponse(odd, "9", null, "movie", NOW);
  check("non-int collection id dropped", e.franchiseID, null);
  check("non-string collection name dropped", e.franchiseName, null);
  check("non-string keyword dropped", e.keywords, ["ok"]);
  check("garbage document", E.parseTMDBResponse(null, "9", null, "movie", NOW).keywords, []);
}

// ---- Supabase row mapping ----
{
  const row = {
    tmdb_id: "1891", media_type: "movie", keywords: ["rebel"], networks: null,
    production_companies: ["Lucasfilm Ltd."], tmdb_genres: ["Adventure"], imdb_id: "tt0080684",
    imdb_rating: 8.7, imdb_votes: 1400000, rt_score: 95, metacritic_score: 82, awards: "Won 1 Oscar.",
    franchise_id: 10, franchise_name: "Star Wars Collection", fetched_at: "2026-04-08T01:45:56+00:00",
  };
  const e = E.fromSupabaseRow(row);
  check("row null array -> []", e.networks, []);
  check("row omdb fields", [e.imdbRating, e.imdbVotes, e.rottenTomatoesScore, e.metacriticScore, e.awards],
    [8.7, 1400000, 95, 82, "Won 1 Oscar."]);
  check("row franchise", [e.franchiseID, e.franchiseName], [10, "Star Wars Collection"]);
  check("row without media_type rejected", E.fromSupabaseRow({ tmdb_id: "1" }), null);

  const up = E.toSupabaseRow(e);
  check("upsert columns are TMDB only", Object.keys(up), E.TMDB_COLUMNS);
  check("upsert never carries imdb", "imdb_id" in up || "imdb_rating" in up, false);
}

// ---- The attached record is what the shared filter reads ----
{
  const spyGames = {
    id: 219, rules: {
      type: "movie", keywords: ["spy", "espionage"], keywordsRequireAnyGenre: ["Action", "Thriller"],
    },
  };
  const foreign = { id: 212, rules: { type: "movie", keywords: ["french cinema"], imdbRatingMin: 6.5, imdbVotesMin: 5000 } };
  const item = { title: "Spy Film", type: "movie", genres: ["Action"], duration: 100, tmdbID: 77, ratingKey: "1" };
  check("unenriched item misses SPY GAMES", Boolean(CF.itemPasses({ ...item }, spyGames)), false);
  const items = [item];
  const n = E.attach(items, new Map([["movie:77", E.parseTMDBResponse({ keywords: { keywords: [{ name: "Espionage" }] } }, "77", null, "movie", NOW)]]));
  check("attach count", n, 1);
  check("enriched item passes SPY GAMES", CF.itemPasses(items[0], spyGames).via, "keyword");
  check("enrichedValue reads keywords", CF.enrichedValue(items[0], "keywords"), ["Espionage"]);

  const fr = { title: "Amelie", type: "movie", genres: ["Comedy"], duration: 120, tmdbID: 194, ratingKey: "2" };
  E.attach([fr], new Map([["movie:194", E.fromSupabaseRow({ tmdb_id: "194", media_type: "movie", keywords: ["french cinema"], imdb_rating: 8.3, imdb_votes: 800000 })]]));
  check("OMDb row passes FOREIGN FILMS", Boolean(CF.itemPasses(fr, foreign)), true);
  const frNoOmdb = { ...fr, enrichment: undefined };
  E.attach([frNoOmdb], new Map([["movie:194", E.parseTMDBResponse({ keywords: { keywords: [{ name: "french cinema" }] } }, "194", null, "movie", NOW)]]));
  check("TMDB-only row still gated by OMDb (as on tvOS)", Boolean(CF.itemPasses(frNoOmdb, foreign)), false);
}

// ---- workItems: one per TMDB number AND type, junk ids skipped ----
{
  const w = E.workItems([
    { tmdbID: 1399, type: "episode" }, { tmdbID: "1399", type: "movie" }, { tmdbID: 1399, type: "episode" }, { tmdbID: 603, type: "movie" },
    { tmdbID: null }, { tmdbID: "" }, { tmdbID: "12a" }, { tmdbID: "1 OR 1=1" }, null,
  ]);
  check("workItems: a show and a film that share a number are two, the same type is one",
    w, [{ tmdbID: "1399", mediaType: "tv" }, { tmdbID: "1399", mediaType: "movie" }, { tmdbID: "603", mediaType: "movie" }]);
  check("record keys are type and number", [E.recordKey("tv", "1399"), E.recordKey("movie", 603), E.recordKey("anything", 1)], ["tv:1399", "movie:603", "movie:1"]);
}

// ---- Supabase batching ----
function stubFetch(handler) {
  const calls = [];
  const f = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    const r = await handler(String(url), init, calls.length);
    return { status: r.status, json: async () => r.body };
  };
  f.calls = calls;
  return f;
}
const cfg = { supabaseURL: "https://example.supabase.co", anonKey: "anon", relayURL: "https://nostalgex.app/api/tmdb" };
{
  const ids = Array.from({ length: 450 }, (_, i) => String(i + 1));
  const f = stubFetch(async (url) => {
    const m = url.match(/in\.\(([^)]*)\)/);
    const list = m[1].split(",");
    return { status: 200, body: list.filter((x) => Number(x) % 2 === 0).map((x) => ({ tmdb_id: x, media_type: "movie", keywords: [] })) };
  });
  const progress = [];
  const rows = await E.readSupabase(ids, cfg, f, (d, t) => progress.push(`${d}/${t}`));
  check("read: chunks of 200", f.calls.length, 3);
  check("read: chunk sizes", f.calls.map((c) => c.url.match(/in\.\(([^)]*)\)/)[1].split(",").length), [200, 200, 50]);
  check("read: url shape", f.calls[0].url.startsWith("https://example.supabase.co/rest/v1/media_enrichments?tmdb_id=in.(1,2,3,"), true);
  check("read: select all", f.calls[0].url.endsWith(")&select=*"), true);
  check("read: headers", f.calls[0].init.headers, { apikey: "anon", Authorization: "Bearer anon", "Content-Type": "application/json" });
  check("read: rows", rows.length, 225);
  check("read: progress", progress, ["1/3", "2/3", "3/3"]);
}
{
  const f = stubFetch(async (url, init, n) => (n === 2 ? { status: 500, body: {} } : { status: 200, body: [{ tmdb_id: "1", media_type: "movie" }] }));
  const rows = await E.readSupabase(Array.from({ length: 401 }, (_, i) => String(i)), cfg, f);
  check("read: failed chunk skipped, others kept", rows.length, 2);
}
{
  const records = Array.from({ length: 250 }, (_, i) => E.parseTMDBResponse({}, String(i), null, "movie", NOW));
  const f = stubFetch(async () => ({ status: 201, body: null }));
  const written = await E.upsertSupabase(records, cfg, f);
  check("upsert: chunks of 200", f.calls.map((c) => JSON.parse(c.init.body).length), [200, 50]);
  check("upsert: POST", f.calls[0].init.method, "POST");
  check("upsert: merge duplicates", f.calls[0].init.headers.Prefer, "resolution=merge-duplicates,return=minimal");
  check("upsert: columns pinned", f.calls[0].url,
    "https://example.supabase.co/rest/v1/media_enrichments?columns=tmdb_id,media_type,keywords,networks,production_companies,tmdb_genres,franchise_id,franchise_name,fetched_at");
  check("upsert: written", written, 250);
}

// ---- Relay request ----
{
  const f = stubFetch(async () => ({ status: 200, body: { id: 1 } }));
  await E.fetchRelay({ tmdbID: "1399", mediaType: "tv" }, cfg, f);
  await E.fetchRelay({ tmdbID: "603", mediaType: "movie" }, cfg, f);
  check("relay tv url", f.calls[0].url, "https://nostalgex.app/api/tmdb?path=tv/1399");
  check("relay movie url", f.calls[1].url, "https://nostalgex.app/api/tmdb?path=movie/603");
  check("relay client header", f.calls[0].init.headers["X-Nostalgex-Client"], "web");
}

// ---- Concurrency bound ----
{
  let active = 0;
  let peak = 0;
  await E.mapWithConcurrency(Array.from({ length: 40 }), 6, async () => {
    active++; peak = Math.max(peak, active);
    await new Promise((r) => setTimeout(r, 2));
    active--;
  });
  check("concurrency never above 6", peak, 6);
}

// ---- enrichLibrary end to end ----
function library() {
  return [
    { title: "A", type: "movie", tmdbID: 1 },
    { title: "B", type: "movie", tmdbID: 2 },
    { title: "Show", type: "episode", tmdbID: 3 },
    { title: "Show", type: "episode", tmdbID: 3 },
    { title: "Gone", type: "movie", tmdbID: 4 },
    { title: "Flaky", type: "movie", tmdbID: 5 },
    { title: "No id", type: "movie", tmdbID: null },
  ];
}
function backend() {
  return stubFetch(async (url, init) => {
    if (url.includes("/rest/v1/") && (!init.method || init.method === "GET")) {
      return { status: 200, body: [{ tmdb_id: "1", media_type: "movie", keywords: ["cached"] }] };
    }
    if (url.includes("/rest/v1/")) return { status: 201, body: null };
    if (url.endsWith("path=movie/2")) return { status: 200, body: { keywords: { keywords: [{ name: "fresh" }] } } };
    if (url.endsWith("path=tv/3")) return { status: 200, body: { keywords: { results: [{ name: "sitcom" }] }, networks: [{ name: "NBC" }] } };
    if (url.endsWith("path=movie/4")) return { status: 404, body: {} };
    return { status: 429, body: {} };
  });
}
{
  const cache = E.memoryCache();
  const items = library();
  const f = backend();
  let early = null;
  const { records, stats } = await E.enrichLibrary(items, {
    config: cfg, fetch: f, cache, now: () => NOW.getTime(),
    onCacheReady: (r) => { early = [...r.keys()]; },
  });
  check("e2e: stats", { ...stats, peak: undefined },
    { ids: 5, local: 0, supabase: 1, fetched: 2, misses: 1, failed: 1, upserted: 2 });
  check("e2e: early rebuild saw the cache hit only", early, ["movie:1"]);
  check("e2e: records are keyed by type and number", [...records.keys()].sort(), ["movie:1", "movie:2", "tv:3"]);
  check("e2e: attached to every episode", items.filter((i) => i.enrichment).map((i) => i.title), ["A", "B", "Show", "Show"]);
  check("e2e: tv parsed from results", items[2].enrichment.keywords, ["sitcom"]);
  const supa = f.calls.filter((c) => c.url.includes("/rest/v1/"));
  check("e2e: one read, one upsert", supa.map((c) => c.init.method || "GET"), ["GET", "POST"]);
  check("e2e: upsert carries the two fetched", JSON.parse(supa[1].init.body).map((r) => r.tmdb_id).sort(), ["2", "3"]);
  const sent = f.calls.map((c) => c.url).join(" ");
  check("e2e: only TMDB ids sent", /title|Show|Gone|tt\d/.test(sent), false);
  check("e2e: 404 cached as a miss", cache.rows.get("movie:4").record, null);
  check("e2e: 429 not cached", cache.rows.has("movie:5"), false);

  // Reload inside the TTL: nothing leaves the browser except the id that failed.
  const again = library();
  const f2 = backend();
  const second = await E.enrichLibrary(again, { config: cfg, fetch: f2, cache, now: () => NOW.getTime() + 3600000 });
  check("reload: local hits", second.stats.local, 3);
  check("reload: only the failed id goes out", f2.calls.map((c) => c.url.replace(/^https:\/\/[^/]+/, "")),
    ["/rest/v1/media_enrichments?tmdb_id=in.(5)&select=*", "/api/tmdb?path=movie/5"]);
  check("reload: attached from local", again[1].enrichment.keywords, ["fresh"]);

  // Past the TTL: asks Supabase again.
  const f3 = backend();
  await E.enrichLibrary(library(), { config: cfg, fetch: f3, cache, now: () => NOW.getTime() + E.CACHE_TTL_MS + 1 });
  check("expired: Supabase read again", f3.calls[0].url.includes("tmdb_id=in.(1,2,3,4,5)"), true);
}
// ---- A film and a show with one number: each is looked up under its own type ----
{
  const mixed = () => [
    { title: "Film", type: "movie", tmdbID: 1399, ratingKey: "f" },
    { title: "Show", type: "episode", tmdbID: 1399, ratingKey: "e1" },
    { title: "Show", type: "episode", tmdbID: 1399, ratingKey: "e2" },
  ];
  // The shared table answers BOTH rows for the one number (its key is (tmdb_id, media_type)).
  const both = stubFetch(async (url, init) => {
    if (url.includes("/rest/v1/") && (!init.method || init.method === "GET")) {
      return { status: 200, body: [
        { tmdb_id: "1399", media_type: "movie", keywords: ["a film keyword"], tmdb_genres: ["Drama"] },
        { tmdb_id: "1399", media_type: "tv", keywords: ["a show keyword"], tmdb_genres: ["Fantasy"] },
      ] };
    }
    return { status: 201, body: null };
  });
  const items = mixed();
  const r = await E.enrichLibrary(items, { config: cfg, fetch: both, cache: E.memoryCache(), now: () => NOW.getTime() });
  check("film and show: two work items, two records", [r.stats.ids, [...r.records.keys()].sort()], [2, ["movie:1399", "tv:1399"]]);
  check("film and show: the film gets the film's row, every episode the show's", items.map((i) => i.enrichment.keywords[0]), ["a film keyword", "a show keyword", "a show keyword"]);
  check("film and show: one Supabase read for the number", both.calls.filter((c) => c.url.includes("/rest/v1/")).map((c) => c.url.split("?")[1]), ["tmdb_id=in.(1399)&select=*"]);

  // Only the film's row is in the shared table: the show is NOT skipped for it, it goes to the relay as tv.
  const onlyFilm = stubFetch(async (url, init) => {
    if (url.includes("/rest/v1/") && (!init.method || init.method === "GET")) return { status: 200, body: [{ tmdb_id: "1399", media_type: "movie", keywords: ["a film keyword"] }] };
    if (url.includes("/rest/v1/")) return { status: 201, body: null };
    if (url.endsWith("path=tv/1399")) return { status: 200, body: { keywords: { results: [{ name: "from tmdb" }] } } };
    return { status: 500, body: {} };
  });
  const cache = E.memoryCache();
  const items2 = mixed();
  const r2 = await E.enrichLibrary(items2, { config: cfg, fetch: onlyFilm, cache, now: () => NOW.getTime() });
  check("film row stored: the show still asks the relay as tv", onlyFilm.calls.filter((c) => c.url.includes("/api/tmdb")).map((c) => c.url.replace(/^https:\/\/[^/]+/, "")), ["/api/tmdb?path=tv/1399"]);
  check("film row stored: each type has its own row", items2.map((i) => i.enrichment.keywords[0]), ["a film keyword", "from tmdb", "from tmdb"]);
  check("film row stored: only the show's fetch is saved back", JSON.parse(onlyFilm.calls.find((c) => c.init && c.init.method === "POST").init.body).map((x) => [x.tmdb_id, x.media_type]), [["1399", "tv"]]);
  check("film row stored: the local cache holds both under their own keys", [...cache.rows.keys()].sort(), ["movie:1399", "tv:1399"]);
  // A reload from that cache needs nothing.
  const quiet = stubFetch(async () => ({ status: 500, body: {} }));
  const items3 = mixed();
  const r3 = await E.enrichLibrary(items3, { config: cfg, fetch: quiet, cache, now: () => NOW.getTime() + 1000 });
  check("both cached: no request, both attached", [quiet.calls.length, r3.stats.local, items3.map((i) => i.enrichment.keywords[0])], [0, 2, ["a film keyword", "from tmdb", "from tmdb"]]);
  // A row of the wrong type for the number is not used for the other type.
  const wrong = stubFetch(async (url, init) => {
    if (url.includes("/rest/v1/") && (!init.method || init.method === "GET")) return { status: 200, body: [{ tmdb_id: "1399", media_type: "movie", keywords: ["film only"] }] };
    if (url.includes("/rest/v1/")) return { status: 201, body: null };
    return { status: 404, body: {} };
  });
  const showOnly = [{ title: "Show", type: "episode", tmdbID: 1399, ratingKey: "e1" }];
  await E.enrichLibrary(showOnly, { config: cfg, fetch: wrong, cache: E.memoryCache(), now: () => NOW.getTime() });
  check("a film's row never stands in for a show with the same number", showOnly[0].enrichment, undefined);
}
{
  const f = backend();
  const r = await E.enrichLibrary(library(), { config: { relayURL: "/api/tmdb", supabaseURL: "", anonKey: "" }, fetch: f });
  check("no config: skipped", r.skipped, true);
  check("no config: no requests", f.calls.length, 0);
}

// ---- Page config ----
{
  const doc = (vals) => ({
    querySelector: (sel) => {
      const name = sel.match(/name="([^"]+)"/)[1];
      return name in vals ? { getAttribute: () => vals[name] } : null;
    },
  });
  const unset = doc({ "nostalgex-supabase-url": "%VITE_SUPABASE_URL%", "nostalgex-supabase-anon-key": "%VITE_SUPABASE_ANON_KEY%" });
  check("unset Vite placeholders read as empty", E.configFromPage(unset, { hostname: "nostalgex.app" }),
    { supabaseURL: "", anonKey: "", relayURL: "/api/tmdb" });
  const set = doc({ "nostalgex-supabase-url": "https://x.supabase.co/", "nostalgex-supabase-anon-key": "k" });
  check("site uses same-origin relay", E.configFromPage(set, { hostname: "www.nostalgex.app" }).relayURL, "/api/tmdb");
  check("localhost uses nostalgex.app relay", E.configFromPage(set, { hostname: "localhost" }).relayURL, "https://nostalgex.app/api/tmdb");
  check("trailing slash trimmed", E.configFromPage(set, { hostname: "localhost" }).supabaseURL, "https://x.supabase.co");
  const over = doc({ "nostalgex-tmdb-relay": "http://localhost:3000/api/tmdb" });
  check("relay override", E.configFromPage(over, { hostname: "localhost" }).relayURL, "http://localhost:3000/api/tmdb");

  // Self-hosted: any LAN host, the www relay (the apex redirects, which breaks a
  // preflight), and the selfhost client value.
  const selfhost = doc({ "nostalgex-build": "selfhost", "nostalgex-supabase-url": "https://x.supabase.co", "nostalgex-supabase-anon-key": "k" });
  check("selfhost config", E.configFromPage(selfhost, { hostname: "192.168.1.50" }), {
    supabaseURL: "https://x.supabase.co", anonKey: "k",
    relayURL: "https://www.nostalgex.app/api/tmdb", clientValue: "selfhost", selfhost: true,
  });
  check("selfhost on localhost still uses www relay",
    E.configFromPage(selfhost, { hostname: "localhost" }).relayURL, "https://www.nostalgex.app/api/tmdb");
  check("hosted config has no client value", "clientValue" in E.configFromPage(set, { hostname: "www.nostalgex.app" }), false);
}

// ---- Self-host: config.json gate, fails closed ----
{
  const selfCfg = { ...cfg, selfhost: true, clientValue: "selfhost" };
  for (const [name, answer] of [
    ["off", { status: 200, body: { enrichment: false } }],
    ["missing", { status: 404, body: {} }],
    ["unreadable", new Error("network")],
    ["string true is not true", { status: 200, body: { enrichment: "true" } }],
  ]) {
    const f = stubFetch(async (url) => {
      if (url === "config.json") { if (answer instanceof Error) throw answer; return answer; }
      return { status: 200, body: [] };
    });
    const r = await E.enrichLibrary(library(), { config: selfCfg, fetch: f, cache: E.memoryCache(), now: () => NOW.getTime() });
    check(`selfhost ${name}: skipped`, r.skipped, true);
    check(`selfhost ${name}: only config.json asked`, f.calls.map((c) => c.url), ["config.json"]);
  }
  {
    const f = stubFetch(async (url, init) => {
      if (url === "config.json") return { status: 200, body: { enrichment: true } };
      if (url.includes("/rest/v1/")) return (!init.method || init.method === "GET") ? { status: 200, body: [] } : { status: 201, body: null };
      return { status: 200, body: { keywords: { keywords: [{ name: "k" }] } } };
    });
    const r = await E.enrichLibrary(library(), { config: selfCfg, fetch: f, cache: E.memoryCache(), now: () => NOW.getTime() });
    check("selfhost on: runs", r.skipped, undefined);
    check("selfhost on: config.json asked first", f.calls[0].url, "config.json");
    const relay = f.calls.filter((c) => c.url.includes("path="));
    check("selfhost on: relay asked", relay.length, 5);
    check("selfhost on: relay calls carry selfhost", relay.every((c) => c.init.headers["X-Nostalgex-Client"] === "selfhost"), true);
  }
  {
    // The hosted page never asks for config.json.
    const f = backend();
    await E.enrichLibrary(library(), { config: cfg, fetch: f, cache: E.memoryCache(), now: () => NOW.getTime() });
    check("hosted: no config.json", f.calls.some((c) => c.url === "config.json"), false);
    check("hosted: relay calls carry web", f.calls.filter((c) => c.url.includes("path=")).every((c) => c.init.headers["X-Nostalgex-Client"] === "web"), true);
  }
}

// ---- OMDb: parse (OMDBService.parseResponse) ----
{
  const doc = {
    imdbRating: "8.7", imdbVotes: "2,213,456", Metascore: "73", Awards: "Won 4 Oscars.",
    Ratings: [{ Source: "Internet Movie Database", Value: "8.7/10" }, { Source: "Rotten Tomatoes", Value: "83%" }],
    Response: "True",
  };
  check("omdb parse", E.parseOMDbResponse(doc),
    { imdbRating: 8.7, imdbVotes: 2213456, rottenTomatoesScore: 83, metacriticScore: 73, awards: "Won 4 Oscars." });
  check("omdb N/A -> null", E.parseOMDbResponse({ imdbRating: "N/A", imdbVotes: "N/A", Metascore: "N/A", Awards: "N/A", Response: "True" }),
    { imdbRating: null, imdbVotes: null, rottenTomatoesScore: null, metacriticScore: null, awards: null });
  check("omdb Response False -> null", E.parseOMDbResponse({ Response: "False", Error: "Incorrect IMDb ID." }), null);
  check("omdb limit message", [E.isOMDbLimit({ Error: "Request limit reached!" }), E.isOMDbLimit({ Error: "Incorrect IMDb ID." })], [true, false]);
  const base = E.parseTMDBResponse({ keywords: { keywords: [{ name: "cult film" }] } }, "1", null, "movie", NOW);
  const merged = E.mergeOMDb(base, E.parseOMDbResponse(doc), "tt0133093");
  check("omdb merge keeps TMDB fields", merged.keywords, ["cult film"]);
  check("omdb merge fills imdb", [merged.imdbID, merged.imdbRating, merged.imdbVotes], ["tt0133093", 8.7, 2213456]);
  const row = E.toOMDbRow(merged);
  check("omdb upsert columns", Object.keys(row), E.OMDB_COLUMNS);
  check("omdb upsert never carries TMDB lists", "keywords" in row || "franchise_id" in row, false);
}

// ---- OMDb: the TMDB document supplies the IMDb id ----
{
  check("tmdb doc imdb_id used", E.parseTMDBResponse({ imdb_id: "tt0133093" }, "603", null, "movie", NOW).imdbID, "tt0133093");
  check("explicit imdb id wins", E.parseTMDBResponse({ imdb_id: "tt0133093" }, "603", "tt7654321", "movie", NOW).imdbID, "tt7654321");
  check("junk imdb_id ignored", E.parseTMDBResponse({ imdb_id: "" }, "603", null, "movie", NOW).imdbID, null);
}

// ---- OMDb: gates and candidates (OMDBGate / OMDBQuota) ----
const CHANNELS = [
  { id: 212, name: "FOREIGN FILMS", rules: { type: "movie", keywords: ["French Cinema", "subtitled"], imdbRatingMin: 6.5, imdbVotesMin: 5000 } },
  { id: 214, name: "CULT CLASSICS", rules: { type: "movie", keywords: ["cult film"], genres: { include: ["Horror"] }, imdbVotesMin: 30000 } },
  { id: 219, name: "SPY GAMES", rules: { type: "movie", keywords: ["spy"] } },
  { id: 1, name: "NO RULES" },
];
{
  const gates = E.omdbGates(CHANNELS);
  check("gates only from OMDb-ruled channels", gates.length, 2);
  check("gate media type", gates.map((g) => g.mediaType), ["movie", "movie"]);
  check("gate keywords lowercased", [...gates[0].keywords], ["french cinema", "subtitled"]);
  check("candidate by keyword", E.isOMDbCandidate("movie", ["Cult Film"], [], gates), true);
  check("candidate by genre substring", E.isOMDbCandidate("movie", [], ["Comedy Horror"], gates), true);
  check("wrong media type", E.isOMDbCandidate("tv", ["cult film"], [], gates), false);
  check("no keyword or genre", E.isOMDbCandidate("movie", ["spy"], ["Action"], gates), false);
  check("no gates", E.isOMDbCandidate("movie", ["cult film"], [], []), false);

  const real = E.omdbGates(JSON.parse(readFileSync(new URL("../channels.json", import.meta.url), "utf8")).channels);
  check("shipped channels.json gates CULT CLASSICS keywords", E.isOMDbCandidate("movie", ["cult film"], [], real), true);
  check("shipped channels.json gates FOREIGN FILMS keywords", E.isOMDbCandidate("movie", ["french cinema"], [], real), true);

  const rec = (id, extra) => ({ ...E.parseTMDBResponse({}, id, null, "movie", NOW), ...extra });
  const records = new Map([
    ["movie:1", rec("1", { imdbID: "tt0000001", keywords: ["cult film"] })],
    ["movie:2", rec("2", { imdbID: "tt0000002", keywords: ["cult film"], imdbRating: 7.1 })],
    ["movie:3", rec("3", { keywords: ["cult film"] })],
    ["movie:4", rec("4", { imdbID: "tt0000004", keywords: ["romance"] })],
    ["movie:5", rec("5", { imdbID: "tt0000005" })],
  ]);
  const work = ["1", "2", "3", "4", "5", "6"].map((tmdbID) => ({ tmdbID, mediaType: "movie" }));
  const byID = E.genresByTMDB([{ tmdbID: 5, genres: ["Horror"] }, { tmdbID: 5, genres: ["Thriller"] }]);
  check("genresByTMDB merges, by type and number", [...byID.get("movie:5")], ["Horror", "Thriller"]);
  check("genresByTMDB: a show of the same number is another key", E.genresByTMDB([{ tmdbID: 5, type: "episode", genres: ["Drama"] }, { tmdbID: 5, genres: ["Horror"] }]).get("tv:5") instanceof Set, true);
  check("candidates: unrated, with id, gated (server genre counts)",
    E.omdbCandidates(work, records, byID, E.omdbGates(CHANNELS)).map((c) => c.tmdbID), ["1", "5"]);
}

// ---- OMDb: budget ----
{
  const list = Array.from({ length: 400 }, (_, i) => i);
  let seed = 7;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const picked = E.pickOMDbLookups(list, E.OMDB_PER_LOAD, rnd);
  check("pick limit is 50", E.OMDB_PER_LOAD, 50);
  check("pick 50", picked.length, 50);
  check("pick no repeats", new Set(picked).size, 50);
  check("pick random order", JSON.stringify(picked) === JSON.stringify(list.slice(0, 50)), false);
  check("pick fewer than limit returns all", E.pickOMDbLookups([1, 2, 3]).sort(), [1, 2, 3]);
  check("pick leaves input alone", list.slice(0, 3), [0, 1, 2]);

  check("next UTC midnight", new Date(E.nextUTCMidnight(Date.parse("2026-10-11T23:59:00Z"))).toISOString(), "2026-10-12T00:00:00.000Z");
  check("next UTC midnight at midnight", new Date(E.nextUTCMidnight(Date.parse("2026-10-12T00:00:00Z"))).toISOString(), "2026-10-13T00:00:00.000Z");

  const store = new Map();
  const storage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, v) };
  const b = E.omdbBackoff(storage);
  const hit = Date.parse("2026-10-11T15:30:00Z");
  check("backoff starts open", b.isBlocked(hit), false);
  b.mark(hit);
  check("backoff blocks after limit", b.isBlocked(hit), true);
  check("backoff holds to 23:59:59", b.isBlocked(Date.parse("2026-10-11T23:59:59Z")), true);
  check("backoff opens at UTC midnight", b.isBlocked(Date.parse("2026-10-12T00:00:00Z")), false);
  check("backoff persists", E.omdbBackoff(storage).isBlocked(hit), true);
  const throwing = { getItem() { throw new Error("blocked"); }, setItem() { throw new Error("blocked"); } };
  const tb = E.omdbBackoff(throwing);
  tb.mark(hit);
  check("backoff survives throwing storage", tb.isBlocked(hit), true);
}

// ---- OMDb: relay request ----
{
  const f = stubFetch(async () => ({ status: 200, body: { Response: "True" } }));
  await E.fetchOMDb("tt0133093", cfg, f);
  check("omdb relay url", f.calls[0].url, "https://nostalgex.app/api/tmdb?path=omdb/tt0133093");
  check("omdb relay client header", f.calls[0].init.headers["X-Nostalgex-Client"], "web");
  const bad = await E.fetchOMDb("tt12&apikey=x", cfg, f);
  check("omdb bad id never sent", [bad.status, f.calls.length], [400, 1]);
}

// ---- OMDb: enrichLibrary end to end ----
function omdbLibrary(n) {
  const items = [];
  for (let i = 1; i <= n; i++) items.push({ title: `Film ${i}`, type: "movie", tmdbID: i, genres: i % 2 ? ["Horror"] : ["Drama"] });
  return items;
}
function omdbBackend({ limitAfter = Infinity } = {}) {
  let omdbCalls = 0;
  return stubFetch(async (url, init) => {
    if (url.includes("/rest/v1/") && (!init.method || init.method === "GET")) {
      const ids = url.match(/in\.\(([^)]*)\)/)[1].split(",");
      // Shared cache has TMDB rows (with IMDb ids an Apple TV wrote) but no OMDb values.
      return { status: 200, body: ids.map((id) => ({ tmdb_id: id, media_type: "movie", imdb_id: `tt${id.padStart(7, "0")}`, keywords: [] })) };
    }
    if (url.includes("/rest/v1/")) return { status: 201, body: null };
    if (url.includes("path=omdb/")) {
      omdbCalls++;
      if (omdbCalls > limitAfter) return { status: 429, body: { Response: "False", Error: "Request limit reached!" } };
      return { status: 200, body: { imdbRating: "7.4", imdbVotes: "45,000", Response: "True" } };
    }
    return { status: 404, body: {} };
  });
}
{
  const store = new Map();
  const storage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, v) };
  const items = omdbLibrary(200);
  const f = omdbBackend();
  const { omdb, records } = await E.enrichLibrary(items, {
    config: cfg, fetch: f, now: () => NOW.getTime(), channels: CHANNELS, omdbBackoff: E.omdbBackoff(storage),
  });
  const asked = f.calls.filter((c) => c.url.includes("path=omdb/"));
  check("e2e omdb: only gated candidates (horror half)", omdb.candidates, 100);
  check("e2e omdb: capped at 50", asked.length, 50);
  check("e2e omdb: every ask is a candidate", asked.every((c) => Number(c.url.match(/tt(\d+)/)[1]) % 2 === 1), true);
  check("e2e omdb: found", omdb.fetched, 50);
  const ups = f.calls.filter((c) => c.init.method === "POST");
  check("e2e omdb: one OMDb upsert", ups.length, 1);
  check("e2e omdb: upsert pinned to OMDb columns", ups[0].url.endsWith(`columns=${E.OMDB_COLUMNS.join(",")}`), true);
  check("e2e omdb: upsert rows", JSON.parse(ups[0].init.body).length, 50);
  check("e2e omdb: votes parsed", JSON.parse(ups[0].init.body)[0].imdb_votes, 45000);
  const rated = items.filter((i) => i.enrichment && i.enrichment.imdbRating === 7.4);
  check("e2e omdb: attached", rated.length, 50);
  check("e2e omdb: rated items pass CULT CLASSICS votes gate", rated.every((i) => CF.itemPasses(i, CHANNELS[1])), true);
  check("e2e omdb: no titles sent", f.calls.some((c) => /Film/.test(c.url) || /Film/.test(c.init.body || "")), false);
  check("e2e omdb: records updated", [...records.values()].filter((r) => r.imdbRating != null).length, 50);
}
{
  const store = new Map();
  const storage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, v) };
  const backoff = E.omdbBackoff(storage);
  const f = omdbBackend({ limitAfter: 3 });
  const { omdb } = await E.enrichLibrary(omdbLibrary(200), {
    config: cfg, fetch: f, now: () => NOW.getTime(), channels: CHANNELS, omdbBackoff: backoff,
  });
  check("limit: flagged", omdb.limited, true);
  check("limit: stops asking (at most concurrency in flight)", f.calls.filter((c) => c.url.includes("path=omdb/")).length <= 3 + E.OMDB_CONCURRENCY, true);
  check("limit: blocked until UTC midnight", backoff.blockedUntil(), Date.parse("2026-10-12T00:00:00Z"));

  const f2 = omdbBackend();
  const second = await E.enrichLibrary(omdbLibrary(200), {
    config: cfg, fetch: f2, now: () => NOW.getTime() + 3600000, channels: CHANNELS, omdbBackoff: backoff,
  });
  check("limit: next load same day asks nothing", f2.calls.filter((c) => c.url.includes("path=omdb/")).length, 0);
  check("limit: reported paused", second.omdb.paused, true);
  const f3 = omdbBackend();
  await E.enrichLibrary(omdbLibrary(200), {
    config: cfg, fetch: f3, now: () => Date.parse("2026-10-12T00:00:01Z"), channels: CHANNELS, omdbBackoff: backoff,
  });
  check("limit: asks again after UTC midnight", f3.calls.filter((c) => c.url.includes("path=omdb/")).length, 50);
}
{
  const f = omdbBackend();
  const { omdb } = await E.enrichLibrary(omdbLibrary(20), { config: cfg, fetch: f, now: () => NOW.getTime() });
  check("no channels: no OMDb", [omdb.gates, f.calls.filter((c) => c.url.includes("path=omdb/")).length], [0, 0]);
}

console.log = quiet.log;
console.warn = quiet.warn;
if (failures.length) {
  console.error(`enrichment smoke: ${failures.length} failed, ${pass} passed`);
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`enrichment smoke: ${pass} passed`);
