#!/usr/bin/env node
/**
 * Cross-channel duplicates, packed again: what a day looks like under a given schedule engine,
 * from the same library and the same history a device had.
 *
 * Reads a device pull (the layout scripts/qa/cross-channel-duplicates.mjs documents), seeds the
 * engine's store with the device's manifests for --history (the day before), then lets the
 * engine pack --day and the day after for every channel, the way the guide asks for them. With
 * the engine the device ran, the packed day must equal the device's own manifest for it, block
 * for block: that is checked first (--expect-device), so the numbers after it describe what the
 * device airs, not a model of it.
 *
 * Then, over --day: the share of minutes with one title on two or more channels at once and
 * the redundant channel-minutes, by ratingKey, by content identity (one film under two
 * ratingKeys: TMDB, IMDb or title and year) and by show; the same at each minute through the
 * engine's own buildSchedule (which sees the night before running past midnight); how many
 * blocks differ from the device's; and the time the engine takes to pack the lineup's day.
 *
 *   TZ=America/New_York node scripts/qa/cross-channel-repack.mjs --data <dir> \
 *     --history 2026-10-31 --day 2026-11-01 --built-at 2026-10-31T16:14:21-04:00 \
 *     [--engine <file>] [--lineup on|off] [--lookahead N] [--expect-device] [--runs 5] [--out f.json]
 *
 * --built-at: when the device packed --day (the hour decides time-gated pools, VHS VAULT's
 * R-rated hold before 9 PM). --engine: default the tree's scripts/nostalgex-daily-manifest.js.
 * --lineup off packs each channel alone (the engine before 2026-11-01 has no setLineup).
 * Nothing from the data is written next to this file. Do not commit reports.
 */
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { loadEngine } from "../schedule-parity-dump.mjs";

const require = createRequire(import.meta.url);
const filter = require("../nostalgex-channel-filter.cjs");

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : "true"]);
  return acc;
}, []));
for (const k of ["data", "history", "day", "built-at"]) if (!args[k]) { console.error(`--${k} is required`); process.exit(2); }
const DATA = args.data;
const RUNS = Number(args.runs || 3);
const BUILT_AT = Date.parse(args["built-at"]);
const useLineup = (args.lineup || "on") !== "off";

let source = readFileSync(args.engine || new URL("../nostalgex-daily-manifest.js", import.meta.url), "utf8");
if (args.lookahead) {
  const patched = source.replace(/const LOOKAHEAD = \d+;/, `const LOOKAHEAD = ${Number(args.lookahead)};`);
  if (patched === source) { console.error("--lookahead: this engine has no LOOKAHEAD"); process.exit(2); }
  source = patched;
}

// ── the device's library and lineup ────────────────────────────────────────────────────────
const gen = readdirSync(`${DATA}/library_snapshot`).find((n) => n.startsWith("g-"));
const meta = JSON.parse(readFileSync(`${DATA}/library_snapshot/${gen}/meta.json`));
let items = [];
for (const f of readdirSync(`${DATA}/library_snapshot/${gen}`).filter((n) => n.startsWith("items-")).sort())
  items = items.concat(JSON.parse(readFileSync(`${DATA}/library_snapshot/${gen}/${f}`)));
// The engine's ratingKey is the server's (the premiere slot hashes it); the device's
// manifests store the app's item id (server id and ratingKey). One server here, so one maps
// to the other.
const rkOfId = new Map(items.map((i) => [i.id, String(i.ratingKey)]));
const byId = new Map(items.map((i) => [String(i.ratingKey), i]));
if (byId.size !== items.length) { console.error("ratingKeys repeat: more than one server in this pull"); process.exit(2); }
const fpDir = readdirSync(`${DATA}/daily_manifests`).find((n) => !n.startsWith("."));
const rows = meta.allChannelRows;

