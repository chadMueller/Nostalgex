#!/usr/bin/env node
/**
 * The control for scripts/qa/cross-channel-duplicates.mjs and
 * Nostalgex/NostalgexTests/CrossChannelDuplicateHarness.swift: a five-channel, two-day
 * "device" in the same on-disk shape as the real pull (library_snapshot/ + daily_manifests/),
 * with every overlap placed by hand, and the numbers a correct harness must report.
 *
 *   node scripts/qa/make-duplicates-control.mjs --out <dir> [--day 2026-01-15]
 *
 * Times are minutes from the local midnight of --day, so the control means the same thing in
 * any zone. A harness that cannot find these overlaps, or that finds ones that are not here,
 * is broken, and the real numbers mean nothing.
 *
 *   ch 1  A 0-720        B 720-1440
 *   ch 2  C 0-360        B 360-1080   E 1080-1440     B is on ch 1 and ch 2 from 720 to 1080
 *   ch 3  D 0-720        B' 720-1440                  B' is B under a second ratingKey (same TMDB id)
 *   ch 4  F 0-240        G 240-1440
 *   ch 5  F 0-240        H 240-1440                   F is on ch 4 and ch 5 from 0 to 240
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1]]);
  return acc;
}, []));
if (!args.out) { console.error("usage: --out <dir> [--day YYYY-MM-DD]"); process.exit(2); }
const DAY = args.day || "2026-01-15";
const [y, m, d] = DAY.split("-").map(Number);
const midnight = (extraDays) => Math.floor(new Date(y, m - 1, d + extraDays, 0, 0, 0).getTime() / 1000);
const dayKey = (extraDays) => { const t = new Date(y, m - 1, d + extraDays); return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}`; };
const FP = "control0000000000000000000000000000000000000000000000000000000000";
const SERVER = "ctl";

const film = (key, title, tmdb, minutes) => ({
  id: `${SERVER}:${key}`, ratingKey: key, serverID: SERVER, title, summary: "", year: 1999, duration: minutes,
  genres: [], rating: 0, userRating: 0, type: "movie", viewCount: 0, addedAt: 0, librarySource: "movie", tmdbID: tmdb,
});
const items = [
  film("A", "Alpha", "1", 720), film("B", "Bravo", "2", 720), film("Bp", "Bravo", "2", 720), film("C", "Charlie", "3", 360),
  film("D", "Delta", "4", 720), film("E", "Echo", "5", 360), film("F", "Foxtrot", "6", 240), film("G", "Golf", "7", 1200), film("H", "Hotel", "8", 1200),
];
const ix = Object.fromEntries(items.map((it, i) => [it.ratingKey, i]));
const layout = {
  1: [["A", 0, 720], ["B", 720, 1440]],
  2: [["C", 0, 360], ["B", 360, 1080], ["E", 1080, 1440]],
  3: [["D", 0, 720], ["Bp", 720, 1440]],
  4: [["F", 0, 240], ["G", 240, 1440]],
  5: [["F", 0, 240], ["H", 240, 1440]],
};
const names = { 1: "ONE", 2: "TWO", 3: "THREE", 4: "FOUR", 5: "FIVE" };

const root = args.out;
const gen = "g-control";
mkdirSync(`${root}/library_snapshot/${gen}`, { recursive: true });
mkdirSync(`${root}/daily_manifests/${FP}`, { recursive: true });
writeFileSync(`${root}/library_snapshot/current.json`, JSON.stringify({ format: 3, generation: gen, itemCount: items.length, chunkCount: 1 }));
writeFileSync(`${root}/library_snapshot/${gen}/items-0000.json`, JSON.stringify(items));
const rows = Object.keys(layout).map((id) => ({
  id: Number(id), number: Number(id), name: names[id], colorHex: "#FFE500", category: "control", minItems: 1,
  isPremiereChannel: false, enabled: true, itemRatingKeys: [],
}));
const pools = Object.values(layout).map((bl) => [...new Set(bl.map(([k]) => ix[k]))]);
writeFileSync(`${root}/library_snapshot/${gen}/meta.json`, JSON.stringify({ schemaVersion: 3, credentialFingerprint: FP, allChannelRows: rows, allChannelPools: pools }));
for (const [extra, key] of [[0, dayKey(0)], [1, dayKey(1)]]) {
  const base = midnight(extra);
  for (const [ch, bl] of Object.entries(layout)) {
    // The Apple TV keeps a stored day only while its pool fingerprint (SHA-256 of the sorted item ids,
    // DailyManifestStore.poolFingerprint) matches the pool it is asked about; otherwise it packs again.
    const poolIds = [...new Set(bl.map(([k]) => `${SERVER}:${k}`))].sort();
    const poolFingerprint = createHash("sha256").update(poolIds.join(",")).digest("hex");
    writeFileSync(`${root}/daily_manifests/${FP}/${ch}_${key}.json`, JSON.stringify({
      schemaVersion: 1, channelId: Number(ch), dayKey: key, credentialFingerprint: FP, poolFingerprint,
      blocks: bl.map(([k, a, b]) => ({ ratingKey: `${SERVER}:${k}`, startUnix: base + a * 60, endUnix: base + b * 60 })),
    }));
  }
}

// What a correct harness reports. Group-minutes: a title's minutes on 2 or more channels.
const expected = {
  days: [dayKey(0), dayKey(1)],
  sweep: {
    "id/all": { minutesWithAnyDuplicate: 600, redundantChannelMinutes: 600 },
    "content/all": { minutesWithAnyDuplicate: 960, redundantChannelMinutes: 1320,
      duplicatedTitleMinutesSameRatingKey: 240, duplicatedTitleMinutesDifferentRatingKeys: 720 },
  },
  probes: [
    { atMinute: 180, note: "F on ch 4 and ch 5; ch 5 gives way and shows H next",
      rawDupTitles: 1, rawDupChannels: 2, rawContentDupTitles: 1, bumped: 1, shownDupTitles: 0, shownContentDupTitles: 0, tunePlaysTheTitleItGaveWay: 1, tunedDupTitles: 1, tunedDupChannels: 2 },
    { atMinute: 400, note: "nothing shared", rawDupTitles: 0, rawDupChannels: 0, rawContentDupTitles: 0, bumped: 0, shownDupTitles: 0, shownContentDupTitles: 0, tunePlaysTheTitleItGaveWay: 0, tunedDupTitles: 0, tunedDupChannels: 0 },
    { atMinute: 900, note: "B on ch 1 and ch 2, and B' on ch 3; ch 2 gives way, and B on ch 1 against B' on ch 3 survives it",
      rawDupTitles: 1, rawDupChannels: 2, rawContentDupTitles: 1, bumped: 1, shownDupTitles: 0, shownContentDupTitles: 1, tunePlaysTheTitleItGaveWay: 1, tunedDupTitles: 1, tunedDupChannels: 2 },
    { atMinute: 1200, note: "B on ch 1 and B' on ch 3: one film under two ratingKeys, which the id compare cannot see",
      rawDupTitles: 0, rawDupChannels: 0, rawContentDupTitles: 1, bumped: 0, shownDupTitles: 0, shownContentDupTitles: 1, tunePlaysTheTitleItGaveWay: 0, tunedDupTitles: 0, tunedDupChannels: 0 },
  ],
};
writeFileSync(`${root}/expected.json`, JSON.stringify(expected, null, 2));
console.log(`control written to ${root} (${DAY} and the day after)`);
