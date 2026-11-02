#!/usr/bin/env node
/**
 * The lineup's days are packed together (scripts/nostalgex-daily-manifest.js packLineupDay,
 * DailyManifestScheduler.packLineupDay on the Apple TV): one title is not on two channels at
 * once wherever a channel has something else to air. The golden file holds the engines to the
 * same answers; this holds the answers to the properties the guide depends on.
 *
 *   1. A lineup with room: no title on two channels at once, over three days.
 *   2. The same day whatever order the channels are asked for it in.
 *   3. A rescan that changed nothing: the days ahead, packed again, are the same (1.0.29).
 *   4. One channel's pool changes: only that channel's day moves.
 *   5. A channel the guide doesn't carry changes nothing the guide's channels air.
 *   6. No lineup registered, or a lineup of one: each channel's own order, as before.
 *   7. A later part of a story never airs right before an earlier one.
 *   8. Cost: the lineup's day packs in a bounded multiple of packing each channel alone.
 */
import { readFileSync } from "node:fs";
import { loadEngine } from "./schedule-parity-dump.mjs";

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed++; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

process.env.TZ = "America/New_York";
const DAY = new Date(2026, 10, 12, 0, 0, 0).getTime();   // a 24-hour day
const SK = "lineup-smoke";

// A library: 240 films and 6 shows, every length a whole minute, a few "Part" stories.
let seed = 7;
const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
const films = [];
for (let i = 0; i < 240; i++) films.push({ ratingKey: `f${i}`, title: `Film ${i}`, type: "movie", duration: 80 + Math.floor(rnd() * 70), addedAt: 0 });
for (const [base, n] of [["Saga", 3], ["Quest", 2]]) for (let p = 1; p <= n; p++) films.push({ ratingKey: `${base}${p}`, title: `The ${base} Part ${p}`, type: "movie", duration: 100 + p * 7, addedAt: 0 });
const episodes = [];
for (let s = 0; s < 6; s++) for (let e = 0; e < 20; e++) episodes.push({ ratingKey: `s${s}e${e}`, title: `Show ${s}`, type: "episode", duration: 22 + (s % 3) * 22, addedAt: 0 });

/** 24 channels whose pools overlap heavily: windows over the library, a premiere channel, a gated one. */
function lineup() {
  const out = [];
  for (let c = 0; c < 24; c++) {
    const from = (c * 17) % 200;
    const pool = films.slice(from, from + 40 + (c % 5) * 10);
    if (c % 4 === 0) pool.push(...films.filter((f) => /Part/.test(f.title)));
    if (c % 3 === 0) pool.push(...episodes.slice((c % 6) * 20, (c % 6) * 20 + 20));
    out.push({ channel: { id: 10 + c, isPremiereChannel: c === 5, timeRestrictions: c === 7 ? { tvOnlyBefore: 0 } : null }, pool });
  }
  return out;
}

const dayAt = (d) => DAY + d * 86400000 + 3600000;
function packDays(M, entries, order, days = [0, 1, 2]) {
  const out = {};
  for (const d of days) {
    out[d] = {};
    for (const i of order) out[d][entries[i].channel.id] = M.getManifestBlocks(entries[i].channel, entries[i].pool, dayAt(d), SK).map((b) => `${b.item.ratingKey}@${b.startSec}-${b.endSec}`);
  }
  return out;
}
function overlaps(day) {
  const by = new Map();
  let n = 0;
  for (const [ch, bl] of Object.entries(day)) for (const s of bl) {
    const [k, span] = s.split("@");
    const [a, b] = span.split("-").map(Number);
    for (const o of by.get(k) || []) if (o.ch !== ch && Math.min(b, o.b) > Math.max(a, o.a)) n++;
    if (!by.has(k)) by.set(k, []);
    by.get(k).push({ ch, a, b });
  }
  return n;
}
const order = (n, how) => { const a = [...Array(n).keys()]; if (how === "reverse") a.reverse(); if (how === "shuffle") { let s = 3; for (let i = a.length - 1; i > 0; i--) { s = (s * 69069 + 1) % 4294967296; const j = s % (i + 1); [a[i], a[j]] = [a[j], a[i]]; } } return a; };

