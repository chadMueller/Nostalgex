#!/usr/bin/env node
/**
 * Smoke test for api/weather.js, the forecast relay. Stubs fetch and the clock, so nothing reaches MET Norway.
 * Checks MET's rules as the relay keeps them: the identifying User-Agent, rounded coordinates, nothing asked
 * before Expires, If-Modified-Since after it (and a 304 renewing the kept answer), the edge cache windows,
 * and that no request detail is ever logged.
 * Run: `npm run test:weather-proxy`.
 */
import handler, { parseCoord, edgeTtl, isNordic, upstreamUrl, _resetMemory } from "../api/weather.js";

let pass = 0;
const failures = [];
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) pass++;
  else failures.push(`${name}: expected ${e}, got ${a}`);
}
const ok = (name, cond) => check(name, !!cond, true);

// ── No logging, whatever happens ──
let logged = 0;
for (const k of ["log", "info", "warn", "error", "debug"]) console[k] = () => { logged++; };
const realWrite = process.stdout.write.bind(process.stdout);

// ── The clock ──
let nowMs = Date.parse("2026-11-15T12:00:00Z");
const RealDate = Date;
globalThis.Date = class extends RealDate {
  constructor(...a) { super(...(a.length ? a : [nowMs])); }
  static now() { return nowMs; }
};

/** A stub MET: `plan` is a list of answers, one per upstream request. Every request is recorded. */
function stubMET(plan) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), headers: init.headers || {} });
    const a = plan[Math.min(calls.length - 1, plan.length - 1)];
    if (a instanceof Error) throw a;
    return {
      status: a.status,
      headers: { get: (n) => (a.headers || {})[n.toLowerCase()] ?? null },
      text: async () => a.body ?? "",
    };
  };
  return calls;
}

async function call({ method = "GET", query = { lat: "43.65", lon: "-79.38" }, headers = { "x-nostalgex-client": "web" } } = {}) {
  let status = 0, body = null;
  const sent = {};
  const res = {
    setHeader(k, v) { sent[k] = v; },
    status(c) { status = c; return this; },
    json(d) { body = JSON.stringify(d); return this; },
    send(d) { body = d; return this; },
    end(d) { if (d) body = d; return this; },
  };
  await handler({ method, query, headers }, res);
  return { status, body, headers: sent };
}

const DOC = JSON.stringify({ type: "Feature", properties: { meta: { updated_at: "2026-11-15T11:00:00Z" }, timeseries: [] } });
const expiresIn = (s) => new RealDate(nowMs + s * 1000).toUTCString();
const OK = (extra = {}) => ({ status: 200, body: DOC, headers: { "last-modified": "Sun, 15 Nov 2026 11:15:00 GMT", expires: expiresIn(1800), ...extra } });

// ── Coordinates ──
check("rounds to 2 decimals", parseCoord("43.6532", 90), 43.65);
check("rounds up", parseCoord("-79.3851", 180), -79.39);
check("keeps a whole number", parseCoord("52", 90), 52);
check("negative zero is zero", Object.is(parseCoord("-0.001", 90), 0), true);
check("out of range", parseCoord("91", 90), null);
check("longitude range", parseCoord("180.01", 180), null);
check("not a number", parseCoord("abc", 90), null);
check("scientific notation refused", parseCoord("1e2", 90), null);
check("empty", parseCoord("", 90), null);
check("array refused", parseCoord(["1", "2"], 90), null);
check("undefined", parseCoord(undefined, 90), null);
check("upstream url has 2 decimals", upstreamUrl(43.65, -79.38), "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=43.65&lon=-79.38");
check("upstream url pads", upstreamUrl(52, 0), "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=52.00&lon=0.00");

// ── Edge windows ──
check("Oslo is Nordic", isNordic(59.91, 10.75), true);
check("Toronto is not", isNordic(43.65, -79.38), false);
check("world floor is 3 hours", edgeTtl(43.65, -79.38, nowMs + 1800 * 1000, nowMs), 10800);
check("Nordic floor is 30 minutes", edgeTtl(59.91, 10.75, nowMs + 600 * 1000, nowMs), 1800);
check("a later Expires wins", edgeTtl(43.65, -79.38, nowMs + 4 * 3600 * 1000, nowMs), 14400);
check("capped at 6 hours", edgeTtl(43.65, -79.38, nowMs + 20 * 3600 * 1000, nowMs), 21600);
check("no Expires is the floor", edgeTtl(43.65, -79.38, null, nowMs), 10800);

// ── The handler ──
_resetMemory();
let calls = stubMET([OK()]);
let r = await call();
check("200 for a place", r.status, 200);
check("body is MET's document, untouched", r.body, DOC);
check("one upstream call", calls.length, 1);
check("identifying User-Agent", /^Nostalgex\/\S+ weather-relay https:\/\/nostalgex\.app support@nostalgex\.app$/.test(calls[0].headers["User-Agent"]), true);
check("rounded coordinates go upstream", calls[0].url.endsWith("lat=43.65&lon=-79.38"), true);
check("no If-Modified-Since on the first ask", "If-Modified-Since" in calls[0].headers, false);
check("edge cache: 3 hours, 5 minutes in the browser", r.headers["Cache-Control"], "public, max-age=300, s-maxage=10800, stale-while-revalidate=1800");

