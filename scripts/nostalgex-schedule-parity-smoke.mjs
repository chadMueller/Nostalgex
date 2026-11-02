#!/usr/bin/env node
/**
 * The web tuner and the Docker image air what the Apple TV airs, minute for minute.
 *
 *   1. scripts/nostalgex-daily-manifest.js against scripts/schedule-parity-golden.json, which
 *      NostalgexTests/ScheduleParityTests.swift generates from the app's own code and also
 *      asserts: every case byte for byte (canonical JSON), each channel's day, the guide at
 *      each instant, one title on two channels, tuning in and the next pick.
 *   2. The golden file covers what it claims: Plex, Jellyfin and Emby shapes, days of 23 and
 *      25 hours and one that starts at 1 AM, a channel giving way, a next pick moved on by a
 *      title already on elsewhere, a tune that plays the title the guide gave way, items the
 *      loaders drop, one-minute and longer-than-a-day items.
 *   3. plex-tuner.html's own schedule functions (buildChannelSchedule, rebuildAllSchedules,
 *      nextAfterEnd), run on the golden fixtures: the row it tunes to, the guide after one
 *      title on two channels, and the next pick at each instant are the Apple TV's. No pool
 *      shuffle, minutes truncated through the engine.
 *   4. Negative controls: rounding minutes, shuffling pools, the higher channel keeping the
 *      title, an advance that ignores other channels, and a guide window that stops at
 *      midnight each fail the golden file.
 *
 * No network. Run: `npm run test:schedule-parity`.
 */
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadEngine, dump, canonical, makeItem } from "./schedule-parity-dump.mjs";

const root = new URL("../", import.meta.url);
const golden = JSON.parse(readFileSync(new URL("scripts/schedule-parity-golden.json", root), "utf8"));
const engineSrc = readFileSync(new URL("scripts/nostalgex-daily-manifest.js", root), "utf8");
const page = readFileSync(new URL("plex-tuner.html", root), "utf8");

let passed = 0;
const failures = [];
function check(label, ok, detail = "") {
  if (ok) passed += 1;
  else failures.push(`${label}${detail ? `\n    ${detail}` : ""}`);
}

/** The cases a variant of the engine (or of the fixtures) gets wrong. */
function failingCases(source = engineSrc, mapFixture = (fx) => fx) {
  const out = [];
  for (const c of golden.cases) {
    const got = dump(loadEngine(source), mapFixture(c.fixture));
    if (canonical(got) !== canonical(c.expect)) out.push(c.name);
  }
  return out;
}

// 1. The engine matches the Apple TV.
for (const c of golden.cases) {
  const got = canonical(dump(loadEngine(), c.fixture));
  const want = canonical(c.expect);
  let at = 0;
  while (at < got.length && got[at] === want[at]) at += 1;
  check(`${c.name}: byte for byte what the Apple TV airs`, got === want,
    `first difference at byte ${at}: web …${got.slice(Math.max(0, at - 60), at + 60)}…\n    apple …${want.slice(Math.max(0, at - 60), at + 60)}…`);
}

// 2. Coverage.
const all = golden.cases;
const backends = new Set(all.flatMap((c) => c.fixture.items.map((i) => i.backend)));
check("covers Plex, Jellyfin and Emby item shapes", ["plex", "jellyfin", "emby"].every((b) => backends.has(b)), [...backends].join(", "));
const dayLengths = new Set();
for (const c of all) {
  process.env.TZ = c.fixture.zone;
  const { M } = loadEngine();
  for (const t of c.fixture.days) dayLengths.add((M.startOfNextLocalDayMs(t * 1000) - M.startOfLocalDayMs(t * 1000)) / 3600000);
}
delete process.env.TZ;
check("covers a 23-hour and a 25-hour day", dayLengths.has(23) && dayLengths.has(25), [...dayLengths].join(", "));
check("covers a day that starts at 1 AM", all.some((c) => c.fixture.zone === "America/Santiago"));
const rows = all.flatMap((c) => c.expect.at.flatMap((a) => Object.values(a.ch).filter(Boolean)));
const gaveWay = rows.filter((r) => r.gaveWay);
check("a channel gives a title way to a lower one", gaveWay.length >= 6, `${gaveWay.length}`);
check("tuning to a channel that gave way still plays that title, as on the Apple TV",
  gaveWay.some((r) => r.tune && r.tune[0] === r.gaveWay && r.shown && r.shown[0] !== r.gaveWay));
