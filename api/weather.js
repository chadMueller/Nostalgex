/**
 * Forecast relay for the weather channel (Trello I-016): the Apple TV app, Roku, Android TV, the
 * hosted web tuner and the Docker tuner all ask this function for one place's forecast, and it asks
 * MET Norway (Locationforecast 2.0, `complete`, CC BY 4.0) on their behalf.
 *
 *   GET /api/weather?lat=43.65&lon=-79.38      X-Nostalgex-Client: tvos | web | roku | android | selfhost
 *
 * Why a relay: MET's terms say browsers and apps "should not contact the API directly, but instead use
 * a local proxy" and that "the only fully supported solution" for a web page is a proxy that adds the
 * identification. This one adds an identifying User-Agent, follows MET's cache rules, and lets one
 * answer per place serve every viewer.
 *
 * MET's rules, and how they are kept here
 *   - Identify the app: every request carries `User-Agent: Nostalgex/<n> https://nostalgex.app support@nostalgex.app`.
 *   - "Never repeat requests until the time indicated in the Expires response header": an answer is
 *     kept in memory until its Expires and nothing is asked of MET before then.
 *   - After Expires, ask with If-Modified-Since from the last answer's Last-Modified. A 304 renews the
 *     Expires and the kept body is served again.
 *   - "Identical requests should not be repeated more often than every 30 mins for the Nordic region
 *     or every 3rd hour for the rest of the world": the edge cache holds an answer at least that long
 *     (s-maxage), so a warm place is one MET request per window however many viewers ask.
 *   - Coordinates: MET asks for at most 4 decimals "to facilitate caching". We round to 2 (about 1 km),
 *     so everyone in a town asks for the same key. A request with more decimals is rounded, not refused.
 *
 * Privacy. Nothing here writes a log line, and the function stores a place only as the key of its
 * in-memory cache, which goes with the instance. Vercel itself keeps request logs for the platform's
 * own retention, URL and query string included; that is Vercel's, not this code's.
 *
 * CORS is the same as api/tmdb.js: nostalgex.app calls this same-origin, and a self-hosted tuner's
 * origin (any http or https address) is echoed back when it says `X-Nostalgex-Client: selfhost`.
 * Roku and Android TV are not browsers, send no Origin and need no CORS.
 */
import { corsHeaders } from './tmdb.js';

const MET = 'https://api.met.no/weatherapi/locationforecast/2.0/complete';
const USER_AGENT = 'Nostalgex/1.0 weather-relay https://nostalgex.app support@nostalgex.app';
const CLIENT_HEADER = 'x-nostalgex-client';
const CLIENT_VALUES = new Set(['tvos', 'web', 'roku', 'android', 'selfhost']);
const COORD_RE = /^-?\d{1,3}(?:\.\d{1,8})?$/;
const NO_STORE = 'no-store';

// The Nordic window MET updates hourly (every 6 hours elsewhere): where it may be asked again after 30 minutes.
const NORDIC = { minLat: 54, maxLat: 72, minLon: 4, maxLon: 32 };
const MIN_TTL_NORDIC = 30 * 60;
const MIN_TTL_WORLD = 3 * 60 * 60;
const MAX_TTL = 6 * 60 * 60;
const STALE_OK_MS = 12 * 60 * 60 * 1000;   // an answer MET cannot renew is still served this long
const MEMORY_MAX = 400;

/** A coordinate from the query string, rounded to 2 decimals, or null when it is not one in range. Exported for the smoke test. */
export function parseCoord(value, max) {
  if (typeof value !== 'string' || !COORD_RE.test(value)) return null;
  const n = Number(value);
  if (!Number.isFinite(n) || Math.abs(n) > max) return null;
  const r = Math.round(n * 100) / 100;
  return r === 0 ? 0 : r;
}

export function isNordic(lat, lon) {
  return lat >= NORDIC.minLat && lat <= NORDIC.maxLat && lon >= NORDIC.minLon && lon <= NORDIC.maxLon;
}