/** Channel.filteredPool at `hour`: the channel's own rating hold and TV-only morning, as the device applies them. */
function timeFiltered(row, pool, hour) {
  const tr = row.timeRestrictions;
  if (!tr) return pool;
  let out = pool;
  if (tr.blockRatings) {
    const br = tr.blockRatings;
    const blocked = (br.blockBefore != null && hour < br.blockBefore) || (br.blockAfter != null && hour >= br.blockAfter);
    if (blocked) {
      const f = out.filter((it) => !br.ratings.includes(filter.usContentRating(it.contentRating, it.type) ?? ""));
      if (f.length >= 2) out = f;
    }
  }
  if (tr.tvOnlyBefore != null && hour < tr.tvOnlyBefore) {
    const eps = out.filter((it) => it.type === "episode");
    if (eps.length >= 2) out = eps;
  }
  if (tr.onlyAfterHour != null && hour < tr.onlyAfterHour) return [];
  return out;
}
const hour = new Date(BUILT_AT).getHours();
const lineup = rows.map((row, i) => ({
  channel: { id: row.id, number: row.number, isPremiereChannel: Boolean(row.isPremiereChannel), timeRestrictions: row.timeRestrictions || null },
  pool: timeFiltered(row, meta.allChannelPools[i].map((ix) => items[ix]), hour)
    .map((it) => ({ ratingKey: String(it.ratingKey), title: it.title, type: it.type === "episode" ? "episode" : "movie", duration: it.duration, addedAt: it.addedAt || 0 }))
    .filter((it) => it.duration > 0),
}));
const deviceDay = (day) => Object.fromEntries(rows.map((r) => {
  try { return [r.id, JSON.parse(readFileSync(`${DATA}/daily_manifests/${fpDir}/${r.id}_${day}.json`)).blocks.map((b) => [rkOfId.get(b.ratingKey) ?? b.ratingKey, b.startUnix, b.endUnix])]; }
  catch { return [r.id, null]; }
}));
const history = deviceDay(args.history);
const device = deviceDay(args.day);

const dayMs = (d) => { const [y, m, dd] = d.split("-").map(Number); return new Date(y, m - 1, dd, 0, 0, 0).getTime(); };
const ds = dayMs(args.day) / 1000;
const de = new Date(new Date(ds * 1000).setDate(new Date(ds * 1000).getDate() + 1)).getTime() / 1000;
const SK = "repack";

function fresh() {
  const engine = loadEngine(source);
  for (const r of rows) {
    if (!history[r.id]) continue;
    engine.store.set(`plex90_manifest_${SK}_${r.id}_${args.history}`, JSON.stringify({
      schemaVersion: 0, channelId: r.id, dayKey: args.history, poolFingerprint: "history",
      blocks: history[r.id].map(([k, s, e]) => ({ ratingKey: k, startSec: s, endSec: e })),
    }));
  }
  if (useLineup) {
    if (typeof engine.M.setLineup !== "function") { console.error("this engine has no setLineup; use --lineup off"); process.exit(2); }
    engine.M.setLineup(lineup);
  }
  return engine;
}

// ── pack the day the way the guide asks: every channel, in guide order ─────────────────────
const timings = [];
let engine;
for (let r = 0; r < RUNS; r++) {
  engine = fresh();
  const t0 = process.hrtime.bigint();
  for (const { channel, pool } of lineup) engine.M.getManifestBlocks(channel, pool, (ds + 3600) * 1000, SK);
  timings.push(Number(process.hrtime.bigint() - t0) / 1e6);
}
// An instrumented engine (one that hangs counters on __count) says how much work the day took.
const workCounts = engine.M.__count ? JSON.parse(JSON.stringify(engine.M.__count)) : null;
const { M } = engine;
for (const { channel, pool } of lineup) M.getManifestBlocks(channel, pool, (de + 3600) * 1000, SK); // the day after, for the 24-hour window
const packed = Object.fromEntries(lineup.map(({ channel, pool }) =>
  [channel.id, M.getManifestBlocks(channel, pool, (ds + 3600) * 1000, SK).map((b) => [b.item.ratingKey, b.startSec, b.endSec])]));

// ── against the device ────────────────────────────────────────────────────────────────────
let sameChannels = 0, blocksDiffer = 0, blocksTotal = 0, firstChangeMinutes = [];
for (const r of rows) {
  const a = packed[r.id] || [], b = device[r.id] || [];
  if (JSON.stringify(a) === JSON.stringify(b)) { sameChannels++; blocksTotal += b.length; continue; }
  let i = 0;
  while (i < a.length && i < b.length && JSON.stringify(a[i]) === JSON.stringify(b[i])) i++;
  if (process.env.NX_DEBUG) console.error("differs", r.id, r.name, JSON.stringify(a.slice(i, i + 2)), JSON.stringify(b.slice(i, i + 2)));
  firstChangeMinutes.push(Math.round(((a[i] || b[i] || [0, ds])[1] - ds) / 60));
  const key = (x) => x.join("|");
  const sb = new Set(b.map(key));
  blocksDiffer += a.filter((x) => !sb.has(key(x))).length;
  blocksTotal += b.length;
}
const vsDevice = {
  channelsIdentical: sameChannels, channels: rows.length,
  blocksNotOnTheDevice: blocksDiffer, deviceBlocks: blocksTotal,
  changedChannelsFirstChangeMinuteMedian: firstChangeMinutes.length ? firstChangeMinutes.sort((x, y) => x - y)[Math.floor(firstChangeMinutes.length / 2)] : null,
};
if (args["expect-device"] && sameChannels !== rows.length) {
  console.error(`FAIL the engine does not reproduce the device: ${rows.length - sameChannels} channels differ`);
  console.error(JSON.stringify(vsDevice));
  process.exit(1);
}