check("a next pick skips a title already on another channel", rows.some((r) => r.early && r.next && r.early[0] !== r.next));
check("a resync seeks into the programme", rows.some((r) => r.resync && r.resync[1] > 0));
const items = all.flatMap((c) => Object.values(c.expect.items));
check("covers items the loaders drop", items.filter((i) => i === null).length >= 4, `${items.filter((i) => i === null).length}`);
check("covers one-minute and longer-than-a-day items", items.some((i) => i && i[0] === 1) && items.some((i) => i && i[0] > 1440));

// 3. The page's own schedule code gives the Apple TV's answers.
check("plex-tuner.html: no pool shuffle", !/shuffleArray/.test(page));
check("plex-tuner.html: no rounded minutes", !/Math\.round\([^)]*(?:60000|600000000)/.test(page));
for (const fn of ["minutesFromPlexMs", "minutesFromTicks", "unixSecondsFromISO"]) {
  check(`plex-tuner.html: the loaders use NostalgexDailyManifest.${fn}`, page.includes(`NostalgexDailyManifest.${fn}(`));
}
check("plex-tuner.html: the guide's lineup is registered, so each day packs across it",
  /NostalgexDailyManifest\.setLineup\(guideLineup\)/.test(page));
check("plex-tuner.html: a programme that plays to its end advances as a natural end",
  /video\.onended = \(\) => \{[^}]*onItemEnded\(channel, item, true\)/.test(page));
check("plex-tuner.html: a tune plays the schedule's first row", /const now = ch\.schedule\[0\];/.test(page.slice(page.indexOf("function switchChannel("))));
// The Apple TV's tune never needs the guide's resolved copy: it plays what is on by the clock,
// from where it is (capped at the programme's length). So the page's first row is the tune.
check("every golden tune is what is on by the clock, from where it is", rows.every((r) => !r.tune || (r.now && r.tune[0] === r.now[0] && r.tune[1] <= r.elapsed)));

const start = page.indexOf("  function buildChannelSchedule(");
const end = page.indexOf("  // RENDER GRID", start);
check("plex-tuner.html: the schedule functions are where this test reads them", start > 0 && end > start);
const pageSchedule = page.slice(start, page.lastIndexOf("  // ══", end));
let pageRows = 0;
/** Per case, where the page's schedule code (or a variant of it) differs from the Apple TV. */
function pageMismatches(source) {
  const out = new Map();
  pageRows = 0;
  for (const c of golden.cases) {
    const fx = c.fixture;
    const engine = loadEngine();
    dump(engine, fx);                     // the same days packed in the same order as the golden walk
    process.env.TZ = fx.zone;
    let nowMs = 0;
    const ctx = {
      Date: class extends Date { static now() { return nowMs; } }, Math, NostalgexDailyManifest: engine.M,
      getTimeFilteredPool: (ch) => ch.itemPool || [], manifestServerKey: () => fx.fingerprint, formatTime: (sec) => String(sec),
    };
    const items = new Map();
    for (const spec of fx.items) { const [, item] = makeItem(engine.M, spec); if (item) items.set(item.ratingKey, item); }
    ctx.CHANNELS = fx.channels.map((row) => ({ id: row.id, enabled: true, isPremiereChannel: Boolean(row.premiere),
      itemPool: row.pool.map((k) => items.get(k)).filter(Boolean) }));
    vm.createContext(ctx);
    vm.runInContext(source, ctx);
    const mismatches = [];
    for (const a of c.expect.at) {
      nowMs = a.t * 1000;
      ctx.rebuildAllSchedules();
      for (const ch of ctx.CHANNELS) {
        const r = a.ch[ch.id];
        if (!r) continue;
        pageRows += 1;
        const row = ch.schedule[0];
        const guideNow = ch._guide && ch._guide.nowPlaying;
        const gave = ch._guide && ch._guide.entries.find((e) => e.isConflict);
        const got = {
          tune: row ? [row.ratingKey, row.offsetSeconds] : null,
          shown: guideNow ? [guideNow.item.ratingKey, guideNow.startSec] : null,
          gaveWay: gave ? gave.item.ratingKey : null,
        };
        const pick = (sec, natural) => { nowMs = sec * 1000; const n = ctx.nextAfterEnd(ch, { ratingKey: r.tune[0] }, natural); nowMs = a.t * 1000; return n ? [n.ratingKey, n.offsetSeconds] : null; };
        if (r.early) got.early = pick(a.t, true);
        if (r.end) got.end = pick(r.now[2], true);
        if (r.resync) got.resync = pick(r.now[2] + 600, false);
        for (const [k, v] of Object.entries(got)) {
          if (canonical(v) !== canonical(r[k])) mismatches.push(`at ${a.t} ch ${ch.id} ${k}: page ${canonical(v)}, apple ${canonical(r[k])}`);
        }
      }
    }
    delete process.env.TZ;
    out.set(c.name, mismatches);
  }
  return out;
}
for (const [name, mismatches] of pageMismatches(pageSchedule)) {
  check(`${name}: plex-tuner.html tunes, resolves and picks next as the Apple TV does`, mismatches.length === 0, mismatches.slice(0, 5).join("\n    "));
}
const checkedRows = pageRows;
// The page as it was: the next programme is whatever the clock says, from where it is; no
// title is ever given way.
const pageControls = [
  ["the next pick is whatever the clock says", "if (pick) return { ...pick.item, offsetSeconds: pick.seekSeconds };",
    "if (pick) { buildChannelSchedule(channel); return channel.schedule[0]; }"],
  ["the guide never gives a title way", "NostalgexDailyManifest.resolveConflicts(schedules);", ""],
];
for (const [label, from, to] of pageControls) {
  const variant = pageSchedule.replace(from, to);
  check(`page negative control patched: ${label}`, variant !== pageSchedule);
  const failed = [...pageMismatches(variant).values()].filter((m) => m.length).length;
  check(`page negative control fails: ${label}`, failed > 0);
}
pageRows = checkedRows;