// 1 and 2.
const L = lineup();
const runs = {};
for (const how of ["guide", "reverse", "shuffle"]) {
  const { M } = loadEngine();
  M.setLineup(L);
  runs[how] = packDays(M, L, order(L.length, how));
}
for (const d of [0, 1, 2]) check(`day ${d}: no title on two channels at once`, overlaps(runs.guide[d]) === 0, `${overlaps(runs.guide[d])} overlaps`);
// The control: the same pools, each channel packed alone, clash. Otherwise 1 proves nothing.
const alone = packDays(loadEngine().M, L, order(L.length, "guide"));
check("control: packed alone, the same pools clash every day", [0, 1, 2].every((d) => overlaps(alone[d]) > 20), [0, 1, 2].map((d) => overlaps(alone[d])).join(","));
check("the same days whatever order the guide asks in", JSON.stringify(runs.guide) === JSON.stringify(runs.reverse) && JSON.stringify(runs.guide) === JSON.stringify(runs.shuffle));

// 3. A rescan that changed nothing: today kept, the days ahead purged (purgeDays) and packed again.
{
  const { M, store } = loadEngine();
  M.setLineup(L);
  const before = packDays(M, L, order(L.length, "guide"));
  const todayKey = M.localDayKey(dayAt(0));
  for (const k of [...store.keys()]) if (!k.endsWith(`_${todayKey}`)) store.delete(k);
  M.setLineup(lineup());   // the rescan's fresh objects, the same library
  const after = packDays(M, lineup(), order(L.length, "shuffle"));
  check("a rescan that changed nothing packs the days ahead the same", JSON.stringify(before) === JSON.stringify(after));
}

// 4. One pool changes mid-day: that channel's day is packed again, every other one stays.
{
  const { M } = loadEngine();
  M.setLineup(L);
  const before = packDays(M, L, order(L.length, "guide"), [0]);
  const changed = lineup();
  changed[3].pool = [...changed[3].pool, films[239], films[0]];
  M.setLineup(changed);
  const after = packDays(M, changed, order(L.length, "guide"), [0]);
  const moved = Object.keys(before[0]).filter((ch) => JSON.stringify(before[0][ch]) !== JSON.stringify(after[0][ch]));
  check("a changed pool moves only its own channel's day", moved.length <= 1 && moved.every((ch) => ch === String(changed[3].channel.id)), moved.join(","));
  check("and it still clashes with nothing", overlaps(after[0]) === 0, `${overlaps(after[0])}`);
}

// 5. A channel the guide doesn't carry, asked for first, changes nothing the guide airs.
{
  const off = { channel: { id: 5, isPremiereChannel: false, timeRestrictions: null }, pool: films.slice(0, 60) };
  const { M } = loadEngine();
  M.setLineup(L);
  M.getManifestBlocks(off.channel, off.pool, dayAt(0), SK);
  const withOff = packDays(M, L, order(L.length, "guide"));
  check("a channel off the guide changes nothing the guide airs", JSON.stringify(withOff) === JSON.stringify(runs.guide));
  // Asked for after the guide's day is known it takes the short path (the lineup's day kept
  // in memory); before, the full one. The same day either way.
  const before = loadEngine();
  before.M.setLineup(L);
  const offFirst = before.M.getManifestBlocks(off.channel, off.pool, dayAt(0), SK).map((b) => `${b.item.ratingKey}@${b.startSec}`);
  const after = loadEngine();
  after.M.setLineup(L);
  packDays(after.M, L, order(L.length, "guide"), [0]);
  const offAfter = after.M.getManifestBlocks(off.channel, off.pool, dayAt(0), SK).map((b) => `${b.item.ratingKey}@${b.startSec}`);
  check("a channel off the guide packs the same asked before or after the guide", JSON.stringify(offFirst) === JSON.stringify(offAfter));
}

