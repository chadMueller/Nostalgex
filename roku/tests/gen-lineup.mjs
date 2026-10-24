// Lineup golden vectors: the parts of plex-tuner.html that turn filter pools
// into what the guide airs. getTimeFilteredPool is lifted unchanged out of
// plex-tuner.html; getManifestBlocks and poolFingerprint run
// from the daily-manifest module over a stand-in localStorage, two days in a
// row, so yesterday's schedule feeds today's as it does in the browser.
// Called by tests/gen-vectors.mjs, which owns the output, with TZ=UTC.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

export function liftFunction(html, name) {
  const at = html.search(new RegExp(`(?:async\\s+)?function\\s+${name}\\s*\\(`));
  if (at < 0) throw new Error(`plex-tuner.html has no function ${name}`);
  let i = html.indexOf("(", at), depth = 0;
  for (; ; i++) { if (html[i] === "(") depth++; else if (html[i] === ")" && --depth === 0) break; }
  i = html.indexOf("{", i);
  for (depth = 0; ; i++) { if (html[i] === "{") depth++; else if (html[i] === "}" && --depth === 0) break; }
  return html.slice(at, i + 1);
}

function withClock(ms, fn) {
  const RealDate = globalThis.Date;
  globalThis.Date = class extends RealDate {
    constructor(...a) { if (a.length) super(...a); else super(ms); }
    static now() { return ms; }
  };
  try { return fn(); } finally { globalThis.Date = RealDate; }
}

export function lineupVectors(upstream, M, pool) {
  // getTimeFilteredPool reads ratings through the page's channel filter global.
  createRequire(import.meta.url)(join(upstream, "scripts", "nostalgex-channel-filter.cjs"));
  const html = readFileSync(join(upstream, "plex-tuner.html"), "utf8");
  // Pools air in library order since tuner 1.0.7 (no shuffle), as on the Apple TV.
  const lifted = new Function(`${liftFunction(html, "getTimeFilteredPool")}\nreturn { getTimeFilteredPool };`)();
  const ids = (arr) => arr.map((i) => i.ratingKey).join(",");

  // getTimeFilteredPool at each hour, for every kind of restriction.
  // Ratings from other countries count as their US labels (upstream GitHub #41).
  const rated = pool.map((it, k) => ({ ...it, contentRating: ["R", "PG", "NC-17", "TV-MA", "GB-18", "GB-PG", "FSK-16", "TV-12A", "gb/15"][k % 9] }));
  const restrictions = [
    { blockRatings: { ratings: ["R", "NC-17"], blockBefore: 21 } },
    { blockRatings: { ratings: ["R", "PG", "NC-17", "TV-MA"], blockAfter: 22 } },
    { tvOnlyBefore: 11 },
    { onlyAfterHour: 20 },
    { blockRatings: { ratings: ["TV-MA"], blockBefore: 6, blockAfter: 23 }, tvOnlyBefore: 9, onlyAfterHour: 2 },
  ];
  const timeFilter = [];
  for (const tr of restrictions) {
    for (const hour of [0, 1, 2, 5, 6, 8, 9, 10, 11, 19, 20, 21, 22, 23]) {
      const ms = Date.UTC(2026, 9, 12, hour, 30);
      timeFilter.push({ tr, hour, out: ids(withClock(ms, () => lifted.getTimeFilteredPool({ timeRestrictions: tr, itemPool: rated }))) });
    }
  }

  // getManifestBlocks over consecutive days, through a stand-in localStorage.
  const store = new Map();
  globalThis.localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
    key: (i) => [...store.keys()][i] ?? null,
    get length() { return store.size; },
  };
  const blocksOf = (arr) => arr.map((b) => `${b.item.ratingKey}@${b.startSec}-${b.endSec}`).join(",");
  const manifests = [];
  const small = pool.slice(0, 9);
  const steps = [
    { ch: { id: 7 }, pool: small, iso: "2026-10-12T15:30:00Z" },
    { ch: { id: 7 }, pool: small, iso: "2026-10-12T22:00:00Z" },
    { ch: { id: 7 }, pool: small.slice(0, 8), iso: "2026-10-12T22:05:00Z" },
    { ch: { id: 7 }, pool: small, iso: "2026-10-13T00:00:00Z" },
    { ch: { id: 7 }, pool: small, iso: "2026-10-14T09:00:00Z" },
    { ch: { id: 409, isPremiereChannel: true }, pool, iso: "2026-10-13T08:00:00Z" },
    { ch: { id: 409, isPremiereChannel: true }, pool, iso: "2026-10-14T08:00:00Z" },
    { clear: true },
    { ch: { id: 7 }, pool: small, iso: "2026-10-14T09:00:00Z" },
  ];
  for (const s of steps) {
    if (s.clear) { M.clearManifests("roku"); manifests.push({ clear: true }); continue; }
    const ms = Date.parse(s.iso);
    manifests.push({
      channel: s.ch, n: s.pool.length, atSec: Math.floor(ms / 1000),
      out: blocksOf(M.getManifestBlocks(s.ch, s.pool, ms, "roku")),
    });
  }
  // The same, in a zone whose clocks change: either side of each change and
  // late on both days, when the clock's time since midnight is an hour off.
  // `zone` is America/New_York's offsets over these dates, for the port to pin.
  const dst = { zone: [
    { fromSec: 0, offsetSec: -4 * 3600 },
    { fromSec: Date.parse("2026-11-01T06:00:00Z") / 1000, offsetSec: -5 * 3600 },
    { fromSec: Date.parse("2027-03-14T07:00:00Z") / 1000, offsetSec: -4 * 3600 },
  ], cases: [] };
  const tz = process.env.TZ;
  process.env.TZ = "America/New_York";
  try {
    for (const iso of ["2026-10-31T23:30:00-04:00", "2026-11-01T00:30:00-04:00", "2026-11-01T01:30:00-04:00",
      "2026-11-01T01:30:00-05:00", "2026-11-01T21:00:00-05:00", "2026-11-01T23:30:00-05:00",
      "2026-11-02T00:30:00-05:00", "2027-03-14T01:30:00-05:00", "2027-03-14T03:30:00-04:00",
      "2027-03-14T21:00:00-04:00", "2027-03-15T00:30:00-04:00"]) {
      const ms = Date.parse(iso);
      M.clearManifests("roku");
      dst.cases.push({
        atSec: Math.floor(ms / 1000),
        dayStartSec: Math.floor(M.startOfLocalDayMs(ms) / 1000), dayKey: M.localDayKey(ms), dayNumber: M.localDayNumber(ms),
        out: blocksOf(M.getManifestBlocks({ id: 7 }, small, ms, "roku")),
      });
    }
  } finally {
    process.env.TZ = tz;
  }
  delete globalThis.localStorage;

  const fingerprint = [0, 1, 5, pool.length].map((n) => ({ n, out: globalThis.__nxRng.poolFingerprint(pool.slice(0, n)) }));
  return { pool, timeFilter, rated, manifests, dst, fingerprint };
}