// 4. Negative controls.
function patched(label, from, to) {
  const src = engineSrc.replace(from, to);
  check(`negative control patched: ${label}`, src !== engineSrc);
  return src;
}
const controls = [
  ["rounded minutes", patched("rounded minutes", "return n > 0 ? Math.floor(n / 60000) : 0;", "return n > 0 ? Math.round(n / 60000) : 0;"), (fx) => fx],
  ["rounded ticks", patched("rounded ticks", "return n > 0 ? Math.floor(n / 600000000) : 0;", "return n > 0 ? Math.round(n / 600000000) : 0;"), (fx) => fx],
  ["the higher channel keeps the title", patched("higher keeps", "const losers = [...ids].sort((a, b) => a - b).slice(1);", "const losers = [...ids].sort((a, b) => b - a).slice(1);"), (fx) => fx],
  ["an advance that ignores other channels", patched("no advance conflict", "if (pick && findConflict(pick, channel.id, channels, nowSec, serverKey) != null) {", "if (false) {"), (fx) => fx],
  ["a guide window that stops at midnight", patched("one day", "while (cursor <= endDay) {", "while (cursor <= endDay && result.length === 0) {"), (fx) => fx],
  ["each channel packed on its own", patched("no lineup", "Boolean(channel.isPremiereChannel), last, occupancy, isGated(channel));", "Boolean(channel.isPremiereChannel), last, null, isGated(channel));"), (fx) => fx],
  ["yesterday's late programme not seen", patched("no overrun", "for (const b of prev) if (b.endSec > dayStartSec) occupancy.add(", "for (const b of prev) if (false) occupancy.add("), (fx) => fx],
  ["a later part ahead of an earlier one", patched("parts jump", "if (i > 0 && waitsForEarlierPart(queue, i)) continue;", ""), (fx) => fx],
  ["a time-gated channel packs among the rest", patched("gated first", "const rank = (e) => (isGated(e.channel) ? 1 : 0);", "const rank = () => 0;"), (fx) => fx],
  ["a time-gated channel gives way to another", patched("gated see gated", "if (x.ch === channelId || (skipGated && x.gated)) continue;", "if (x.ch === channelId) continue;"), (fx) => fx],
];
// The web's old pool shuffle, verbatim apart from the clock: by UTC day, every channel the same.
function oldShuffle(arr, nowMs) {
  const shuffled = [...arr];
  let m = shuffled.length;
  let s = Math.floor(nowMs / 86400000);
  while (m) {
    s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
    const i = Math.abs(s) % m--;
    [shuffled[m], shuffled[i]] = [shuffled[i], shuffled[m]];
  }
  return shuffled;
}
controls.push(["shuffled pools", engineSrc, (fx) => ({ ...fx, channels: fx.channels.map((c) => ({ ...c, pool: oldShuffle(c.pool, fx.days[0] * 1000) })) })]);
for (const [label, src, mapFixture] of controls) {
  const failed = failingCases(src, mapFixture);
  check(`negative control fails the golden file: ${label}`, failed.length > 0, "every case still passed");
}

if (failures.length) {
  console.error(`schedule parity smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`schedule parity smoke: ${passed} passed (${golden.cases.length} cases byte for byte with the Apple TV, ` +
  `${rows.length} channel-instants, ${gaveWay.length} giving way, ${pageRows} through plex-tuner.html's own code; ` +
  `${controls.length + pageControls.length} negative controls fail)`);