/** Seconds the edge may keep an answer: until MET's Expires, and not under the repeat window for that part of the world. */
export function edgeTtl(lat, lon, expiresMs, nowMs) {
  const floor = isNordic(lat, lon) ? MIN_TTL_NORDIC : MIN_TTL_WORLD;
  const untilExpires = Number.isFinite(expiresMs) ? Math.floor((expiresMs - nowMs) / 1000) : 0;
  return Math.min(MAX_TTL, Math.max(floor, untilExpires));
}

export function upstreamUrl(lat, lon) {
  return `${MET}?lat=${lat.toFixed(2)}&lon=${lon.toFixed(2)}`;
}

// One answer per rounded place, per instance. `body` is MET's JSON text.
const memory = new Map();
export function _resetMemory() { memory.clear(); }
function remember(key, entry) {
  memory.delete(key);
  memory.set(key, entry);
  while (memory.size > MEMORY_MAX) memory.delete(memory.keys().next().value);
}

const header = (res, name) => (res && res.headers && typeof res.headers.get === 'function' ? res.headers.get(name) : null);
const dateMs = (v) => { const t = v ? Date.parse(v) : NaN; return Number.isFinite(t) ? t : null; };

function send(res, status, body, cacheControl) {
  res.setHeader('Cache-Control', cacheControl);
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (typeof body === 'string') { res.status(status); return res.send ? res.send(body) : res.end(body); }
  return res.status(status).json(body);
}

export default async function handler(req, res) {
  const cors = corsHeaders(req.headers?.origin, {
    client: req.headers?.[CLIENT_HEADER],
    preflightHeaders: req.method === 'OPTIONS' ? req.headers?.['access-control-request-headers'] : undefined,
  });
  for (const [key, value] of Object.entries(cors)) res.setHeader(key, value);

  if (req.method === 'OPTIONS') {
    res.setHeader('Allow', 'GET, OPTIONS');
    return res.status(204).end();
  }
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET, OPTIONS');
    return res.status(405).json({ error: 'Method not allowed' });
  }
  if (!CLIENT_VALUES.has(req.headers?.[CLIENT_HEADER])) {
    return res.status(403).json({ error: 'Client header required' });
  }

  const lat = parseCoord(req.query?.lat, 90);
  const lon = parseCoord(req.query?.lon, 180);
  if (lat === null || lon === null) {
    res.setHeader('Cache-Control', NO_STORE);
    return res.status(400).json({ error: 'lat and lon required' });
  }

  const key = `${lat.toFixed(2)},${lon.toFixed(2)}`;
  const now = Date.now();
  let entry = memory.get(key);

  // Nothing is asked of MET before the answer's own Expires.
  if (!entry || now >= entry.expiresMs) {
    const headers = { 'User-Agent': USER_AGENT, Accept: 'application/json' };
    if (entry && entry.lastModified) headers['If-Modified-Since'] = entry.lastModified;
    let up = null;
    try {
      up = await fetch(upstreamUrl(lat, lon), { headers });
    } catch {
      up = null;
    }
    if (up && up.status === 200) {
      let text = null;
      try { text = await up.text(); } catch { text = null; }
      if (text) {
        entry = {
          body: text,
          lastModified: header(up, 'last-modified'),
          expiresMs: dateMs(header(up, 'expires')) ?? now + 30 * 60 * 1000,
          fetchedMs: now,
        };
        remember(key, entry);
      } else {
        up = null;
      }
    } else if (up && up.status === 304 && entry) {
      entry = { ...entry, expiresMs: dateMs(header(up, 'expires')) ?? now + 30 * 60 * 1000, fetchedMs: now };
      remember(key, entry);
    } else {
      up = null;
    }
    if (!up) {
      // MET unreachable, throttled or refusing: an answer kept from earlier is better than none, for a while.
      if (entry && now - entry.fetchedMs < STALE_OK_MS) {
        return send(res, 200, entry.body, 'public, s-maxage=60, stale-while-revalidate=300');
      }
      return send(res, 502, { error: 'Forecast unavailable' }, NO_STORE);
    }
  }

  const ttl = edgeTtl(lat, lon, entry.expiresMs, now);
  // max-age lets a viewer's browser reuse it for 5 minutes; the edge keeps it for the MET window.
  return send(res, 200, entry.body, `public, max-age=300, s-maxage=${ttl}, stale-while-revalidate=1800`);
}
