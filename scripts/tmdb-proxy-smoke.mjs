#!/usr/bin/env node
/**
 * Smoke test for api/tmdb.js (TMDB and OMDb routes). Stubs fetch, so nothing reaches TMDB or OMDb.
 * Run: `npm run test:tmdb`.
 */
import handler, { upstreamRequest, corsHeaders, isOMDbLimit } from "../api/tmdb.js";

let pass = 0;
const failures = [];
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) pass++;
  else failures.push(`${name}: expected ${e}, got ${a}`);
}

/** Shape of an allowlist answer for comparison: path plus the query as a plain string. */
function shape(result) {
  return result ? { path: result.path, query: result.params.toString() } : null;
}

/** Canned TMDB response; records every upstream request. */
function stubTMDB(response) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), headers: init.headers });
    if (response instanceof Error) throw response;
    return {
      status: response.status,
      json: async () => {
        if (response.nonJSON) throw new SyntaxError("Unexpected token <");
        return response.body ?? {};
      },
    };
  };
  return calls;
}

const CLIENT_VALUES_OK = (r) => r.status !== 403;

async function call({ method = "GET", query = {}, headers = { "x-nostalgex-client": "tvos" } } = {}) {
  let status = 0;
  let json = null;
  const sent = {};
  const res = {
    setHeader(key, value) { sent[key] = value; },
    status(code) { status = code; return this; },
    json(data) { json = data; return this; },
    end() { return this; },
  };
  await handler({ method, query, headers }, res);
  return { status, json, headers: sent };
}

process.env.TMDB_API_KEY = "test_key";

// ---- Allowlist ----
check("movie adds keywords", shape(upstreamRequest({ path: "movie/603" })), {
  path: "/movie/603", query: "append_to_response=keywords",
});
check("tv adds keywords", shape(upstreamRequest({ path: "tv/1399" })), {
  path: "/tv/1399", query: "append_to_response=keywords",
});
check("collection has no keywords", shape(upstreamRequest({ path: "collection/404609" })), {
  path: "/collection/404609", query: "",
});
check("search collection forwards query", shape(upstreamRequest({ path: "search/collection", query: " John Wick " })), {
  path: "/search/collection", query: "query=John+Wick",
});
check("search collection forwards page", shape(upstreamRequest({ path: "search/collection", query: "Alien", page: "2" })), {
  path: "/search/collection", query: "query=Alien&page=2",
});
check("search without query rejected", upstreamRequest({ path: "search/collection" }), null);
check("search with blank query rejected", upstreamRequest({ path: "search/collection", query: "   " }), null);
check("search with long query rejected", upstreamRequest({ path: "search/collection", query: "x".repeat(201) }), null);
check("search with bad page rejected", upstreamRequest({ path: "search/collection", query: "Alien", page: "0" }), null);
check("search with huge page rejected", upstreamRequest({ path: "search/collection", query: "Alien", page: "1001" }), null);
check("person rejected", upstreamRequest({ path: "person/1" }), null);
check("non-numeric id rejected", upstreamRequest({ path: "movie/abc" }), null);
check("sub-resource rejected", upstreamRequest({ path: "movie/603/credits" }), null);
check("traversal rejected", upstreamRequest({ path: "../movie/603" }), null);
check("leading slash rejected", upstreamRequest({ path: "/movie/603" }), null);
check("query injection rejected", upstreamRequest({ path: "movie/603?api_key=x" }), null);
check("oversized id rejected", upstreamRequest({ path: "movie/12345678901" }), null);
check("repeated path rejected", upstreamRequest({ path: ["movie/603", "tv/1"] }), null);
check("empty rejected", upstreamRequest({}), null);
check("undefined rejected", upstreamRequest(undefined), null);

