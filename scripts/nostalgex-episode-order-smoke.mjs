#!/usr/bin/env node
/**
 * EPISODE ORDER (I-103): the web engine airs what the Apple TV airs under each order.
 *
 *   1. scripts/nostalgex-daily-manifest.js against scripts/episode-order-golden.json (the
 *      Apple TV's answers, from NostalgexTests/EpisodeOrderTests.swift), byte for byte.
 *   2. CLASSIC RERUNS pairs are two consecutive episodes (across a season, wrapping at the end of
 *      the series, never with a stranger when a neighbour aired yesterday); SHUFFLE airs one
 *      episode of a show at a time; another channel cannot reorder a show.
 *   3. A day stored under one order is not served under another, and CLASSIC RERUNS keeps the
 *      fingerprint it always had.
 *
 * No network. Run: `npm run test:episode-order`.
 */
import { readFileSync } from "node:fs";
import { loadEngine, dump, canonical } from "./schedule-parity-dump.mjs";

const root = new URL("../", import.meta.url);
const golden = JSON.parse(readFileSync(new URL("scripts/episode-order-golden.json", root), "utf8"));

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `\n    ${detail}` : ""}`); };

// 1. Byte for byte.
check("the golden file has a SHUFFLE case", golden.cases.some((c) => c.fixture.episodeOrder === "shuffle"));
for (const c of golden.cases) {
  const got = canonical(dump(loadEngine(), c.fixture));
  const want = canonical(c.expect);
  let at = 0;
  while (at < got.length && got[at] === want[at]) at += 1;
  check(`${c.name}: byte for byte what the Apple TV airs`, got === want,
    `first difference at byte ${at}: web …${got.slice(Math.max(0, at - 60), at + 60)}…\n    apple …${want.slice(Math.max(0, at - 60), at + 60)}…`);
}

// 2. The ordering itself.
const { M } = loadEngine();
const ep = (show, season, n) => ({ ratingKey: `${show}-${season}-${n}`, title: show, type: "episode", duration: 22,
  seTag: `S${String(season).padStart(2, "0")}E${String(n).padStart(2, "0")}` });
// A: two seasons of three, listed out of order. B: six in one season. C: one episode.
const pool = [ep("A", 2, 2), ep("A", 1, 3), ep("A", 1, 1), ep("A", 2, 1), ep("A", 1, 2), ep("A", 2, 3),
  ...[1, 2, 3, 4, 5, 6].map((n) => ep("B", 1, n)), ep("C", 1, 1)];
const next = M.seriesNext(pool);
check("the last of a season is followed by the first of the next", next.get("A-1-3") === "A-2-1");
check("the last of the series is followed by the first", next.get("A-2-3") === "A-1-1");
check("a show with one episode has no pair", !next.has("C-1-1"));
check("series order: season then episode, the unnumbered last",
  M.inSeriesOrder([{ ratingKey: "x" }, { ratingKey: "b", seTag: "S02E01" }, { ratingKey: "e", seTag: "E05" }, { ratingKey: "a", seTag: "S01E09" }])
    .map((i) => i.ratingKey).join() === "e,a,b,x");
const runsOf = (ordered) => {
  const out = [];
  ordered.forEach((item, i) => {
    if (i > 0 && ordered[i - 1].title === item.title) out[out.length - 1].push(item.ratingKey);
    else out.push([item.ratingKey]);
  });
  return out;
};
let pairs = 0, badPairs = 0, longRuns = 0, shuffleDoubles = 0, missing = 0;
const starts = new Set();
const unplayed = pool.filter((i) => !["B-1-3", "A-1-2"].includes(i.ratingKey));
for (let day = 1; day <= 40; day++) {
  const classic = M.interleaveByShow(pool, 7, day);
  if (new Set(classic.map((i) => i.ratingKey)).size !== pool.length) missing += 1;
  starts.add(classic.find((i) => i.title === "B").ratingKey);
  for (const run of [...runsOf(classic), ...runsOf(M.interleaveByShow(unplayed, 7, day, "classic", next))]) {
    if (run.length > 2) longRuns += 1;
    if (run.length === 2) { pairs += 1; if (next.get(run[0]) !== run[1]) badPairs += 1; }
  }
  const shuffled = M.interleaveByShow(pool, 7, day, "shuffle");
  if (new Set(shuffled.map((i) => i.ratingKey)).size !== pool.length) missing += 1;
  shuffled.forEach((item, i) => {
    if (i > 0 && shuffled[i - 1].title === item.title && shuffled.slice(i + 1).some((x) => x.title !== item.title)) shuffleDoubles += 1;
  });
}
check("CLASSIC RERUNS: every pair is two consecutive episodes, with or without yesterday's left out", pairs > 300 && badPairs === 0, `${badPairs} of ${pairs}`);
check("CLASSIC RERUNS: never three of a show in a row", longRuns === 0);
check("CLASSIC RERUNS: a show starts at a different spot on different days", starts.size > 3);
check("SHUFFLE: one episode of a show at a time while another title waits", shuffleDoubles === 0);
check("every episode airs once in both orders", missing === 0);
{
  // Another channel has episode 1 on: the film goes first, and episodes 2 and 3 wait behind episode 1.
  const queue = [ep("B", 1, 1), ep("B", 1, 2), { ratingKey: "f1", title: "Film", type: "movie", duration: 90 }, ep("B", 1, 3)];
  const occupancy = { overlap: (key) => (key === "B-1-1" ? 500 : 0) };
  check("another channel cannot reorder a show", M.pickCandidate(queue, 100, () => 600, occupancy, 1, null, true, false, true) === 2);
  check("without the rule the next episode jumps ahead", M.pickCandidate(queue, 100, () => 600, occupancy, 1, null, true, false) === 1);
}

// 2b. A day packed with another channel in the way (the reviewer's cases, 2026-11-19).
{
  const occupancyOf = () => { const l = []; return { add: (ch, k, s, e) => l.push({ ch, k, s, e }),
    overlap: (k, s, e, ch) => l.reduce((n, x) => n + (x.k === k && x.ch !== ch ? Math.max(0, Math.min(e, x.e) - Math.max(s, x.s)) : 0), 0) }; };
  const e1 = (show, n, key, extra = {}) => ({ ratingKey: key || `${show}${n}`, title: show, type: "episode", duration: 22, seTag: `S01E${String(n).padStart(2, "0")}`, ...extra });
  const film = (k) => ({ ratingKey: k, title: k, type: "movie", duration: 22 });
  const savedTZ = process.env.TZ;
  process.env.TZ = "America/New_York";
  const dayStart = Math.floor(new Date(2026, 10, 19).getTime() / 1000), ch = 7;
  const aired = (pool, occ, dayNumber, n) => M.packDay(pool, dayStart, dayNumber, ch, new Set(), false, null, occ, false, 0).slice(0, n).map((b) => b.ratingKey);
  const follows = (pool) => M.seriesNext(pool);
  let splits = 0, chains = 0, tried = 0;
  for (let dayNumber = 20400; dayNumber < 20440; dayNumber++) {
    // Three shows; another channel has this channel's first programme on in the first slot only.
    let pool = []; for (const s of ["A", "B", "C"]) for (let n = 1; n <= 6; n++) pool.push(e1(s, n));
    let order = M.interleaveByShow(pool, ch, dayNumber);
    let occ = occupancyOf(); occ.add(99, order[0].ratingKey, dayStart, dayStart + 22 * 60);
    let got = aired(pool, occ, dayNumber, 12);
    const next = follows(pool);
    tried += 1;
    // Every first of a pair in the order as built is followed by its second on air.
    for (let i = 0; i + 1 < 12; i += 2) {
      const a = order[i].ratingKey, b = order[i + 1].ratingKey;
      if (next.get(a) === b && got.includes(a) && got[got.indexOf(a) + 1] !== b) splits += 1;
    }
    // One show and films; the show's first episode is on elsewhere in the first slot. Never three of the show in a
    // row while a film is still to come.
    pool = []; for (let n = 1; n <= 8; n++) pool.push(e1("A", n)); for (const f of ["F1", "F2", "F3"]) pool.push(film(f));
    order = M.interleaveByShow(pool, ch, dayNumber);
    occ = occupancyOf(); if (order[0].type === "episode") occ.add(99, order[0].ratingKey, dayStart, dayStart + 22 * 60);
    got = aired(pool, occ, dayNumber, 11);
    let run = 0;
    got.forEach((k, i) => { run = k.startsWith("A") ? run + 1 : 0; if (run > 2 && got.slice(i + 1).some((x) => x.startsWith("F"))) chains += 1; });
  }
  check("a programme picked ahead never splits a pair", tried === 40 && splits === 0, `${splits} split`);
  check("a programme picked ahead never leaves two pairs of a show back to back", chains === 0, `${chains}`);
  // "Keep the pair whole" (Chad, 2026-11-19): the second of a pair airs straight after the first even when another
  // channel has that episode on; one episode on two channels now and then is accepted.
  {
    const pool = []; for (const s of ["A", "B", "C"]) for (let n = 1; n <= 6; n++) pool.push(e1(s, n));
    const order = M.interleaveByShow(pool, ch, 20411);
    const occ = occupancyOf(); occ.add(99, order[1].ratingKey, dayStart, dayStart + 86400);
    const got = aired(pool, occ, 20411, 2);
    check("the pair is kept whole when another channel has its second episode on",
      follows(pool).get(order[0].ratingKey) === order[1].ratingKey && got[0] === order[0].ratingKey && got[1] === order[1].ratingKey, got.join(" "));
  }
  // Two shows with one title: by the show's id, else by year.
  for (const [label, extraA, extraB] of [["id", { showKey: "uk" }, { showKey: "us" }], ["year", { year: 1951 }, { year: 1967 }]]) {
    const pool = [1, 2, 3, 4].map((n) => e1("The Office", n, `uk${n}`, extraA)).concat([1, 2, 3, 4].map((n) => e1("The Office", n, `us${n}`, extraB)));
    const got = aired(pool, null, 20411, 8);
    const next = follows(pool);
    let ok = new Set(got).size === 8;
    for (let i = 0; i < 8; i += 2) if (next.get(got[i]) !== got[i + 1] || got[i].slice(0, 2) !== got[i + 1].slice(0, 2)) ok = false;
    check(`two shows with one title, told apart by ${label}, each air their own pairs`, ok, got.join(" "));
  }
  // A show held twice under one id: one copy of each episode airs.
  {
    const pool = [];
    for (let n = 1; n <= 4; n++) { pool.push(e1("Echo", n, `hd${n}`, { showKey: "e" })); pool.push(e1("Echo", n, `uhd${n}`, { showKey: "e" })); }
    for (let n = 1; n <= 4; n++) pool.push(e1("Foxtrot", n, `f${n}`, { showKey: "f" }));
    const got = aired(pool, null, 20411, 30);
    check("a second copy of an episode does not air", !got.some((k) => k.startsWith("uhd")) && ["hd1", "hd2", "hd3", "hd4"].every((k) => got.includes(k)), got.slice(0, 10).join(" "));
    M.setEpisodeOrder("shuffle");
    const shuffled = aired(pool, null, 20411, 30);
    M.setEpisodeOrder("classic");
    check("nor under SHUFFLE", !shuffled.some((k) => k.startsWith("uhd")));
    const unnumbered = [1, 2, 3].map((n) => ({ ratingKey: `g${n}`, title: "Golf", type: "episode", duration: 22, seTag: "S01" }));
    check("a season with no episode numbers is kept whole", M.withoutSecondCopies(unnumbered).length === 3);
  }
  if (savedTZ === undefined) delete process.env.TZ; else process.env.TZ = savedTZ;
}

// 3. Stored days and the order.
{
  const { M: E, store } = loadEngine();
  const savedTZ = process.env.TZ;
  process.env.TZ = "America/New_York";
  const channel = { id: 7, number: 7, isPremiereChannel: false, timeRestrictions: null };
  E.setLineup([{ channel, pool }]);
  const at = Date.UTC(2026, 10, 19, 17);
  const keys = (blocks) => blocks.map((b) => b.item.ratingKey).join(",");
  const classic = keys(E.getManifestBlocks(channel, pool, at, "smoke"));
  const storedClassic = [...store.values()].join("");
  check("CLASSIC RERUNS adds nothing to a stored day's fingerprint", !storedClassic.includes("order="));
  E.setEpisodeOrder("shuffle");
  const shuffled = keys(E.getManifestBlocks(channel, pool, at, "smoke"));
  check("a day stored under CLASSIC RERUNS is packed again under SHUFFLE", shuffled !== classic);
  E.setEpisodeOrder("classic");
  check("and back again gives the CLASSIC RERUNS day", keys(E.getManifestBlocks(channel, pool, at, "smoke")) === classic);
  E.setEpisodeOrder("nonsense");
  check("an unknown order is CLASSIC RERUNS", E.getEpisodeOrder() === "classic");
  if (savedTZ === undefined) delete process.env.TZ; else process.env.TZ = savedTZ;
}

if (failures.length) {
  console.error(`episode order: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`episode order: ${passed} checks passed`);
