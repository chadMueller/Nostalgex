#!/usr/bin/env node
// Generate schedule golden vectors from upstream's own engine
// (scripts/nostalgex-daily-manifest.js), which upstream holds bit-identical to
// the Apple TV Swift. The BrightScript port must reproduce every vector; a
// divergence is a bug in the port, never a reason to regenerate.
//
//   node tests/gen-vectors.mjs            # write tests/vectors/{schedule,filter,lineup,franchise,enrichment,collections,mediabrowser,schedule-dst-zones}.json
//   node tests/gen-vectors.mjs --check    # fail if the file is stale
//
// Upstream: $NOSTALGEX_DIR, default the Nostalgex repo this port lives in
// (roku/..), so the vectors always come from the same tree as the data the
// port reads. tests/vectors/ is generated, git-ignored, and rewritten by
// tests/run.sh and scripts/deploy.sh --test on every run. It also gets byte
// copies of upstream's scripts/franchise-golden.json, filter-golden.json,
// rating-golden.json, season-golden.json, schedule-dst-golden.json and
// schedule-parity-golden.json, which the Franchise, FilterGolden,
// RatingGolden, Seasonal, ScheduleDSTGolden and ScheduleParityGolden tests read.
// Every number in the output fits a 32-bit Integer, and 64-bit values travel as
// hex strings, so the Roku's ParseJson reads them without loss.
// The filter's date rules run in local time; pin it so the vectors don't
// depend on where they were generated.
process.env.TZ = "UTC";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { filterVectors } from "./gen-filter.mjs";
import { lineupVectors } from "./gen-lineup.mjs";
import { franchiseVectors } from "./gen-franchise.mjs";
import { enrichmentVectors } from "./gen-enrichment.mjs";
import { collectionsVectors } from "./gen-collections.mjs";
import { mediaBrowserVectors } from "./gen-mediabrowser.mjs";
import { dstZones, parityZones } from "./gen-dst.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const upstream = resolve(process.env.NOSTALGEX_DIR || join(here, "..", ".."));
const out = join(here, "vectors", "schedule.json");
mkdirSync(join(here, "vectors"), { recursive: true });
const commit = execFileSync("git", ["-C", upstream, "rev-parse", "HEAD"]).toString().trim();
const engine = join(upstream, "scripts", "nostalgex-daily-manifest.js");
const source = readFileSync(engine, "utf8");

// The upstream module keeps its RNG private, so evaluate the file with a hook
// that exposes it. The RNG is checked on its own because a wrong 64-bit
// operation in the port shows up there first, and far more legibly.
const hooked = source.replace(
  "const api = {",
  "global.__nxRng = { splitmix64, makeSeededRNG, swiftShuffle, poolFingerprint };\n  const api = {",
);
if (hooked === source) throw new Error("upstream engine changed shape: no `const api = {`");
new Function("globalThis", "module", hooked)(globalThis, undefined);
const M = globalThis.NostalgexDailyManifest;
const R = globalThis.__nxRng;
const hex = (b) => BigInt.asUintN(64, b).toString(16).padStart(16, "0");
const ids = (arr) => arr.map((i) => i.ratingKey).join(",");
const blocks = (arr) => arr.map((b) => `${b.ratingKey}@${b.startSec}-${b.endSec}`).join(",");

// ── Fixture A: upstream's own smoke-test pool, with its Swift-made vectors ──
const poolA = [];
["Seinfeld", "Friends", "The Office"].forEach((show, si) => {
  for (let e = 1; e <= 5; e++) {
    poolA.push({ ratingKey: `e${si}${e}`, title: show, type: "episode", duration: 22, addedAt: 0 });
  }
});
[
  "Alien", "Mockingjay Part 2", "Heat", "Mockingjay Part 1", "Deathly Hallows: Part 2",
  "Jaws", "Deathly Hallows: Part 1", "Rocky", "Kill Bill Vol 1", "Dune",
].forEach((title, mi) => {
  poolA.push({ ratingKey: `m${mi}`, title, type: "movie", duration: 95 + mi * 3, addedAt: mi % 4 === 0 ? 1700000000 : 0 });
});
const DAY_START_A = 1700100000;