// ---- Handler ----
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ method: "POST", query: { path: "movie/603" } });
  check("POST 405", r.status, 405);
  check("POST no upstream", calls.length, 0);
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "movie/603" }, headers: {} });
  check("missing client header 403", r.status, 403);
  check("missing client header no upstream", calls.length, 0);
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "movie/603" }, headers: { "x-nostalgex-client": "crawler" } });
  check("wrong client header 403", r.status, 403);
  check("wrong client header no upstream", calls.length, 0);
}
{
  // The Roku port is a native client: no Origin, so no CORS, just the client filter.
  const calls = stubTMDB({ status: 200, body: { id: 603 } });
  const r = await call({ query: { path: "movie/603" }, headers: { "x-nostalgex-client": "roku" } });
  check("roku client header 200", r.status, 200);
  check("roku client one upstream call", calls.length, 1);
  check("roku client needs no allow-origin", r.headers["Access-Control-Allow-Origin"], undefined);
}
{
  // So is the Android TV port (OkHttp).
  const calls = stubTMDB({ status: 200, body: { id: 603 } });
  const r = await call({ query: { path: "movie/603" }, headers: { "x-nostalgex-client": "android" } });
  check("android client header 200", r.status, 200);
  check("android client one upstream call", calls.length, 1);
  check("android client needs no allow-origin", r.headers["Access-Control-Allow-Origin"], undefined);
}
{
  const calls = stubTMDB({ status: 200, body: { id: 603 } });
  const r = await call({ query: { path: "movie/603" }, headers: { "x-nostalgex-client": "web" } });
  check("web client header 200", r.status, 200);
  check("web client one upstream call", calls.length, 1);
  check("web client cached at the edge", r.headers["Cache-Control"], "public, s-maxage=86400, stale-while-revalidate=604800");
}