// ── duplicates ────────────────────────────────────────────────────────────────────────────
const norm = (s) => String(s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const category = (it) => it.type === "episode" ? "episode" : it.librarySource === "musicVideo" ? "musicVideo" : "movie";
const parent = new Map();
const find = (x) => { while (parent.get(x) !== x) { parent.set(x, parent.get(parent.get(x))); x = parent.get(x); } return x; };
const union = (a, b) => { for (const n of [a, b]) if (!parent.has(n)) parent.set(n, n); parent.set(find(a), find(b)); };
for (const it of items) {
  const node = `id:${it.ratingKey}`; parent.set(node, node);
  const c = category(it);
  const toks = c === "movie" ? [it.tmdbID && `tmdb:${it.tmdbID}`, it.imdbID && `imdb:${it.imdbID}`, it.year && `ty:${norm(it.title)}|${it.year}`]
    : c === "episode" ? [`ep:${norm(it.title)}|${it.seTag || norm(it.episodeTitle)}`] : [`mv:${norm(it.artist)}|${norm(it.title)}`];
  for (const t of toks.filter(Boolean)) union(node, t);
}
const KEYS = { id: (k) => k, content: (k) => find(`id:${k}`), show: (k) => (category(byId.get(k)) === "episode" ? `show:${norm(byId.get(k).title)}` : null) };

function sweep(blocksByChannel) {
  const pts = new Set([ds, de]);
  for (const bl of Object.values(blocksByChannel)) for (const [, s, e] of bl) { if (s > ds && s < de) pts.add(s); if (e > ds && e < de) pts.add(e); }
  const sorted = [...pts].sort((a, b) => a - b);
  const out = {};
  for (const k of Object.keys(KEYS)) out[k] = { anySec: 0, redundantSec: 0, movieSec: 0, episodeSec: 0, musicVideoSec: 0 };
  for (let p = 0; p < sorted.length - 1; p++) {
    const a = sorted[p], dur = sorted[p + 1] - a;
    const air = [];
    for (const [c, bl] of Object.entries(blocksByChannel)) { const b = bl.find((x) => x[1] <= a && x[2] > a); if (b) air.push([c, b[0]]); }
    for (const [name, fn] of Object.entries(KEYS)) {
      const g = new Map();
      for (const [c, k] of air) { const key = fn(k); if (!key) continue; if (!g.has(key)) g.set(key, []); g.get(key).push(k); }
      let any = false;
      const cats = new Set();
      for (const v of g.values()) if (v.length > 1) { any = true; out[name].redundantSec += (v.length - 1) * dur; cats.add(category(byId.get(v[0]))); }
      if (any) out[name].anySec += dur;
      for (const c of cats) out[name][`${c}Sec`] += dur;
    }
  }
  const daySec = de - ds;
  return Object.fromEntries(Object.entries(out).map(([k, v]) => [k, {
    shareOfMinutesWithADoubledTitle: +(v.anySec / daySec).toFixed(4),
    redundantChannelMinutes: Math.round(v.redundantSec / 60),
    shareMovie: +(v.movieSec / daySec).toFixed(4), shareEpisode: +(v.episodeSec / daySec).toFixed(4), shareMusicVideo: +(v.musicVideoSec / daySec).toFixed(4),
  }]));
}

/** What is on at each minute by the engine's own buildSchedule (yesterday's overrun included). */
function instants() {
  let dup = 0, n = 0, chDup = 0;
  for (let t = ds; t < de; t += 60) {
    const g = new Map();
    for (const { channel, pool } of lineup) {
      const s = M.buildSchedule(channel, pool, t, SK);
      if (!s || !s.nowPlaying) continue;
      const k = s.nowPlaying.item.ratingKey;
      g.set(k, (g.get(k) || 0) + 1);
    }
    let any = false;
    for (const v of g.values()) if (v > 1) { any = true; chDup += v; }
    if (any) dup++;
    n++;
  }
  return { minutes: n, shareOfMinutesWithADoubledTitle: +(dup / n).toFixed(4), meanChannelsOnADoubledTitle: +(chDup / n).toFixed(2) };
}

/** The same title back to back on one channel, and a later part before an earlier one. */
function quality(blocksByChannel) {
  let backToBack = 0, partOrder = 0;
  const mark = (k) => { const it = byId.get(k); const m = it && it.type !== "episode" && /^(.*?)[\s:,-]+(?:part|pt\.?)\s*([0-9]{1,2})\s*$/i.exec(it.title || ""); return m ? [m[1].toLowerCase().trim(), +m[2]] : null; };
  for (const bl of Object.values(blocksByChannel)) {
    for (let i = 1; i < bl.length; i++) if (bl[i][0] === bl[i - 1][0]) backToBack++;
    for (let i = 1; i < bl.length; i++) { const a = mark(bl[i - 1][0]), b = mark(bl[i][0]); if (a && b && a[0] === b[0] && b[1] < a[1]) partOrder++; }
  }
  return { sameTitleBackToBack: backToBack, laterPartRightBeforeEarlier: partOrder };
}

const report = {
  engine: args.engine || "tree", lineup: useLineup, lookahead: args.lookahead ? Number(args.lookahead) : "engine default",
  channels: rows.length,
  packLineupDayMs: { runs: timings.map((x) => +x.toFixed(0)), median: +[...timings].sort((a, b) => a - b)[Math.floor(timings.length / 2)].toFixed(0) },
  vsDevice,
  sweep: sweep(packed),
  deviceSweep: sweep(Object.fromEntries(Object.entries(device).filter(([, v]) => v))),
  instants: instants(),
  quality: quality(packed),
  workCounts,
};
/** The overlaps left, by ratingKey: who, what, when, and how big each channel's pool is. */
function residual(blocksByChannel) {
  const out = [];
  const ids = Object.keys(blocksByChannel);
  const poolSize = new Map(lineup.map((e) => [String(e.channel.id), e.pool.length]));
  for (let x = 0; x < ids.length; x++) for (let y = x + 1; y < ids.length; y++) {
    for (const a of blocksByChannel[ids[x]]) for (const b of blocksByChannel[ids[y]]) {
      if (a[0] !== b[0]) continue;
      const lo = Math.max(a[1], b[1], ds), hi = Math.min(a[2], b[2], de);
      if (hi > lo) out.push({ channels: [ids[x], ids[y]], pools: [poolSize.get(ids[x]), poolSize.get(ids[y])], minutes: Math.round((hi - lo) / 60), atMinute: Math.round((lo - ds) / 60), category: category(byId.get(a[0])) });
    }
  }
  return out.sort((p, q) => q.minutes - p.minutes);
}
report.residualOverlaps = residual(packed);

/**
 * For each overlap left, the channel that packed second at the block's start: every programme
 * in its pool, how much of its slot another channel has it on, and whether it aired yesterday
 * (then it waits for the filler loop). Says why nothing else fit.
 */
function explain(blocksByChannel) {
  return report.residualOverlaps.map((o) => {
    const later = o.channels[1];
    const entry = lineup.find((e) => String(e.channel.id) === later);
    const bl = blocksByChannel[later];
    const block = bl.find((b) => b[1] <= ds + o.atMinute * 60 + 30 && b[2] > ds + o.atMinute * 60 + 30) || bl[0];
    const t = block[1], idx = bl.indexOf(block);
    const aired = new Set((history[later] || []).map((b) => b[0]));
    const others = (k, s, e) => { let sec = 0; for (const [c, cb] of Object.entries(blocksByChannel)) if (c !== later) for (const b of cb) if (b[0] === k) sec += Math.max(0, Math.min(e, b[2]) - Math.max(s, b[1])); return Math.round(sec / 60); };
    return {
      channel: later, blockIndex: idx, blocksToday: bl.length, slotStartMinute: Math.round((t - ds) / 60),
      candidates: entry.pool.map((it) => ({ minutes: it.duration, overlapMinutes: others(it.ratingKey, t, t + it.duration * 60), airedYesterday: aired.has(it.ratingKey), airedEarlierToday: bl.slice(0, idx).some((b) => b[0] === it.ratingKey), isThisOne: it.ratingKey === block[0] })),
    };
  });
}
if (args.explain) report.explain = explain(packed);
// The packed day in the app's own keys (server id and ratingKey), to diff with the Swift
// harness (CrossChannelDuplicateHarness.testRepackOnDeviceData).
if (args["dump-packed"]) writeFileSync(args["dump-packed"], JSON.stringify(Object.fromEntries(Object.entries(packed)
  .map(([c, bl]) => [c, bl.map(([k, s, e]) => [byId.get(k).id, s, e])]))));
if (args.out) writeFileSync(args.out, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