// Copied verbatim from upstream scripts/nostalgex-schedule-order-smoke.mjs,
// where they were produced by the real Swift on Apple Swift 6.2.1.
const swift = {
  order: {
    "INTER:1:20000": "m8,m3,m5,m4,m7,m2,m6,m9,m0,e22,e25,e03,e01,m1,e15,e13,e23,e21,e04,e05,e14,e12,e24,e02,e11",
    "PROMO:1:20000": "m3,m5,m7,m2,m6,m9,e22,e25,e03,e01,m1,e15,e13,e23,e21,e04,e05,e14,e12,e24,e02,e11,m0,m4,m8",
    "SEQ:1:20000": "m3,m1,m5,m7,m2,m6,m4,m9,e22,e25,e03,e01,e15,e13,e23,e21,e04,e05,e14,e12,e24,e02,e11,m0,m8",
    "INTER:49:20431": "m1,e23,e24,m7,m3,m2,m9,m0,m5,m4,e03,e05,e14,e12,m8,m6,e22,e21,e02,e04,e11,e15,e25,e01,e13",
    "PROMO:49:20431": "m1,e23,e24,m7,m3,m2,m9,m5,e03,e05,e14,e12,m6,e22,e21,e02,e04,e11,e15,e25,e01,e13,m0,m8,m4",
    "SEQ:49:20431": "m3,m1,e23,e24,m7,m2,m9,m5,e03,e05,e14,e12,m6,m4,e22,e21,e02,e04,e11,e15,e25,e01,e13,m0,m8",
    "INTER:141:20500": "m8,m9,m6,m2,m4,m3,m1,e21,e22,m5,e04,e05,m7,e12,e11,m0,e25,e24,e02,e01,e15,e13,e23,e03,e14",
    "PROMO:141:20500": "m9,m6,m2,m3,m1,e21,e22,m5,e04,e05,m7,e12,e11,e25,e24,e02,e01,e15,e13,e23,e03,e14,m4,m8,m0",
    "SEQ:141:20500": "m9,m6,m4,m2,m3,m1,e21,e22,m5,e04,e05,m7,e12,e11,e25,e24,e02,e01,e15,e13,e23,e03,e14,m8,m0",
  },
  premiereOffset: {
    "1:m0": 72900, "1:m4": 79200, "1:m8": 81000, "1:e01": 84600,
    "49:m0": 68400, "49:m4": 85500, "49:m8": 78300, "49:e01": 76500,
    "223:m0": 83700, "223:m4": 73800, "223:m8": 69300, "223:e01": 72000,
  },
};
// The JS must still agree with Swift, or these vectors prove nothing.
for (const [seed, day] of [[1, 20000], [49, 20431], [141, 20500]]) {
  const a = M.interleaveByShow(poolA, seed, day);
  const b = M.promoteRecentlyAdded(a, DAY_START_A, seed);
  const c = M.groupSequelParts(b);
  for (const [k, v] of [["INTER", a], ["PROMO", b], ["SEQ", c]]) {
    if (swift.order[`${k}:${seed}:${day}`] !== ids(v)) throw new Error(`upstream JS disagrees with Swift at ${k}:${seed}:${day}`);
  }
}
for (const [key, want] of Object.entries(swift.premiereOffset)) {
  const [ch, rk] = key.split(":");
  if (M.premiereOffset(Number(ch), rk) !== want) throw new Error(`upstream JS disagrees with Swift on premiereOffset ${key}`);
}

// ── Fixture B: a broader pool that reaches every branch ────────────────────
// Shows of uneven length (the interleave's exhausted-group path), shows whose
// titles differ only in case (Swift groups case-sensitively), sequel families
// in every marker form plus decoys that must not move, a zero-length item, and
// premieres within, at and just outside the 7-day window.
const DAY_START_B = 1791262800; // 2026-10-06 00:00 at UTC-5
const DAY_B = 20732;
const WEEK = 7 * 86400;
const poolB = [];
const shows = [["Seinfeld", 9, 22], ["Friends", 4, 22], ["The Wire", 3, 58], ["Bluey", 12, 7], ["the wire", 2, 58], ["Cheers", 1, 25]];
let n = 100;
for (const [show, count, dur] of shows) {
  for (let e = 0; e < count; e++) {
    poolB.push({ ratingKey: String(n++), title: show, type: "episode", duration: dur + (e % 3), addedAt: 0 });
  }
}
const movies = [
  ["The Godfather", 175], ["Kill Bill: Vol. 2", 137], ["Dune: Part Two", 166], ["Dune Part 1", 155],
  ["Dune: Part 2", 166], ["Harry Potter and the Deathly Hallows - Part 1", 146],
  ["Harry Potter and the Deathly Hallows - Part 2", 130], ["Mockingjay Pt. 2", 137], ["Mockingjay pt 1", 123],
  ["Part 2", 90], ["Spare Parts 2", 83], ["Partly Cloudy", 6], ["Che: Part 10", 134], ["Che: Part 9", 135],
  ["Zero Length", 0], ["Alien", 117], ["Aliens", 137], ["Heat", 170], ["Jaws", 124], ["Rocky", 120],
  ["Ran", 162], ["Yojimbo", 110], ["Amélie", 122], ["Up", 96],
];
for (const [title, duration] of movies) {
  poolB.push({ ratingKey: String(n++), title, type: "movie", duration, addedAt: 0 });
}
const recent = { "109": DAY_START_B - 3600, "125": DAY_START_B - WEEK, "130": DAY_START_B - WEEK - 1, "133": DAY_START_B - 86400, "140": DAY_START_B - 2 * 86400 };
for (const it of poolB) if (recent[it.ratingKey]) it.addedAt = recent[it.ratingKey];