// ---- CORS ----
for (const origin of ["https://www.nostalgex.app", "https://nostalgex.app", "http://localhost:5173"]) {
  check(`cors echoes ${origin}`, corsHeaders(origin)["Access-Control-Allow-Origin"], origin);
}
for (const origin of ["https://evil.example", "http://localhost:3000", "https://nostalgex.app.evil.example", "null", "", undefined]) {
  check(`cors refuses ${origin}`, corsHeaders(origin)["Access-Control-Allow-Origin"], undefined);
  check(`cors refuses ${origin} headers`, corsHeaders(origin)["Access-Control-Allow-Headers"], undefined);
}
check("cors vary always", corsHeaders(undefined).Vary, "Origin, X-Nostalgex-Client");
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ method: "OPTIONS", query: { path: "movie/603" }, headers: { origin: "http://localhost:5173" } });
  check("preflight 204", r.status, 204);
  check("preflight no upstream", calls.length, 0);
  check("preflight allow origin", r.headers["Access-Control-Allow-Origin"], "http://localhost:5173");
  check("preflight allow headers", r.headers["Access-Control-Allow-Headers"], "X-Nostalgex-Client");
  check("preflight allow methods", r.headers["Access-Control-Allow-Methods"], "GET, OPTIONS");
  check("preflight vary", r.headers.Vary, "Origin, X-Nostalgex-Client");
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ method: "OPTIONS", query: { path: "movie/603" }, headers: { origin: "https://evil.example" } });
  check("foreign preflight 204", r.status, 204);
  check("foreign preflight no allow origin", r.headers["Access-Control-Allow-Origin"], undefined);
  check("foreign preflight no upstream", calls.length, 0);
}
{
  stubTMDB({ status: 200, body: { id: 603 } });
  const r = await call({
    query: { path: "movie/603" },
    headers: { "x-nostalgex-client": "web", origin: "https://www.nostalgex.app" },
  });
  check("cors GET allow origin", r.headers["Access-Control-Allow-Origin"], "https://www.nostalgex.app");
  check("cors GET vary", r.headers.Vary, "Origin, X-Nostalgex-Client");
}
{
  stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "movie/603" }, headers: { origin: "http://localhost:5173" } });
  check("cors 403 still readable", r.headers["Access-Control-Allow-Origin"], "http://localhost:5173");
  check("cors 403 status", r.status, 403);
}
{
  stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "movie/603" }, headers: { "x-nostalgex-client": "tvos" } });
  check("tvos no origin no allow origin", r.headers["Access-Control-Allow-Origin"], undefined);
  check("tvos no origin still varies", r.headers.Vary, "Origin, X-Nostalgex-Client");
}
// ---- Self-hosted tuners: any http(s) origin, `selfhost` client ----
{
  const lan = "http://192.168.1.50:8080";
  check("selfhost header accepted", CLIENT_VALUES_OK(await call({ query: { path: "movie/603" }, headers: { "x-nostalgex-client": "selfhost" } })), true);
  for (const origin of [lan, "http://nas.local:8080", "https://tuner.example.com", "http://[fd00::5]:8080"]) {
    check(`selfhost cors echoes ${origin}`, corsHeaders(origin, { client: "selfhost" })["Access-Control-Allow-Origin"], origin);
  }
  for (const origin of ["null", "", undefined, "file://", "http://192.168.1.50:8080/path", "ftp://x"]) {
    check(`selfhost cors refuses ${origin}`, corsHeaders(origin, { client: "selfhost" })["Access-Control-Allow-Origin"], undefined);
  }
  check("web client from a LAN origin still refused", corsHeaders(lan, { client: "web" })["Access-Control-Allow-Origin"], undefined);
  check("tvos client from a LAN origin still refused", corsHeaders(lan, { client: "tvos" })["Access-Control-Allow-Origin"], undefined);
  check("no client from a LAN origin refused", corsHeaders(lan)["Access-Control-Allow-Origin"], undefined);
  check("selfhost vary unchanged", corsHeaders(lan, { client: "selfhost" }).Vary, "Origin, X-Nostalgex-Client");
  check("listed origin unchanged", corsHeaders("https://www.nostalgex.app", { client: "web" })["Access-Control-Allow-Origin"], "https://www.nostalgex.app");
}
{
  // Preflight from a LAN origin: the value is not visible yet, only the header name.
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({
    method: "OPTIONS", query: { path: "movie/603" },
    headers: { origin: "http://192.168.1.50:8080", "access-control-request-headers": "x-nostalgex-client" },
  });
  check("selfhost preflight 204", r.status, 204);
  check("selfhost preflight allow origin", r.headers["Access-Control-Allow-Origin"], "http://192.168.1.50:8080");
  check("selfhost preflight allow headers", r.headers["Access-Control-Allow-Headers"], "X-Nostalgex-Client");
  check("selfhost preflight no upstream", calls.length, 0);
}
{
  const r = await call({
    method: "OPTIONS", query: { path: "movie/603" },
    headers: { origin: "http://192.168.1.50:8080", "access-control-request-headers": "authorization" },
  });
  check("preflight for another header refused", r.headers["Access-Control-Allow-Origin"], undefined);
}
{
  // A GET can't borrow the preflight rule: the header name on a GET means nothing.
  stubTMDB({ status: 200, body: {} });
  const r = await call({
    query: { path: "movie/603" },
    headers: { origin: "http://192.168.1.50:8080", "x-nostalgex-client": "web", "access-control-request-headers": "x-nostalgex-client" },
  });
  check("LAN GET as web not readable", r.headers["Access-Control-Allow-Origin"], undefined);
}
{
  const calls = stubTMDB({ status: 200, body: { id: 603 } });
  const r = await call({ query: { path: "movie/603" }, headers: { origin: "http://192.168.1.50:8080", "x-nostalgex-client": "selfhost" } });
  check("selfhost GET 200", r.status, 200);
  check("selfhost GET readable", r.headers["Access-Control-Allow-Origin"], "http://192.168.1.50:8080");
  check("selfhost GET same edge cache", r.headers["Cache-Control"], "public, s-maxage=86400, stale-while-revalidate=604800");
  check("selfhost GET one upstream", calls.length, 1);
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "person/1" }, headers: { origin: "http://192.168.1.50:8080", "x-nostalgex-client": "selfhost" } });
  check("selfhost path allowlist 400", r.status, 400);
  check("selfhost path allowlist no upstream", calls.length, 0);
}
{
  process.env.OMDB_API_KEY = "omdb_key";
  const calls = stubTMDB({ status: 200, body: { Response: "True" } });
  const r = await call({ query: { path: "omdb/tt0133093" }, headers: { origin: "http://192.168.1.50:8080", "x-nostalgex-client": "selfhost" } });
  delete process.env.OMDB_API_KEY;
  check("selfhost omdb ok", r.status, 200);
  check("selfhost omdb readable", r.headers["Access-Control-Allow-Origin"], "http://192.168.1.50:8080");
  check("selfhost omdb upstream", calls.length, 1);
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "person/1" } });
  check("person 400", r.status, 400);
  check("person no upstream", calls.length, 0);
  check("person not cached", r.headers["Cache-Control"], undefined);
}
{
  delete process.env.TMDB_API_KEY;
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "movie/603" } });
  check("missing env 500", r.status, 500);
  check("missing env no upstream", calls.length, 0);
  process.env.TMDB_API_KEY = "test_key";
}
{
  const body = {
    id: 603,
    belongs_to_collection: { id: 2344, name: "The Matrix Collection" },
    keywords: { keywords: [{ id: 1, name: "artificial intelligence" }] },
  };
  const calls = stubTMDB({ status: 200, body });
  const r = await call({ query: { path: "movie/603" } });
  check("movie ok", r.status, 200);
  check("movie one upstream call", calls.length, 1);
  check("movie upstream url", calls[0].url, "https://api.themoviedb.org/3/movie/603?append_to_response=keywords&api_key=test_key");
  check("movie body passes through", r.json, body);
  check("movie cached at the edge", r.headers["Cache-Control"], "public, s-maxage=86400, stale-while-revalidate=604800");
}
{
  const calls = stubTMDB({ status: 200, body: { id: 404609, parts: [] } });
  const r = await call({ query: { path: "collection/404609" } });
  check("collection ok", r.status, 200);
  check("collection upstream url", calls[0].url, "https://api.themoviedb.org/3/collection/404609?api_key=test_key");
}
{
  const calls = stubTMDB({ status: 200, body: { results: [] } });
  await call({ query: { path: "search/collection", query: "John Wick", page: "2" } });
  check("search upstream url", calls[0].url, "https://api.themoviedb.org/3/search/collection?query=John+Wick&page=2&api_key=test_key");
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  await call({ query: { path: "movie/603", api_key: "attacker", language: "fr" } });
  check("extra query params dropped", calls[0].url, "https://api.themoviedb.org/3/movie/603?append_to_response=keywords&api_key=test_key");
}
{
  stubTMDB({ status: 404, body: { status_code: 34, status_message: "The resource you requested could not be found." } });
  const r = await call({ query: { path: "movie/999999999" } });
  check("upstream 404 passes through", r.status, 404);
  check("upstream 404 not cached", r.headers["Cache-Control"], "no-store");
}
{
  stubTMDB({ status: 429, body: { status_code: 25 } });
  const r = await call({ query: { path: "tv/1399" } });
  check("upstream 429 passes through", r.status, 429);
  check("upstream 429 not cached", r.headers["Cache-Control"], "no-store");
}
{
  stubTMDB({ status: 502, nonJSON: true });
  const r = await call({ query: { path: "movie/603" } });
  check("upstream non-JSON 502", r.status, 502);
  check("upstream non-JSON not cached", r.headers["Cache-Control"], "no-store");
}
{
  stubTMDB(new Error("network down"));
  const r = await call({ query: { path: "movie/603" } });
  check("network error 502", r.status, 502);
  check("network error not cached", r.headers["Cache-Control"], "no-store");
}