// Another viewer of the same town, with more decimals: served from memory, MET not asked.
nowMs += 600 * 1000;
r = await call({ query: { lat: "43.6499", lon: "-79.3801" } });
check("same town, rounded to the same key", calls.length, 1);
check("still 200", r.status, 200);

// A different town is a different key.
r = await call({ query: { lat: "45.50", lon: "-73.57" } });
check("another town asks MET", calls.length, 2);

// Before Expires: nothing is asked. After: If-Modified-Since, and a 304 renews the kept body.
nowMs = Date.parse("2026-11-15T12:00:00Z") + 1801 * 1000;
calls = stubMET([{ status: 304, headers: { expires: expiresIn(1800) } }]);
r = await call();
check("after Expires, one conditional request", calls.length, 1);
check("sends the last Last-Modified", calls[0].headers["If-Modified-Since"], "Sun, 15 Nov 2026 11:15:00 GMT");
check("a 304 serves the kept body", r.body, DOC);
check("a 304 is a 200 to the viewer", r.status, 200);
nowMs += 60 * 1000;
r = await call();
check("the renewed answer is not asked for again", calls.length, 1);

// MET failing after Expires: the kept answer is served, short-lived; with nothing kept, 502.
nowMs += 3600 * 1000;
calls = stubMET([{ status: 429 }]);
r = await call();
check("MET throttling: the kept answer, 60 seconds", [r.status, r.body, r.headers["Cache-Control"]], [200, DOC, "public, s-maxage=60, stale-while-revalidate=300"]);
nowMs += 13 * 3600 * 1000;
r = await call();
check("kept answer too old: 502", r.status, 502);
check("a 502 is never cached", r.headers["Cache-Control"], "no-store");
_resetMemory();
calls = stubMET([new Error("network")]);
r = await call();
check("network failure with nothing kept: 502", r.status, 502);
calls = stubMET([{ status: 200, body: "" }]);
r = await call();
check("empty answer: 502", r.status, 502);

// ── The gate ──
calls = stubMET([OK()]);
check("no client header: 403", (await call({ headers: {} })).status, 403);
check("unknown client: 403", (await call({ headers: { "x-nostalgex-client": "curl" } })).status, 403);
check("no upstream call for a refused client", calls.length, 0);
for (const c of ["tvos", "web", "roku", "android", "selfhost"]) check(`client ${c} accepted`, (await call({ headers: { "x-nostalgex-client": c } })).status, 200);
for (const bad of [{ lat: "x", lon: "1" }, { lat: "1" }, { lon: "1" }, { lat: "95", lon: "1" }, {}]) {
  const before = calls.length;
  const b = await call({ query: bad });
  check(`bad query ${JSON.stringify(bad)}: 400`, [b.status, b.headers["Cache-Control"]], [400, "no-store"]);
  check(`bad query ${JSON.stringify(bad)}: no upstream call`, calls.length, before);
}
check("POST: 405", (await call({ method: "POST" })).status, 405);

// ── CORS: nostalgex.app and a self-hosted tuner ──
r = await call({ headers: { "x-nostalgex-client": "web", origin: "https://nostalgex.app" } });
check("hosted origin allowed", r.headers["Access-Control-Allow-Origin"], "https://nostalgex.app");
r = await call({ headers: { "x-nostalgex-client": "selfhost", origin: "http://192.168.1.50:8080" } });
check("self-hosted origin echoed", r.headers["Access-Control-Allow-Origin"], "http://192.168.1.50:8080");
r = await call({ headers: { "x-nostalgex-client": "web", origin: "https://evil.example" } });
check("other origin not allowed", r.headers["Access-Control-Allow-Origin"], undefined);
r = await call({ method: "OPTIONS", headers: { origin: "http://nas.local:8080", "access-control-request-headers": "x-nostalgex-client" } });
check("preflight from a self-hosted tuner", [r.status, r.headers["Access-Control-Allow-Origin"]], [204, "http://nas.local:8080"]);
check("every answer varies on origin and client", r.headers["Vary"], "Origin, X-Nostalgex-Client");

check("nothing was logged", logged, 0);

globalThis.Date = RealDate;
if (failures.length) {
  console.error = (...a) => realWrite(a.join(" ") + "\n");
  realWrite(`weather-proxy-smoke: ${failures.length} failed, ${pass} passed\n${failures.map((f) => "  " + f).join("\n")}\n`);
  process.exit(1);
}
realWrite(`weather-proxy-smoke: ${pass} checks passed\n`);