// ── Vectors ────────────────────────────────────────────────────────────────
const rng = {
  splitmix64: [0, 1, 2, 42, 20001, 20733, 2147483647].map((x) => ({ in: x, out: hex(R.splitmix64(x)) })),
  next: [1, 2, 20001, 21234].map((seed) => {
    const r = R.makeSeededRNG(BigInt(seed));
    return { seed, out: Array.from({ length: 8 }, () => hex(r.next())) };
  }),
  bounded: [[2, [2, 3, 7, 10, 100, 1000]], [20733, [5, 13, 64, 65, 2147483647, 1]]].map(([seed, bounds]) => {
    const r = R.makeSeededRNG(BigInt(seed));
    return { seed, bounds, out: bounds.map((b) => r.boundedNext(b)) };
  }),
};

const premiereOffset = {};
for (const ch of [1, 7, 49, 130, 223, 409, 2147483647]) {
  for (const rk of ["m0", "1", "100", "12345", "a1b2c3d4e5f6", "", "é", "ラ"]) {
    premiereOffset[`${ch}:${rk}`] = M.premiereOffset(ch, rk);
  }
}

const order = {};
for (const [seed, day] of [[1, 20000], [7, DAY_B], [49, DAY_B + 1], [130, DAY_B], [409, 25000], [2, 0]]) {
  const a = M.interleaveByShow(poolB, seed, day);
  const b = M.promoteRecentlyAdded(a, DAY_START_B, seed);
  order[`INTER:${seed}:${day}`] = ids(a);
  order[`PROMO:${seed}:${day}`] = ids(b);
  order[`SEQ:${seed}:${day}`] = ids(M.groupSequelParts(b));
  order[`SEQONLY:${seed}:${day}`] = ids(M.groupSequelParts(a));
}

// packDay over whole days: the unplayed pass, the golden-ratio filler loop,
// both seams, and premiere vs non-premiere channels.
const small = poolB.filter((i) => ["Bluey", "Cheers"].includes(i.title) || ["Up", "Ran", "Dune Part 1", "Dune: Part 2"].includes(i.title));
const single = [poolB.find((i) => i.title === "Heat")];
const aired = new Set(poolB.filter((_, k) => k % 3 === 0).map((i) => i.ratingKey));
const allAired = new Set(small.map((i) => i.ratingKey));
const packCases = [
  { name: "full-plain", pool: poolB, day: DAY_B, ch: 7, aired: [], premiere: false, last: null },
  { name: "full-premiere", pool: poolB, day: DAY_B, ch: 7, aired: [], premiere: true, last: null },
  { name: "full-premiere-ch130", pool: poolB, day: DAY_B, ch: 130, aired: [], premiere: true, last: null },
  { name: "yesterday-aired", pool: poolB, day: DAY_B + 1, ch: 49, aired: [...aired], premiere: true, last: null },
  { name: "small-filler", pool: small, day: DAY_B, ch: 7, aired: [], premiere: false, last: null },
  { name: "small-filler-nextday", pool: small, day: DAY_B + 1, ch: 7, aired: [], premiere: false, last: null },
  { name: "all-aired", pool: small, day: DAY_B, ch: 409, aired: [...allAired], premiere: false, last: null },
  { name: "single", pool: single, day: DAY_B, ch: 1, aired: [], premiere: false, last: null },
  { name: "single-aired", pool: single, day: DAY_B, ch: 1, aired: [single[0].ratingKey], premiere: false, last: single[0].ratingKey },
];
// Seam cases: yesterday closed on exactly what today would open with.
for (const base of [packCases[0], packCases[4], packCases[6]]) {
  const first = M.packDay(base.pool, DAY_START_B, base.day, base.ch, new Set(base.aired), base.premiere, null)[0].ratingKey;
  packCases.push({ ...base, name: `${base.name}-seam`, last: first });
}
// packDay ends the day after the local day's length (its localDayLengthSec),
// which the port takes as dayEnd, as the Swift does: 86,400 s here, in UTC.
const dayEndB = DAY_START_B + (M.startOfNextLocalDayMs(DAY_START_B * 1000) - M.startOfLocalDayMs(DAY_START_B * 1000)) / 1000;
const packDay = packCases.map((c) => ({
  name: c.name,
  pool: c.pool === poolB ? "B" : c.pool === small ? "small" : "single",
  dayStart: DAY_START_B,
  dayEnd: dayEndB,
  day: c.day,
  channel: c.ch,
  aired: c.aired,
  premiere: c.premiere,
  last: c.last,
  blocks: blocks(M.packDay(c.pool, DAY_START_B, c.day, c.ch, new Set(c.aired), c.premiere, c.last)),
}));

