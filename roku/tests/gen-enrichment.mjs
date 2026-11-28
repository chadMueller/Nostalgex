// Enrichment vectors: upstream's own scripts/nostalgex-enrichment.js run over
// fixture documents, so the port's parsers, row mapping, OMDb gates and quota
// clock answer exactly as the web tuner's. The orchestration (caches, relay,
// batching, OMDb budget) is checked by cases transcribed from upstream's
// scripts/nostalgex-enrichment-smoke.mjs in tests/EnrichmentTests.brs.
//
// Records are written as canonical JSON (keys sorted, non-integers to 7
// significant digits, non-ASCII escaped) so the BrightScript side can compare them as text.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export function canon(v) {
  if (v === null || v === undefined) return "null";
  if (Array.isArray(v)) return `[${v.map(canon).join(",")}]`;
  if (typeof v === "object") {
    return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(",")}}`;
  }
  if (typeof v === "number") return Number.isInteger(v) ? String(v) : String(Number(v.toPrecision(7)));
  if (typeof v === "boolean") return String(v);
  // Non-ASCII as \uXXXX, so neither side depends on how its JSON writer escapes.
  return JSON.stringify(String(v)).replace(/[\u007f-\uffff]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
}

const NOW = new Date("2026-10-11T12:00:00.000Z");

const TMDB_DOCS = [
  // Upstream's smoke fixtures.
  [{
    id: 603,
    belongs_to_collection: { id: 2344, name: "The Matrix Collection", poster_path: "/x.jpg" },
    genres: [{ id: 28, name: "Action" }, { id: 878, name: "Science Fiction" }],
    production_companies: [{ id: 79, name: "Village Roadshow Pictures" }, { id: 174, name: "Warner Bros. Pictures" }],
    keywords: { keywords: [{ id: 1, name: "artificial intelligence" }, { id: 2, name: "dystopia" }] },
  }, "603", null, "movie"],
  [{ id: 550, belongs_to_collection: null, keywords: { keywords: [{ name: "fight" }] } }, 550, null, "movie"],
  [{ keywords: { keywords: [{ name: "heist" }] } }, "1", null, "tv"],
  [{
    id: 1399,
    genres: [{ name: "Sci-Fi & Fantasy" }, { name: "Drama" }],
    networks: [{ id: 49, name: "HBO" }],
    production_companies: [{ name: "Revolution Sun Studios" }],
    keywords: { results: [{ id: 1, name: "based on novel or book" }, { id: 2, name: "dragon" }] },
  }, "1399", null, "tv"],
  [{ belongs_to_collection: { id: "12", name: 7 }, keywords: { keywords: [{ name: 3 }, { name: "ok" }] } }, "9", null, "movie"],
  [null, "9", null, "movie"],
  [{ imdb_id: "tt0133093" }, "603", null, "movie"],
  [{ imdb_id: "tt0133093" }, "603", "tt7654321", "movie"],
  [{ imdb_id: "" }, "603", null, "movie"],
  // Edges of the port's own: odd types where JSON allows them.
  [{ belongs_to_collection: { id: 12.5, name: "Half" } }, "2", null, "movie"],
  [{ belongs_to_collection: { id: 12.0, name: "Whole" } }, "2", null, "movie"],
  [{ belongs_to_collection: [1, 2] }, "2", null, "movie"],
  [{ belongs_to_collection: "Star Wars" }, "2", null, "movie"],
  [{ imdb_id: "tt123456" }, "3", null, "movie"],
  [{ imdb_id: "tt1234567890" }, "3", null, "movie"],
  [{ imdb_id: "tt12345678" }, "3", null, "movie"],
  [{ imdb_id: "TT1234567" }, "3", null, "movie"],
  [{ imdb_id: "tt1234567 " }, "3", null, "movie"],
  [{ imdb_id: 1234567 }, "3", null, "movie"],
  [{ imdb_id: "tt0000001" }, "3", null, "tv"],
  [{ keywords: [{ name: "flat" }] }, "4", null, "movie"],
  [{ keywords: { keywords: { name: "not a list" } } }, "4", null, "movie"],
  [{ keywords: { keywords: [null, { name: null }, {}, "plain", { name: "" }, { name: "Été" }] } }, "4", null, "movie"],
  [{ keywords: { results: [{ name: "tv only" }], keywords: [{ name: "movie only" }] } }, "4", null, "tv"],
  [{ genres: "Drama", networks: {}, production_companies: [{ name: "A" }, { name: "A" }] }, "5", null, "movie"],
  ["a string", "6", null, "movie"],
  [[1, 2], "6", null, "movie"],
];

const OMDB_DOCS = [
  {
    imdbRating: "8.7", imdbVotes: "2,213,456", Metascore: "73", Awards: "Won 4 Oscars.",
    Ratings: [{ Source: "Internet Movie Database", Value: "8.7/10" }, { Source: "Rotten Tomatoes", Value: "83%" }],
    Response: "True",
  },
  { imdbRating: "N/A", imdbVotes: "N/A", Metascore: "N/A", Awards: "N/A", Response: "True" },
  { Response: "False", Error: "Incorrect IMDb ID." },
  { Response: "False", Error: "Request limit reached!" },
  null,
  "text",
  {},
  { imdbRating: "", imdbVotes: "", Metascore: "", Awards: "" },
  { imdbRating: " 7.5 ", imdbVotes: " 1,234 ", Metascore: "07" },
  { imdbRating: "7.5x", imdbVotes: "1,2,3", Metascore: "-5" },
  { imdbRating: "1e1", imdbVotes: "0x10", Metascore: "Infinity" },
  { imdbRating: ".5", imdbVotes: "5.", Metascore: "+8" },
  { imdbRating: "-", imdbVotes: ",", Metascore: "1e400" },
  { imdbRating: 8.1, imdbVotes: 1000, Metascore: 50, Awards: 3 },
  { Ratings: [{ Source: "Rotten Tomatoes", Value: "N/A" }] },
  { Ratings: [{ Source: "Rotten Tomatoes", Value: " 9%" }] },
  { Ratings: [{ Source: "Rotten Tomatoes", Value: "83.5%" }] },
  { Ratings: [{ Source: "Rotten Tomatoes", Value: "-5%" }] },
  { Ratings: [{ Source: "Rotten Tomatoes", Value: "1%00" }] },
  { Ratings: [{ Source: "Rotten Tomatoes", Value: 83 }, { Source: "Rotten Tomatoes", Value: "70%" }] },
  { Ratings: [{ Source: "Rotten Tomatoes", Value: "60%" }, { Source: "Rotten Tomatoes", Value: "70%" }] },
  { Ratings: [null, { Source: "Metacritic", Value: "73/100" }] },
  { Ratings: { Source: "Rotten Tomatoes", Value: "60%" } },
  { Response: "True", Error: "limit reached anyway" },
  { Error: "Daily LIMIT REACHED" },
  { Error: 5 },
];

const SUPABASE_ROWS = [
  {
    tmdb_id: "1891", media_type: "movie", keywords: ["rebel"], networks: null,
    production_companies: ["Lucasfilm Ltd."], tmdb_genres: ["Adventure"], imdb_id: "tt0080684",
    imdb_rating: 8.7, imdb_votes: 1400000, rt_score: 95, metacritic_score: 82, awards: "Won 1 Oscar.",
    franchise_id: 10, franchise_name: "Star Wars Collection", fetched_at: "2026-04-08T01:45:56+00:00",
  },
  { tmdb_id: "1" },
  { tmdb_id: 77, media_type: "tv", fetched_at: "x" },
  { tmdb_id: null, media_type: "movie", fetched_at: "x" },
  { media_type: "movie", fetched_at: "x" },
  { tmdb_id: "5", media_type: 3, fetched_at: "x" },
  { tmdb_id: "5", media_type: "movie", keywords: ["a", 1, null, "b"], networks: "HBO", imdb_id: 5,
    imdb_rating: "8.1", imdb_votes: null, rt_score: 0, metacritic_score: 7.25, awards: 3,
    franchise_id: "10", franchise_name: 10, fetched_at: "y" },
  { tmdb_id: 0, media_type: "", fetched_at: "x" },
  null,
];

// A film and a show with one number are two items now (EnrichmentTests.brs holds that case with the port's own
// fixtures); no vector here repeats a number across types, so the file reads the same before and after the web
// engine's change to key by type and number.
const WORK_ITEMS = [
  [{ tmdbID: 1399, type: "episode" }, { tmdbID: "1399", type: "episode" }, { tmdbID: 603, type: "movie" },
    { tmdbID: null }, { tmdbID: "" }, { tmdbID: "12a" }, { tmdbID: "1 OR 1=1" }, null],
  [{ tmdbID: "12345678901" }, { tmdbID: "1234567890" }, { tmdbID: "0" }, { tmdbID: "007", type: "episode" },
    { tmdbID: 7 }, { tmdbID: -3 }, { tmdbID: 4.5 }, { tmdbID: " 8" }, { tmdbID: "9\n" }],
  [{ tmdbID: 10, type: "show" }, { tmdbID: 11, type: "season" }, { tmdbID: 12 }],
];

const MIDNIGHTS = ["2026-10-11T23:59:00Z", "2026-10-12T00:00:00Z", "2026-10-11T15:30:00Z",
  "2026-12-31T23:59:59Z", "2028-02-28T12:00:00Z", "2028-02-29T00:00:01Z"];

export function enrichmentVectors(upstream) {
  const source = readFileSync(join(upstream, "scripts", "nostalgex-enrichment.js"), "utf8");
  const scope = {};
  new Function("globalThis", "window", source)(scope, scope);
  const E = scope.NostalgexEnrichment;
  if (!E) throw new Error("upstream enrichment changed shape: no NostalgexEnrichment");
  const channels = JSON.parse(readFileSync(join(upstream, "channels.json"), "utf8")).channels;
  const quiet = console.warn;

  const tmdb = TMDB_DOCS.map(([doc, id, imdb, type]) => ({
    doc: JSON.stringify(doc), tmdbID: String(id), imdbID: imdb, mediaType: type,
    want: canon(E.parseTMDBResponse(doc, id, imdb, type, NOW)),
  }));
  const omdb = OMDB_DOCS.map((doc) => ({
    doc: JSON.stringify(doc), want: canon(E.parseOMDbResponse(doc)), limit: E.isOMDbLimit(doc),
  }));
  const rows = SUPABASE_ROWS.map((row) => {
    const e = E.fromSupabaseRow(row);
    return {
      row: JSON.stringify(row), want: canon(e),
      tmdbRow: e ? canon(E.toSupabaseRow(e)) : "null",
      omdbRow: e ? canon(E.toOMDbRow(e)) : "null",
    };
  });
  const work = WORK_ITEMS.map((items) => ({ items: JSON.stringify(items), want: canon(E.workItems(items)) }));

  // Gates from the shipped channels, and probes built from each gate's own
  // words, so every keyword and genre the port must recognise is asked about.
  const gates = E.omdbGates(channels);
  const gateCanon = canon(gates.map((g) => ({ mediaType: g.mediaType, keywords: [...g.keywords], genres: g.genres })));
  const probes = [];
  for (const g of gates) {
    for (const mt of ["movie", "tv"]) {
      for (const k of [...g.keywords].slice(0, 3)) probes.push([mt, [k.toUpperCase()], []]);
      for (const x of g.genres.slice(0, 3)) probes.push([mt, [], [`Dark ${x.toUpperCase()} Tales`]]);
    }
  }
  probes.push(["movie", [], []], ["movie", ["nothing at all"], ["Nothing"]], ["tv", [], ["Drama"]]);
  const candidates = probes.map(([mt, kw, gs]) => ({
    mediaType: mt, keywords: kw, genres: gs, want: E.isOMDbCandidate(mt, kw, gs, gates),
  }));

  const midnights = MIDNIGHTS.map((iso) => ({
    nowSec: Date.parse(iso) / 1000, want: E.nextUTCMidnight(Date.parse(iso)) / 1000,
  }));
  console.warn = quiet;
  return {
    fetchedAt: NOW.toISOString(), nowSec: NOW.getTime() / 1000,
    constants: {
      supabaseChunk: E.SUPABASE_CHUNK, relayConcurrency: E.RELAY_CONCURRENCY,
      cacheTtlSec: E.CACHE_TTL_MS / 1000, missTtlSec: E.MISS_TTL_MS / 1000,
      omdbPerLoad: E.OMDB_PER_LOAD, omdbConcurrency: E.OMDB_CONCURRENCY,
      tmdbColumns: E.TMDB_COLUMNS.join(","), omdbColumns: E.OMDB_COLUMNS.join(","),
    },
    tmdb, omdb, rows, work, gates: gateCanon, candidates, midnights,
  };
}