// 5b. A channel switched on after the day was packed: the next channel off the guide packs
// against the new lineup, as a fresh start with that lineup would.
// The stale case is a channel whose day was stored while it was off the guide: switched on,
// it is read from the store and nothing packs, so only the memo's key can notice.
{
  const engineSrc = readFileSync(new URL("./nostalgex-daily-manifest.js", import.meta.url), "utf8");
  const staleSrc = engineSrc.replace(/const memoKey = `\$\{serverKey\}\|\$\{dayKey\}\|\$\{entries[^`]*`;/, "const memoKey = `${serverKey}|${dayKey}`;");
  check("control patched: an off-guide memo keyed on the day only", staleSrc !== engineSrc);
  const small = L.slice(0, 20);
  const x = L[20];
  const y = { channel: { id: 7, isPremiereChannel: false, timeRestrictions: null }, pool: x.pool };
  const clashesWithX = (src) => {
    const { M } = loadEngine(src);
    let current = small;
    M.setLineup(() => current);                       // the page's one provider, never re-registered
    packDays(M, small, order(small.length, "guide"), [0]);
    const xDay = M.getManifestBlocks(x.channel, x.pool, dayAt(0), SK);   // off the guide, stored
    current = [...small, x];                          // switched on: its day is read, not packed
    M.getManifestBlocks(x.channel, x.pool, dayAt(0), SK);
    const yDay = M.getManifestBlocks(y.channel, y.pool, dayAt(0), SK);   // the next off-guide channel
    let n = 0;
    for (const a of yDay) for (const b of xDay) if (a.item.ratingKey === b.item.ratingKey && Math.min(a.endSec, b.endSec) > Math.max(a.startSec, b.startSec)) n++;
    return n;
  };
  check("a channel switched on reaches the next off-guide channel's day", clashesWithX(engineSrc) === 0, `${clashesWithX(engineSrc)} clashes`);
  check("control: keyed on the day only, the off-guide channel clashes with it", clashesWithX(staleSrc) > 0);
}

// 5c. Two time-gated channels: the second's day doesn't depend on the pool the first had
// when it was built (its rating hold before 9 PM, say).
{
  const gatedA = (pool) => ({ channel: { id: 90, isPremiereChannel: false, timeRestrictions: { blockBefore: 21 } }, pool });
  const gatedB = { channel: { id: 91, isPremiereChannel: false, timeRestrictions: { tvOnlyBefore: 11 } }, pool: films.slice(0, 60) };
  const dayOfB = (poolA) => {
    const { M } = loadEngine();
    const lu = [...L, gatedA(poolA), gatedB];
    M.setLineup(lu);
    return packDays(M, lu, order(lu.length, "guide"), [0])[0][91];
  };
  check("a time-gated channel's day doesn't depend on another's pool", JSON.stringify(dayOfB(films.slice(0, 40))) === JSON.stringify(dayOfB(films.slice(10, 70))));
}

// 6. No lineup, or a lineup of one: the channel's own order.
{
  const a = loadEngine(), b = loadEngine();
  b.M.setLineup([L[2]]);
  const solo = packDays(a.M, L, [2]), one = packDays(b.M, L, [2]);
  check("a lineup of one packs as no lineup", JSON.stringify(solo) === JSON.stringify(one));
  // The lowest channel, with nothing before it, keeps its own order when the lineup has room.
  const first = packDays(loadEngine().M, L, [0]);
  check("the first channel in the lineup airs its own order", JSON.stringify(first[0][L[0].channel.id]) === JSON.stringify(runs.guide[0][L[0].channel.id]));
}

// 7. Parts in order.
{
  let bad = 0, pairs = 0;
  for (const day of Object.values(runs.guide)) for (const bl of Object.values(day)) for (let i = 1; i < bl.length; i++) {
    const m = (s) => /^(Saga|Quest)(\d)@/.exec(s);
    const a = m(bl[i - 1]), b = m(bl[i]);
    if (a && b && a[1] === b[1]) { pairs++; if (+b[2] < +a[2]) bad++; }
  }
  check("a later part never airs right before an earlier one", bad === 0 && pairs > 0, `${bad} of ${pairs}`);
}

// 8. Cost, against packing each channel alone. Generous bound: the check is for a blow-up.
{
  const time = (withLineup) => {
    const ms = [];
    for (let r = 0; r < 5; r++) {
      const { M } = loadEngine();
      if (withLineup) M.setLineup(L);
      const t0 = process.hrtime.bigint();
      for (const e of L) M.getManifestBlocks(e.channel, e.pool, dayAt(0), SK);
      ms.push(Number(process.hrtime.bigint() - t0) / 1e6);
    }
    return ms.sort((x, y) => x - y)[2];
  };
  const alone = time(false), together = time(true);
  check("the lineup's day costs at most 4x packing each channel alone", together <= alone * 4 + 5, `${together.toFixed(1)} ms vs ${alone.toFixed(1)} ms`);
  console.log(`lineup smoke: ${L.length} channels, one day packed in ${together.toFixed(1)} ms together, ${alone.toFixed(1)} ms alone`);
}

if (failures.length) {
  console.error(`schedule lineup smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`schedule lineup smoke: ${passed} passed`);
