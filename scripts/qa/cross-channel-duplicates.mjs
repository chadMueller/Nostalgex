#!/usr/bin/env node
/**
 * Cross-channel duplicates: how often is one title on air on two channels at once, and what
 * does the app's conflict handling do about it.
 *
 * It reads what an Apple TV actually holds, pulled read-only from the device:
 *
 *   xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
 *     --domain-identifier com.muellhaus.nostalgex \
 *     --source Library/Caches/Nostalgex/library_snapshot --destination <dir>/library_snapshot
 *   (same for daily_manifests)
 *
 * and runs the web engine (scripts/nostalgex-daily-manifest.js, parity-tested against the
 * Apple TV: ChannelScheduleBuilder.resolveConflicts, findConflict, AppState.selectChannel and
 * advanceToNextItem are its mirrors) over the device's own manifests. The Swift side of the
 * same measurement is NostalgexTests/CrossChannelDuplicateHarness.swift.
 *
 * Nothing from the data is written next to this file: the report goes to --out, and the data
 * is private (a user's library). Do not commit either.
 *
 *   TZ=America/New_York node scripts/qa/cross-channel-duplicates.mjs \
 *     --data <dir> --days 2026-10-31,2026-11-01 --at 2026-10-31T16:14:21-04:00 \
 *     [--step 60] [--advance-every 1] [--shuffles 200] [--top 15] [--out report.json]
 *
 * --days: local days with a manifest on the device; the first is the day sampled minute by
 * minute (the second must exist so the last block's next programme is known).
 */
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { loadEngine } from "../schedule-parity-dump.mjs";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : "true"]);
  return acc;
}, []));
if (!args.data) { console.error("usage: --data <dir with library_snapshot/ and daily_manifests/> --days D1,D2 [--at ISO]"); process.exit(2); }
const DATA = args.data;
const DAYS = (args.days || "").split(",").filter(Boolean);
if (DAYS.length < 2) { console.error("--days needs two consecutive local days, e.g. 2026-10-31,2026-11-01"); process.exit(2); }
const STEP = Number(args.step || 60);
const ADV_EVERY = Number(args["advance-every"] || 1);
const SHUFFLES = Number(args.shuffles || 200);
const TOP = Number(args.top || 15);
const AT = args.at ? Date.parse(args.at) / 1000 : null;

// ── load what the device holds ────────────────────────────────────────────────────────────

const gen = readdirSync(`${DATA}/library_snapshot`).find((n) => n.startsWith("g-"));
const meta = JSON.parse(readFileSync(`${DATA}/library_snapshot/${gen}/meta.json`));
let items = [];
for (const f of readdirSync(`${DATA}/library_snapshot/${gen}`).filter((n) => n.startsWith("items-")).sort())
  items = items.concat(JSON.parse(readFileSync(`${DATA}/library_snapshot/${gen}/${f}`)));
