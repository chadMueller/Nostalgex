#!/usr/bin/env node
/**
 * Golden-vector smoke test for scripts/nostalgex-daily-manifest.js ordering.
 *
 * The expected strings pin the ordering (interleaveByShow, promoteRecentlyAdded,
 * groupSequelParts). They were first produced by running the Swift algorithms on Apple
 * Swift 6.2.1. On 2026-11-19 CLASSIC RERUNS changed to two consecutive episodes from a
 * random spot (EPISODE ORDER, I-103) and the strings were written again from this engine,
 * after scripts/schedule-parity-golden.json (the Apple TV's own answers) matched it byte
 * for byte. That file is the proof the two agree; this one catches a drift in the ordering
 * alone. The episodes here carry no season or episode number, so series order is the
 * order they are listed in.
 *
 * Run: `npm run test:schedule`
 */
import "./nostalgex-daily-manifest.js";
const M = globalThis.NostalgexDailyManifest;

const pool = [];
["Seinfeld", "Friends", "The Office"].forEach((show, si) => {
  for (let e = 1; e <= 5; e++) {
    pool.push({ ratingKey: `e${si}${e}`, title: show, type: "episode", duration: 22, addedAt: 0 });
  }
});
[
  "Alien", "Mockingjay Part 2", "Heat", "Mockingjay Part 1", "Deathly Hallows: Part 2",
  "Jaws", "Deathly Hallows: Part 1", "Rocky", "Kill Bill Vol 1", "Dune",
].forEach((title, mi) => {
  pool.push({
    ratingKey: `m${mi}`, title, type: "movie",
    duration: 95 + mi * 3,
    addedAt: mi % 4 === 0 ? 1700000000 : 0,
  });
});
const DAY_START = 1700100000;

const GOLDEN = {
  "INTER:1:20000": "m7,m8,m3,e23,e24,m0,m4,m9,m2,e13,e14,m1,m5,m6,e03,e04,e25,e21,e15,e11,e05,e01,e22,e12,e02",
  "PROMO:1:20000": "m7,m3,e23,e24,m9,m2,e13,e14,m1,m5,m6,e03,e04,e25,e21,e15,e11,e05,e01,e22,e12,e02,m0,m4,m8",
  "SEQ:1:20000": "m7,m3,m1,e23,e24,m9,m2,e13,e14,m5,m6,m4,e03,e04,e25,e21,e15,e11,e05,e01,e22,e12,e02,m0,m8",
  "INTER:49:20431": "m0,m6,e03,e04,m5,e15,e11,e25,e21,m1,m7,m2,m4,m3,m9,m8,e05,e01,e12,e13,e22,e23,e02,e14,e24",
  "PROMO:49:20431": "m6,e03,e04,m5,e15,e11,e25,e21,m1,m7,m2,m3,m9,e05,e01,e12,e13,e22,e23,e02,e14,e24,m0,m8,m4",
  "SEQ:49:20431": "m6,m4,e03,e04,m5,e15,e11,e25,e21,m3,m1,m7,m2,m9,e05,e01,e12,e13,e22,e23,e02,e14,e24,m0,m8",
  "INTER:141:20500": "m2,m1,e25,e21,m6,m9,e04,e05,m3,m8,m7,e14,e15,m0,m5,m4,e22,e23,e01,e02,e11,e12,e24,e03,e13",
  "PROMO:141:20500": "m2,m1,e25,e21,m6,m9,e04,e05,m3,m7,e14,e15,m5,e22,e23,e01,e02,e11,e12,e24,e03,e13,m4,m8,m0",
  "SEQ:141:20500": "m2,m3,m1,e25,e21,m6,m4,m9,e04,e05,m7,e14,e15,m5,e22,e23,e01,e02,e11,e12,e24,e03,e13,m8,m0",
};

const failures = [];
let pass = 0;
function check(key, actual) {
  if (GOLDEN[key] === actual) pass++;
  else failures.push(`${key}\n    expected ${GOLDEN[key]}\n    actual   ${actual}`);
}
const ids = (arr) => arr.map((i) => i.ratingKey).join(",");