// ---- OMDb route ----
process.env.OMDB_API_KEY = "omdb_key";
const OMDB_CACHE = "public, s-maxage=604800, stale-while-revalidate=2592000";
check("omdb route", shape(upstreamRequest({ path: "omdb/tt0133093" })), { path: "", query: "i=tt0133093" });
check("omdb route service", upstreamRequest({ path: "omdb/tt0133093" }).service, "omdb");
check("tmdb route service", upstreamRequest({ path: "movie/603" }).service, "tmdb");
check("omdb 9 digit id", shape(upstreamRequest({ path: "omdb/tt123456789" })), { path: "", query: "i=tt123456789" });
check("omdb 6 digit id rejected", upstreamRequest({ path: "omdb/tt123456" }), null);
check("omdb 10 digit id rejected", upstreamRequest({ path: "omdb/tt1234567890" }), null);
check("omdb without tt rejected", upstreamRequest({ path: "omdb/0133093" }), null);
check("omdb uppercase rejected", upstreamRequest({ path: "omdb/TT0133093" }), null);
check("omdb title search rejected", upstreamRequest({ path: "omdb/matrix" }), null);
check("omdb query injection rejected", upstreamRequest({ path: "omdb/tt0133093&apikey=x" }), null);
check("omdb sub-path rejected", upstreamRequest({ path: "omdb/tt0133093/x" }), null);
check("omdb bare rejected", upstreamRequest({ path: "omdb" }), null);
{
  const body = { Title: "The Matrix", imdbRating: "8.7", imdbVotes: "2,200,000", Response: "True" };
  const calls = stubTMDB({ status: 200, body });
  const r = await call({ query: { path: "omdb/tt0133093", apikey: "attacker", t: "x" } });
  check("omdb ok", r.status, 200);
  check("omdb one upstream call", calls.length, 1);
  check("omdb upstream url", calls[0].url, "https://www.omdbapi.com/?i=tt0133093&apikey=omdb_key");
  check("omdb body passes through", r.json, body);
  check("omdb cached a week", r.headers["Cache-Control"], OMDB_CACHE);
  check("omdb vary", r.headers.Vary, "Origin, X-Nostalgex-Client");
}
{
  const calls = stubTMDB({ status: 200, body: { Response: "True" } });
  const r = await call({ query: { path: "omdb/tt0133093" }, headers: { "x-nostalgex-client": "web", origin: "https://nostalgex.app" } });
  check("omdb web client ok", r.status, 200);
  check("omdb web cors", r.headers["Access-Control-Allow-Origin"], "https://nostalgex.app");
  check("omdb web upstream", calls.length, 1);
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "omdb/tt0133093" }, headers: {} });
  check("omdb missing client header 403", r.status, 403);
  check("omdb missing client header no upstream", calls.length, 0);
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ method: "OPTIONS", query: { path: "omdb/tt0133093" }, headers: { origin: "http://localhost:5173" } });
  check("omdb preflight 204", r.status, 204);
  check("omdb preflight no upstream", calls.length, 0);
}
{
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "omdb/tt12" } });
  check("omdb bad id 400", r.status, 400);
  check("omdb bad id no upstream", calls.length, 0);
}
{
  stubTMDB({ status: 401, body: { Response: "False", Error: "Request limit reached!" } });
  const r = await call({ query: { path: "omdb/tt0133093" } });
  check("omdb limit becomes 429", r.status, 429);
  check("omdb limit body", r.json, { Response: "False", Error: "Request limit reached!" });
  check("omdb limit not cached", r.headers["Cache-Control"], "no-store");
}
{
  stubTMDB({ status: 200, body: { Response: "False", Error: "Request limit reached!" } });
  const r = await call({ query: { path: "omdb/tt0133093" } });
  check("omdb limit on a 200 still 429", r.status, 429);
}
{
  stubTMDB({ status: 401, body: { Response: "False", Error: "Invalid API key!" } });
  const r = await call({ query: { path: "omdb/tt0133093" } });
  check("omdb bad key passes through", r.status, 401);
  check("omdb bad key not cached", r.headers["Cache-Control"], "no-store");
}
{
  stubTMDB({ status: 200, body: { Response: "False", Error: "Incorrect IMDb ID." } });
  const r = await call({ query: { path: "omdb/tt9999999" } });
  check("omdb not found passes through", r.status, 200);
  check("omdb not found body", r.json.Error, "Incorrect IMDb ID.");
  check("omdb not found not cached", r.headers["Cache-Control"], "no-store");
}
{
  stubTMDB({ status: 503, nonJSON: true });
  const r = await call({ query: { path: "omdb/tt0133093" } });
  check("omdb non-JSON 502", r.status, 502);
  check("omdb non-JSON not cached", r.headers["Cache-Control"], "no-store");
}
{
  stubTMDB(new Error("network down"));
  const r = await call({ query: { path: "omdb/tt0133093" } });
  check("omdb network error 502", r.status, 502);
}
{
  delete process.env.OMDB_API_KEY;
  const calls = stubTMDB({ status: 200, body: {} });
  const r = await call({ query: { path: "omdb/tt0133093" } });
  check("omdb missing env 500", r.status, 500);
  check("omdb missing env no upstream", calls.length, 0);
  process.env.OMDB_API_KEY = "omdb_key";
}
{
  // The TMDB key never goes to OMDb, and the OMDb key never goes to TMDB.
  const calls = stubTMDB({ status: 200, body: {} });
  await call({ query: { path: "omdb/tt0133093" } });
  await call({ query: { path: "movie/603" } });
  check("omdb call carries no tmdb key", calls[0].url.includes("test_key"), false);
  check("tmdb call carries no omdb key", calls[1].url.includes("omdb_key"), false);
}
check("isOMDbLimit", [isOMDbLimit({ Error: "Request limit reached!" }), isOMDbLimit({ Error: "Invalid API key!" }), isOMDbLimit(null)], [true, false, false]);

if (failures.length) {
  console.error(`tmdb proxy smoke: ${failures.length} failed, ${pass} passed`);
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`tmdb proxy smoke: ${pass} passed`);