const byId = new Map(items.map((i) => [i.id, i]));
const fpDir = readdirSync(`${DATA}/daily_manifests`).find((n) => !n.startsWith("."));
const rows = meta.allChannelRows;
const chName = new Map(rows.map((r) => [r.id, `${r.number} ${r.name}`]));
const category = (it) => it.type === "episode" ? "episode" : it.librarySource === "musicVideo" ? "musicVideo" : "movie";
const norm = (s) => String(s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

// Content identity: the union of every token that says "this is the same film/episode/video".
// Two library items that share any token are one piece of content under two ratingKeys.
const parent = new Map();
const find = (x) => { while (parent.get(x) !== x) { parent.set(x, parent.get(parent.get(x))); x = parent.get(x); } return x; };
const union = (a, b) => { if (!parent.has(a)) parent.set(a, a); if (!parent.has(b)) parent.set(b, b); parent.set(find(a), find(b)); };
function tokens(it) {
  const c = category(it);
  if (c === "movie") return [it.tmdbID && `tmdb:${it.tmdbID}`, it.imdbID && `imdb:${it.imdbID}`, it.year && `ty:${norm(it.title)}|${it.year}`].filter(Boolean);
  if (c === "episode") return [`ep:${norm(it.title)}|${it.seTag || norm(it.episodeTitle)}`];
  return [`mv:${norm(it.artist)}|${norm(it.title)}`];
}
for (const it of items) {
  const t = tokens(it);
  const node = `id:${it.id}`;
  parent.set(node, node);
  for (const x of t) union(node, x);
}
const contentOf = (id) => find(`id:${id}`);
const showOf = (id) => { const it = byId.get(id); return category(it) === "episode" ? `show:${norm(it.title)}` : null; };
const KEYS = { id: (id) => id, content: contentOf, show: showOf };

// ── library census ───────────────────────────────────────────────────────────────────────

const census = {};
for (const cat of ["movie", "episode", "musicVideo"]) {
  const its = items.filter((i) => category(i) === cat);
  const groups = new Map();
  for (const i of its) { const k = contentOf(i.id); groups.set(k, (groups.get(k) || 0) + 1); }
  const multi = [...groups.values()].filter((n) => n > 1);
  census[cat] = { items: its.length, contentGroups: groups.size, groupsWithMoreThanOneRatingKey: multi.length, itemsInThem: multi.reduce((a, b) => a + b, 0) };
}
const poolCount = new Map();
rows.forEach((r, i) => { for (const ix of meta.allChannelPools[i]) poolCount.set(items[ix].id, (poolCount.get(items[ix].id) || 0) + 1); });
const hist = (cat) => {
  const h = {};
  for (const it of items.filter((i) => category(i) === cat)) { const n = Math.min(poolCount.get(it.id) || 0, 6); h[n] = (h[n] || 0) + 1; }
  return h;
};
const poolMembership = { movie: hist("movie"), episode: hist("episode"), musicVideo: hist("musicVideo"), note: "channels carrying the item; 6 means 6 or more" };

// ── device manifests ─────────────────────────────────────────────────────────────────────

const manifests = {}; // day -> channelId -> [{id, s, e}]
for (const d of DAYS) {
  manifests[d] = {};
  for (const r of rows) {
    const j = JSON.parse(readFileSync(`${DATA}/daily_manifests/${fpDir}/${r.id}_${d}.json`));
    manifests[d][r.id] = j.blocks.map((b) => ({ id: b.ratingKey, s: b.startUnix, e: b.endUnix }));
  }
}
const dayStartSec = (d) => { const [y, m, dd] = d.split("-").map(Number); return Math.floor(new Date(y, m - 1, dd, 0, 0, 0).getTime() / 1000); };
const dayEndSec = (d) => { const [y, m, dd] = d.split("-").map(Number); return Math.floor(new Date(y, m - 1, dd + 1, 0, 0, 0).getTime() / 1000); };

// ── sweep: exact, by elementary interval ─────────────────────────────────────────────────

/** blocksByChannel: Map(channelId -> [{id,s,e}]) already clipped to [ds, de). */
function sweep(blocksByChannel, ds, de, wantEvents) {
  const bounds = new Set([ds, de]);
  for (const bl of blocksByChannel.values()) for (const b of bl) { bounds.add(b.s); bounds.add(b.e); }
  const pts = [...bounds].filter((x) => x >= ds && x <= de).sort((a, b) => a - b);
  const chans = [...blocksByChannel.keys()];
  const ptr = new Map(chans.map((c) => [c, 0]));
  const acc = {};
  for (const k of Object.keys(KEYS)) for (const cat of ["all", "movie", "episode", "musicVideo"])
    acc[`${k}/${cat}`] = { anySec: 0, redundantChannelSec: 0, affectedChannelSec: 0, sameIdSec: 0, differentIdSec: 0, maxGroups: 0, groupSecSum: 0 };
  const events = { id: [], content: [], show: [] }; // [key, s, e, channels[]]
  const open = { id: new Map(), content: new Map(), show: new Map() };
  const perInstant = []; // for the sampled-grid metric: [s, e, idDup(bool)]
  for (let p = 0; p < pts.length - 1; p++) {
    const a = pts[p], b = pts[p + 1], dur = b - a;
    if (dur <= 0) continue;
    const air = []; // [channelId, id]
    for (const c of chans) {
      const bl = blocksByChannel.get(c);
      let i = ptr.get(c);
      while (i < bl.length && bl[i].e <= a) i++;
      ptr.set(c, i);
      if (i < bl.length && bl[i].s <= a && bl[i].e > a) air.push([c, bl[i].id]);
    }
    for (const kt of Object.keys(KEYS)) {
      const groups = new Map();
      for (const [c, id] of air) {
        const k = KEYS[kt](id);
        if (!k) continue;
        if (!groups.has(k)) groups.set(k, []);
        groups.get(k).push([c, id]);
      }
      const dups = [...groups.entries()].filter(([, v]) => v.length > 1);
      const byCat = { all: [], movie: [], episode: [], musicVideo: [] };
      for (const [k, v] of dups) { byCat.all.push([k, v]); byCat[category(byId.get(v[0][1]))].push([k, v]); }
      for (const cat of Object.keys(byCat)) {
        const g = byCat[cat], A = acc[`${kt}/${cat}`];
        if (!g.length) continue;
        A.anySec += dur;
        A.groupSecSum += g.length * dur;
        A.maxGroups = Math.max(A.maxGroups, g.length);
        for (const [, v] of g) {
          A.redundantChannelSec += (v.length - 1) * dur;
          A.affectedChannelSec += v.length * dur;
          if (kt === "content") { if (new Set(v.map((x) => x[1])).size > 1) A.differentIdSec += dur; else A.sameIdSec += dur; }
        }
      }
      if (wantEvents) {
        const live = new Set(dups.map(([k]) => k));
        for (const [k, v] of dups) {
          const o = open[kt].get(k);
          const chs = v.map((x) => x[0]);
          if (!o) open[kt].set(k, { s: a, chs: new Set(chs) });
          else chs.forEach((c) => o.chs.add(c));
        }
        for (const [k, o] of [...open[kt].entries()]) if (!live.has(k)) { events[kt].push([k, o.s, a, [...o.chs]]); open[kt].delete(k); }
      }
    }
  }
  if (wantEvents) for (const kt of Object.keys(open)) for (const [k, o] of open[kt]) events[kt].push([k, o.s, de, [...o.chs]]);
  return { acc, events };
}

function clip(day) {
  const ds = dayStartSec(day), de = dayEndSec(day);
  const m = new Map();
  for (const [c, bl] of Object.entries(manifests[day])) m.set(Number(c), bl.map((b) => ({ ...b, s: Math.max(b.s, ds), e: Math.min(b.e, de) })).filter((b) => b.e > b.s));
  return { m, ds, de };
}
const mins = (s) => Math.round((s / 60) * 10) / 10;

const raw = {};
let eventsD1 = null;
for (const day of DAYS) {
  const { m, ds, de } = clip(day);
  const { acc, events } = sweep(m, ds, de, day === DAYS[0]);
  if (day === DAYS[0]) eventsD1 = events;
  const daySec = de - ds, nCh = m.size;
  const out = {};
  for (const [k, A] of Object.entries(acc)) {
    out[k] = {
      minutesWithAnyDuplicate: mins(A.anySec),
      shareOfDayWithAnyDuplicate: +(A.anySec / daySec).toFixed(4),
      redundantChannelMinutes: mins(A.redundantChannelSec),
      meanChannelsOnADuplicatedTitle: +(A.affectedChannelSec / daySec).toFixed(2),
      shareOfChannelMinutesOnADuplicatedTitle: +(A.affectedChannelSec / (daySec * nCh)).toFixed(4),
      meanDuplicatedTitlesAtOnce: +(A.groupSecSum / daySec).toFixed(2),
      maxDuplicatedTitlesAtOnce: A.maxGroups,
      ...(k.startsWith("content/") ? { duplicatedTitleMinutesSameRatingKey: mins(A.sameIdSec), duplicatedTitleMinutesDifferentRatingKeys: mins(A.differentIdSec) } : {}),
    };
  }
  raw[day] = { channels: nCh, dayMinutes: daySec / 60, metrics: out };
}

// Overlap events on the first day, by ratingKey: the top offenders.
const evId = eventsD1.id.map(([k, s, e, chs]) => ({ id: k, s, e, chs }));
const perTitle = new Map();
for (const ev of evId) {
  const t = perTitle.get(ev.id) || { id: ev.id, sec: 0, events: 0, channels: new Set(), spans: [] };
  t.sec += ev.e - ev.s; t.events++; ev.chs.forEach((c) => t.channels.add(c)); t.spans.push([ev.s, ev.e, ev.chs]);
  perTitle.set(ev.id, t);
}
const fmt = (s) => new Date(s * 1000).toLocaleTimeString("en-US", { hour12: false, hour: "2-digit", minute: "2-digit" });
const top = [...perTitle.values()].sort((a, b) => b.sec - a.sec).slice(0, TOP).map((t) => ({
  title: byId.get(t.id).title + (byId.get(t.id).seTag ? ` ${byId.get(t.id).seTag}` : ""),
  category: category(byId.get(t.id)),
  minutesOnTwoOrMoreChannels: mins(t.sec),
  overlaps: t.events,
  channels: [...t.channels].sort((a, b) => a - b).map((c) => chName.get(c)),
  poolsCarryingIt: poolCount.get(t.id),
  spans: t.spans.map(([s, e, chs]) => `${fmt(s)}-${fmt(e)} on channels ${chs.sort((a, b) => a - b).map((c) => rows.find((r) => r.id === c).number).join("+")}`),
}));
const catOf = new Map(rows.map((r) => [r.id, r.category || "none"]));
const involving = {}; let sameCategorySec = 0, totalEvSec = 0, franchiseSec = 0;
const isFranchise = (c) => c >= 1000000 || /^franchise/.test(catOf.get(c));
for (const ev of evId) {
  const sec = ev.e - ev.s; totalEvSec += sec;
  for (const cat of new Set(ev.chs.map((c) => catOf.get(c)))) involving[cat] = (involving[cat] || 0) + sec;
  if (new Set(ev.chs.map((c) => catOf.get(c))).size === 1) sameCategorySec += sec;
  if (ev.chs.some(isFranchise)) franchiseSec += sec;
}
const byChannelCategory = {
  note: "overlap minutes on the first day, by the category of the channels involved (an overlap counts once per category it involves)",
  minutesInvolvingCategory: Object.fromEntries(Object.entries(involving).sort((a, b) => b[1] - a[1]).map(([k, v]) => [k, mins(v)])),
  shareOfOverlapMinutesWithEveryChannelInOneCategory: totalEvSec ? +(sameCategorySec / totalEvSec).toFixed(3) : 0,
  shareOfOverlapMinutesInvolvingAFranchiseChannel: totalEvSec ? +(franchiseSec / totalEvSec).toFixed(3) : 0,
};
const idEventStats = {
  titlesWithAnOverlap: perTitle.size,
  overlapEvents: evId.length,
  medianOverlapMinutes: mins([...evId.map((e) => e.e - e.s)].sort((a, b) => a - b)[Math.floor(evId.length / 2)] || 0),
  byChannelCategory,
  overlapMinutesByCategory: (() => {
    const out = {};
    for (const cat of ["movie", "episode", "musicVideo"]) {
      const d = evId.filter((e) => category(byId.get(e.id)) === cat).map((e) => (e.e - e.s) / 60).sort((a, b) => a - b);
      if (!d.length) continue;
      out[cat] = { events: d.length, totalMinutes: +d.reduce((a, b) => a + b, 0).toFixed(0), median: +d[Math.floor(d.length / 2)].toFixed(1), p90: +d[Math.floor(d.length * 0.9)].toFixed(1), longest: +d[d.length - 1].toFixed(1) };
    }
    return out;
  })(),
  overlapEventsByCategory: evId.reduce((o, e) => { const c = category(byId.get(e.id)); o[c] = (o[c] || 0) + 1; return o; }, {}),
  titlesWithAnOverlapByNumberOfPoolsCarrying: [...perTitle.keys()].reduce((o, id) => { const n = Math.min(poolCount.get(id) || 0, 6); o[n] = (o[n] || 0) + 1; return o; }, {}),
};

// ── null model: the same day with every channel's day circularly shifted at random ─────────

function shuffledNull() {
  const { m, ds, de } = clip(DAYS[0]);
  const daySec = de - ds;
  const results = [];
  let seed = 12345;
  const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
  for (let n = 0; n < SHUFFLES; n++) {
    const shifted = new Map();
    for (const [c, bl] of m) {
      const off = Math.floor(rnd() * daySec);
      const out = [];
      for (const b of bl) {
        let s = b.s - ds + off, e = b.e - ds + off;
        if (s >= daySec) { s -= daySec; e -= daySec; }
        if (e > daySec) { out.push({ id: b.id, s: ds + s, e: ds + daySec }); out.push({ id: b.id, s: ds, e: ds + (e - daySec) }); }
        else out.push({ id: b.id, s: ds + s, e: ds + e });
      }
      out.sort((x, y) => x.s - y.s);
      shifted.set(c, out);
    }
    const { acc } = sweep(shifted, ds, de, false);
    results.push([acc["id/all"].anySec / daySec, acc["id/all"].redundantChannelSec / 60]);
  }
  const pick = (i) => results.map((r) => r[i]).sort((a, b) => a - b);
  const q = (arr, p) => arr[Math.floor(arr.length * p)];
  const mean = (arr) => arr.reduce((a, b) => a + b, 0) / arr.length;
  const share = pick(0), red = pick(1);
  return {
    trials: SHUFFLES,
    shareOfDayWithAnyDuplicate: { mean: +mean(share).toFixed(4), p5: +q(share, 0.05).toFixed(4), p95: +q(share, 0.95).toFixed(4) },
    redundantChannelMinutes: { mean: +mean(red).toFixed(0), p5: +q(red, 0.05).toFixed(0), p95: +q(red, 0.95).toFixed(0) },
  };
}
const nullModel = SHUFFLES > 0 ? shuffledNull() : null;

// ── the app's own handling, run by the real engine over the device's manifests ─────────────

const { M, store } = loadEngine();
const SK = "dev";
const poolFP = (pool) => { const keys = pool.map((i) => i.ratingKey).sort().join(","); let h = 0; for (let i = 0; i < keys.length; i++) h = ((h << 5) - h + keys.charCodeAt(i)) | 0; return String(h); };
const lineup = rows.map((row, i) => ({
  channel: { id: row.id, number: row.number, isPremiereChannel: Boolean(row.isPremiereChannel) },
  pool: meta.allChannelPools[i].map((ix) => { const it = items[ix]; return { ratingKey: it.id, title: it.title, type: it.type === "episode" ? "episode" : "movie", duration: it.duration, addedAt: it.addedAt || 0 }; }),
}));
for (const day of DAYS) for (const { channel, pool } of lineup) {
  const valid = pool.filter((i) => i.duration > 0);
  store.set(`plex90_manifest_${SK}_${channel.id}_${day}`, JSON.stringify({
    schemaVersion: 2, channelId: channel.id, dayKey: day, poolFingerprint: poolFP(valid),
    blocks: manifests[day][channel.id].map((b) => ({ ratingKey: b.id, startSec: b.s, endSec: b.e })),
  }));
}
// The seeded store must give back the device's blocks exactly.
{
  let bad = 0;
  for (const { channel, pool } of lineup) {
    const got = M.getManifestBlocks(channel, pool, (dayStartSec(DAYS[0]) + 43200) * 1000, SK).map((b) => `${b.item.ratingKey}|${b.startSec}|${b.endSec}`).join();
    const want = manifests[DAYS[0]][channel.id].map((b) => `${b.id}|${b.s}|${b.e}`).join();
    if (got !== want) bad++;
  }
  if (bad) { console.error(`seeding failed on ${bad} channels`); process.exit(1); }
}

function instant(t) {
  const rawMap = new Map();
  for (const { channel, pool } of lineup) { const s = M.buildSchedule(channel, pool, t, SK); if (s && s.nowPlaying) rawMap.set(channel.id, s); }
  const shown = M.resolveConflicts(new Map(rawMap));
  const group = (get) => { const g = new Map(); for (const [c, s] of rawMap) { const it = get(c, s); if (!it) continue; if (!g.has(it)) g.set(it, []); g.get(it).push(c); } return g; };
  const rawNow = (c) => rawMap.get(c).nowPlaying.item.ratingKey;
  const shownNow = (c) => shown.get(c).nowPlaying.item.ratingKey;
  const dupGroups = (g) => [...g.entries()].filter(([, v]) => v.length > 1);
  const rawG = dupGroups(group((c) => rawNow(c)));
  const shownG = dupGroups(group((c) => shownNow(c)));
  const shownContentG = dupGroups(group((c) => contentOf(shownNow(c))));
  const rawContentG = dupGroups(group((c) => contentOf(rawNow(c))));
  const bumped = [...rawMap.keys()].filter((c) => shownNow(c) !== rawNow(c));
  // Why a duplicate survives the bump.
  const cause = { bumpedChannelLandsOnAnotherChannelsTitle: 0, titleKeptByBothBecauseTheLoserHadNoNextProgramme: 0, winnerCollidedWithABumpedChannel: 0, other: 0 };
  for (const [, chs] of shownG) for (const c of chs) {
    const lowest = Math.min(...[...rawMap.keys()].filter((x) => rawNow(x) === rawNow(c)));
    if (bumped.includes(c)) cause.bumpedChannelLandsOnAnotherChannelsTitle++;
    else if (c !== lowest && shown.get(c).nowPlaying === rawMap.get(c).nowPlaying) cause.titleKeptByBothBecauseTheLoserHadNoNextProgramme++;
    else if (chs.some((x) => bumped.includes(x))) cause.winnerCollidedWithABumpedChannel++;
    else cause.other++;
  }
  // What tuning to each channel plays, given the guide's resolved schedule (selectChannel).
  const tuned = new Map();
  let tunePlaysTheTitleItGaveWay = 0;
  for (const { channel, pool } of lineup) {
    if (!shown.has(channel.id)) continue;
    const t1 = M.tuneIn(channel, pool, shown.get(channel.id), t, SK);
    if (t1) tuned.set(channel.id, t1.item.ratingKey);
    if (bumped.includes(channel.id) && t1 && t1.item.ratingKey === rawNow(channel.id)) tunePlaysTheTitleItGaveWay++;
  }
  const tg = new Map(); for (const [c, k] of tuned) { if (!tg.has(k)) tg.set(k, []); tg.get(k).push(c); }
  const tunedG = dupGroups(tg);
  const count = (g) => g.reduce((a, [, v]) => a + v.length, 0);
  return {
    t, channels: rawMap.size,
    rawDupTitles: rawG.length, rawDupChannels: count(rawG), rawContentDupTitles: rawContentG.length,
    bumped: bumped.length,
    shownDupTitles: shownG.length, shownDupChannels: count(shownG), shownContentDupTitles: shownContentG.length,
    cause, tunePlaysTheTitleItGaveWay, tunedDupTitles: tunedG.length, tunedDupChannels: count(tunedG),
    detail: { rawG, bumped, shownG, rawMap, shown },
  };
}

const sums = (arr, f) => arr.reduce((a, x) => a + f(x), 0);
const frac = (n, d) => +(n / d).toFixed(4);

const ds0 = dayStartSec(DAYS[0]), de0 = dayEndSec(DAYS[0]);
const samples = [];
const t0wall = Date.now();
for (let t = ds0; t < de0; t += STEP) { const r = instant(t); delete r.detail; samples.push(r); }
const sampleSeconds = (Date.now() - t0wall) / 1000;
const S = (f) => sums(samples, f);
const n = samples.length;
const instants = {
  samples: n, stepSeconds: STEP, wallSeconds: +sampleSeconds.toFixed(1), channelsPerInstant: samples[0].channels,
  raw: {
    shareOfInstantsWithAnyDuplicateTitle: frac(samples.filter((s) => s.rawDupTitles > 0).length, n),
    meanDuplicatedTitles: +(S((s) => s.rawDupTitles) / n).toFixed(2),
    meanChannelsOnADuplicatedTitle: +(S((s) => s.rawDupChannels) / n).toFixed(2),
    shareOfChannelInstantsOnADuplicatedTitle: frac(S((s) => s.rawDupChannels), n * samples[0].channels),
    contentShareOfInstantsWithAnyDuplicate: frac(samples.filter((s) => s.rawContentDupTitles > 0).length, n),
  },
  afterResolveConflicts: {
    meanChannelsBumped: +(S((s) => s.bumped) / n).toFixed(2),
    shareOfInstantsWithAnyDuplicateTitle: frac(samples.filter((s) => s.shownDupTitles > 0).length, n),
    meanDuplicatedTitles: +(S((s) => s.shownDupTitles) / n).toFixed(2),
    meanChannelsOnADuplicatedTitle: +(S((s) => s.shownDupChannels) / n).toFixed(2),
    shareOfChannelInstantsOnADuplicatedTitle: frac(S((s) => s.shownDupChannels), n * samples[0].channels),
    contentShareOfInstantsWithAnyDuplicate: frac(samples.filter((s) => s.shownContentDupTitles > 0).length, n),
    survivingDuplicateChannelInstantsByCause: Object.fromEntries(Object.keys(samples[0].cause).map((k) => [k, S((s) => s.cause[k])])),
  },
  whatTuningPlays: {
    note: "tuneIn() with the guide's resolved schedule, for every channel at every instant",
    meanBumpedChannelsThatStillPlayTheTitleTheyGaveWay: +(S((s) => s.tunePlaysTheTitleItGaveWay) / n).toFixed(2),
    shareOfInstantsWithAnyDuplicateTitle: frac(samples.filter((s) => s.tunedDupTitles > 0).length, n),
    meanChannelsOnADuplicatedTitle: +(S((s) => s.tunedDupChannels) / n).toFixed(2),
    shareOfChannelInstantsOnADuplicatedTitle: frac(S((s) => s.tunedDupChannels), n * samples[0].channels),
  },
};

// The guide grid: what the viewer sees in the visible two hours, resolved or not. resolveConflicts
// never edits the grid's entries (only flags one), so the grid is the raw schedule.
function gridMetric() {
  const ev = evId; // overlaps by ratingKey on the first day
  let onlyNow = 0, futureOnly = 0, both = 0, none = 0, total = 0;
  for (let t = ds0; t < de0; t += 1800) {
    const ws = t, we = ws + 7200;
    const now = ev.some((e) => e.s <= t + 1 && e.e > t + 1);
    const future = ev.some((e) => e.s > t + 1 && e.s < we);
    total++;
    if (now && future) both++; else if (now) onlyNow++; else if (future) futureOnly++; else none++;
  }
  const any = total - none;
  return { windows: total, windowsShowingTheSameTitleOnTwoRows: any, share: frac(any, total), overlappingAtTheCurrentHalfHour: onlyNow + both, overlappingOnlyLaterInTheTwoHours: futureOnly, noOverlap: none };
}
const grid = gridMetric();

// Natural end of a programme: what advanceToNextItem picks (findConflict and one skip), and
// whether the pick is already on another channel when it starts.
function advanceMetric() {
  let total = 0, skipped = 0, pickOnAnotherAtStart = 0, upNextWouldHaveBeen = 0, upNextEqualsOtherAtStartBeforeSkip = 0;
  let k = 0;
  const rawAt = new Map();
  const nowAt = (c, ch, t) => { const s = M.buildSchedule(ch.channel, ch.pool, t, SK); return s && s.nowPlaying ? s.nowPlaying.item.ratingKey : null; };
  for (const { channel, pool } of lineup) {
    const bl = manifests[DAYS[0]][channel.id];
    for (let i = 0; i < bl.length - 1; i++) {
      if ((k++ % ADV_EVERY) !== 0) continue;
      const b = bl[i];
      if (b.e > de0 - 120) continue;
      const tEarly = b.e - 30;
      const pick = M.advancePick(channel, pool, b.id, tEarly, lineup, SK, true);
      if (!pick) continue;
      total++;
      const atStart = b.e + 1;
      const key = `${atStart}`;
      if (!rawAt.has(key)) {
        const m2 = new Map();
        for (const l of lineup) m2.set(l.channel.id, nowAt(l.channel.id, l, atStart));
        rawAt.set(key, m2);
        if (rawAt.size > 50) rawAt.delete(rawAt.keys().next().value);
      }
      const others = rawAt.get(key);
      const isOnOther = (itemKey) => [...others.entries()].some(([c, v]) => c !== channel.id && v === itemKey);
      const up = bl[i + 1].id;
      if (pick.item.ratingKey !== up) skipped++;
      if (isOnOther(pick.item.ratingKey)) pickOnAnotherAtStart++;
      if (isOnOther(up)) upNextEqualsOtherAtStartBeforeSkip++;
    }
  }
  return { advances: total, skippedByConflictCheck: skipped, upNextWasOnAnotherChannelAtItsStart: upNextEqualsOtherAtStartBeforeSkip, pickIsOnAnotherChannelAtItsStart: pickOnAnotherAtStart };
}
const advance = ADV_EVERY > 0 ? advanceMetric() : null;

// "Right now".
let atNow = null;
if (AT) {
  const r = instant(AT);
  const d = r.detail;
  const named = (c) => chName.get(c);
  atNow = {
    at: new Date(AT * 1000).toISOString(),
    rawDuplicatedTitles: d.rawG.map(([k, chs]) => ({ title: byId.get(k).title, channels: chs.sort((a, b) => a - b).map(named) })),
    bumpedChannels: d.bumped.map((c) => ({ channel: named(c), guideShowsNow: d.shown.get(c).nowPlaying.item.title ? byId.get(d.shown.get(c).nowPlaying.item.ratingKey).title : null, wasOn: byId.get(d.rawMap.get(c).nowPlaying.item.ratingKey).title })),
    stillDuplicatedAfterResolve: d.shownG.map(([k, chs]) => ({ title: byId.get(k).title, channels: chs.sort((a, b) => a - b).map(named) })),
    counts: { rawDupTitles: r.rawDupTitles, rawDupChannels: r.rawDupChannels, bumped: r.bumped, shownDupTitles: r.shownDupTitles, shownDupChannels: r.shownDupChannels, tunedDupChannels: r.tunedDupChannels },
  };
}

// One title, followed through the day: --watch "part of a title" (matches by title substring).
let watch = null;
if (args.watch) {
  const needle = norm(args.watch);
  const ids = items.filter((i) => norm(i.title).includes(needle)).map((i) => i.id);
  watch = ids.map((id) => {
    const it = byId.get(id);
    const airings = [];
    for (const day of DAYS) for (const [c, bl] of Object.entries(manifests[day])) for (const b of bl) if (b.id === id) airings.push({ day, channel: chName.get(Number(c)), id: Number(c), from: fmt(b.s), to: fmt(b.e), s: b.s, e: b.e });
    airings.sort((a, b) => a.s - b.s);
    const overlaps = [];
    for (let i = 0; i < airings.length; i++) for (let j = i + 1; j < airings.length; j++) {
      const s = Math.max(airings[i].s, airings[j].s), e = Math.min(airings[i].e, airings[j].e);
      if (e > s) overlaps.push({ channels: [airings[i].channel, airings[j].channel], from: fmt(s), to: fmt(e), minutes: mins(e - s), higherChannelGivesWay: chName.get(Math.max(airings[i].id, airings[j].id)) });
    }
    return {
      title: `${it.title}${it.year ? ` (${it.year})` : ""}`, ratingKeys: 1, poolsCarryingIt: poolCount.get(id),
      channelsCarryingIt: rows.filter((r, ri) => meta.allChannelPools[ri].some((ix) => items[ix].id === id)).map((r) => `${r.number} ${r.name}`),
      airings: airings.map(({ day, channel, from, to }) => `${day} ${channel} ${from}-${to}`), overlaps,
    };
  });
}

const report = {
  tested: { device: "data pulled read-only from the device named in --data", day: DAYS[0], channelsWithManifests: rows.length, libraryItems: items.length },
  library: { census, poolMembership },
  rawSweep: raw,
  topOffendersOnFirstDay: top,
  overlapEventsOnFirstDay: idEventStats,
  nullModelEachChannelsDayShiftedAtRandom: nullModel,
  instants, guideGrid: grid, naturalEndAdvance: advance, atNow, watch,
};
if (args.out) writeFileSync(args.out, JSON.stringify(report, null, 2));
if (args["dump-instants"]) {
  const cols = ["t", "rawDupTitles", "rawDupChannels", "rawContentDupTitles", "bumped", "shownDupTitles", "shownDupChannels", "shownContentDupTitles", "tunePlaysTheTitleItGaveWay", "tunedDupTitles", "tunedDupChannels"];
  writeFileSync(args["dump-instants"], JSON.stringify({ columns: cols, rows: samples.map((x) => cols.map((c) => x[c])) }));
}
console.log(JSON.stringify(report, null, 2));

// The control: the numbers a correct harness reports for scripts/qa/make-duplicates-control.mjs.
if (args.expect) {
  const exp = JSON.parse(readFileSync(args.expect, "utf8"));
  let failed = 0;
  const check = (label, got, want) => { const ok = Math.abs(got - want) < 0.11; if (!ok) failed++; console.error(`${ok ? "PASS" : "FAIL"} ${label}: got ${got}, want ${want}`); };
  for (const [k, fields] of Object.entries(exp.sweep)) for (const [f, want] of Object.entries(fields)) check(`sweep ${k} ${f}`, report.rawSweep[DAYS[0]].metrics[k][f], want);
  for (const p of exp.probes) {
    const r = instant(dayStartSec(DAYS[0]) + p.atMinute * 60);
    for (const [f, want] of Object.entries(p)) if (f !== "atMinute" && f !== "note") check(`probe ${p.atMinute} min ${f}`, r[f], want);
  }
  console.error(failed ? `${failed} control check(s) FAILED` : "control: all checks passed");
  process.exit(failed ? 1 : 0);
}