for (const [seed, day] of [[1, 20000], [49, 20431], [141, 20500]]) {
  const a = M.interleaveByShow(pool, seed, day);
  check(`INTER:${seed}:${day}`, ids(a));
  const b = M.promoteRecentlyAdded(a, DAY_START, seed);
  check(`PROMO:${seed}:${day}`, ids(b));
  check(`SEQ:${seed}:${day}`, ids(M.groupSequelParts(b)));
}

// Behavioural guards that don't depend on the golden vectors.
const twoInARow = M.interleaveByShow(pool, 7, 20000);
let run = 1, maxRun = 1;
for (let i = 1; i < twoInARow.length; i++) {
  if (twoInARow[i].type === "episode" && twoInARow[i].title === twoInARow[i - 1].title) run++;
  else run = 1;
  maxRun = Math.max(maxRun, run);
}
if (maxRun <= 2) pass++;
else failures.push(`interleave: ${maxRun} consecutive episodes of one show (max is 2)`);

// A lone "Part 2" with no sibling must not move.
const lone = [
  { ratingKey: "a", title: "Alien", type: "movie", duration: 100, addedAt: 0 },
  { ratingKey: "b", title: "Some Story Part 2", type: "movie", duration: 100, addedAt: 0 },
];
if (ids(M.groupSequelParts(lone)) === "a,b") pass++;
else failures.push("groupSequelParts moved a lone Part 2");

// Premieres land at the prime-time anchor, not at midnight.
const promo = M.promoteRecentlyAdded(pool.map((i, n) => ({ ...i, addedAt: n === 0 ? DAY_START - 3600 : 0 })), DAY_START, 1);
if (promo[0].ratingKey !== "e01" && promo.some((i) => i.ratingKey === "e01")) pass++;
else failures.push("promoteRecentlyAdded put a premiere at position 0 (should be the 7 PM anchor)");

console.log(`${pass} passed, ${failures.length} failed`);

// premiereOffset must match Swift exactly, or the same film premieres at a
// different hour on web than on Apple TV. Vectors from the Swift harness.
const OFFSETS = {
  "1:m0": 72900, "1:m4": 79200, "1:m8": 81000, "1:e01": 84600,
  "49:m0": 68400, "49:m4": 85500, "49:m8": 78300, "49:e01": 76500,
  "223:m0": 83700, "223:m4": 73800, "223:m8": 69300, "223:e01": 72000,
};
for (const [key, want] of Object.entries(OFFSETS)) {
  const [ch, rk] = key.split(":");
  const got = M.premiereOffset(Number(ch), rk);
  if (got !== want) failures.push(`premiereOffset(${ch}, ${rk}) = ${got}, Swift says ${want}`);
}

// A non-premiere channel must not promote recents at all, or one new film lands
// in prime time on every channel that carries it.
{
  const recentPool = pool.map((i, n) => ({ ...i, addedAt: n === 0 ? DAY_START - 3600 : 0 }));
  const plain = M.packDay(recentPool, DAY_START, 20000, 1, new Set(), false, null);
  const premiere = M.packDay(recentPool, DAY_START, 20000, 1, new Set(), true, null);
  if (JSON.stringify(plain) === JSON.stringify(premiere)) {
    failures.push("packDay ignored isPremiereChannel: premiere and non-premiere schedules are identical");
  }
}

// Neither seam may open a day with the title that just finished airing.
{
  const day = M.packDay(pool, DAY_START, 20000, 1, new Set(), false, null);
  const firstKey = day[0] && day[0].ratingKey;
  const guarded = M.packDay(pool, DAY_START, 20000, 1, new Set(), false, firstKey);
  if (guarded[0] && guarded[0].ratingKey === firstKey) {
    failures.push("cross-day seam: day opened with the same title that closed yesterday");
  }
  for (let i = 1; i < guarded.length; i++) {
    if (guarded[i].ratingKey === guarded[i - 1].ratingKey) {
      failures.push(`back-to-back repeat at block ${i} (${guarded[i].ratingKey})`);
      break;
    }
  }
}

if (failures.length) {
  failures.forEach((f) => console.error("  FAIL " + f));
  process.exit(1);
}