const vectors = {
  generatedBy: "tests/gen-vectors.mjs",
  upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, engine: "scripts/nostalgex-daily-manifest.js" },
  fixtures: {
    A: { dayStart: DAY_START_A, pool: poolA },
    B: { dayStart: DAY_START_B, pool: poolB },
    small: { pool: small },
    single: { pool: single },
  },
  swift,
  rng,
  premiereOffset,
  order,
  packDay,
};
const files = [
  [out, vectors],
  [join(here, "vectors", "filter.json"), {
    generatedBy: "tests/gen-vectors.mjs (tests/gen-filter.mjs)",
    upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, engine: "scripts/nostalgex-channel-filter.cjs" },
    ...filterVectors(upstream),
  }],
  [join(here, "vectors", "lineup.json"), {
    generatedBy: "tests/gen-vectors.mjs (tests/gen-lineup.mjs)",
    upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, engine: "plex-tuner.html, scripts/nostalgex-daily-manifest.js" },
    ...lineupVectors(upstream, M, poolB),
  }],
  [join(here, "vectors", "franchise.json"), {
    generatedBy: "tests/gen-vectors.mjs (tests/gen-franchise.mjs)",
    upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, engine: "scripts/nostalgex-franchise-builder.js" },
    ...franchiseVectors(upstream),
  }],
  [join(here, "vectors", "enrichment.json"), {
    generatedBy: "tests/gen-vectors.mjs (tests/gen-enrichment.mjs)",
    upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, engine: "scripts/nostalgex-enrichment.js" },
    ...enrichmentVectors(upstream),
  }],
  [join(here, "vectors", "collections.json"), {
    generatedBy: "tests/gen-vectors.mjs (tests/gen-collections.mjs)",
    upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, engine: "scripts/nostalgex-collections.js" },
    ...(await collectionsVectors(upstream)),
  }],
  [join(here, "vectors", "mediabrowser.json"), {
    generatedBy: "tests/gen-vectors.mjs (tests/gen-mediabrowser.mjs)",
    upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, engine: "plex-tuner.html fetchJellyfinLibraryFromServer" },
    ...(await mediaBrowserVectors(upstream)),
  }],
  [join(here, "vectors", "schedule-dst-zones.json"), {
    generatedBy: "tests/gen-vectors.mjs (tests/gen-dst.mjs)",
    upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, source: "the tz database (Intl), for scripts/schedule-dst-golden.json's zones" },
    ...dstZones(upstream),
  }],
  [join(here, "vectors", "schedule-parity-zones.json"), {
    generatedBy: "tests/gen-vectors.mjs (tests/gen-dst.mjs)",
    upstream: { repo: "https://github.com/chadMueller/Nostalgex", commit, source: "the tz database (Intl), for scripts/schedule-parity-golden.json's zones" },
    ...parityZones(upstream),
  }],
  // Upstream's own golden files, copied byte for byte: FranchiseTests.brs,
  // FilterGoldenTests.brs, RatingGoldenTests.brs, SeasonalTests.brs,
  // ScheduleDSTGoldenTests.brs and ScheduleParityGoldenTests.brs read them.
  ...["franchise-golden.json", "filter-golden.json", "rating-golden.json", "season-golden.json", "schedule-dst-golden.json", "schedule-parity-golden.json"].map((g) =>
    [join(here, "vectors", g), readFileSync(join(upstream, "scripts", g), "utf8")]),
];
let stale = false;
for (const [path, data] of files) {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 1) + "\n";
  if (process.argv.includes("--check")) {
    let current = null;
    try { current = readFileSync(path, "utf8"); } catch {}
    if (current !== text) {
      console.error(`stale: ${path} differs from upstream ${commit.slice(0, 7)}`);
      stale = true;
    }
  } else {
    writeFileSync(path, text);
    console.log(`wrote ${path} from upstream ${commit.slice(0, 7)}`);
  }
}
if (stale) process.exit(1);
if (process.argv.includes("--check")) console.log(`up to date with upstream ${commit.slice(0, 7)}`);
