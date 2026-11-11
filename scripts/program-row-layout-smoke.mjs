#!/usr/bin/env node
/**
 * GUIDE ROW ACROSS LOCAL MIDNIGHT: the web tuner's guide row is never wider than its window, and no
 * programme is drawn away from its time.
 *
 * The 24-hour guide window holds two days' blocks, and an airing that runs past local midnight overlaps the
 * next day's first airing (it starts AT midnight). renderGrid used to lay blocks end to end, so the overlap was
 * counted twice: a movie from 23:24 to 01:08 made the row 68 minutes wider than the 2-hour window and drew every
 * programme after it 68 minutes late, for the 90 minutes before midnight in which the window holds both
 * (Trello N-062; the Roku side of the same night is issue 297). The Apple TV trims the later airing with a cursor
 * walk (ProgramRowLayout.segments); scripts/nostalgex-program-row-layout.js is that walk for the page.
 *
 *   1. The module against the cases of NostalgexTests/ProgramRowLayoutTests.swift.
 *   2. The page's own renderGrid (lifted out of plex-tuner.html, run on a stub DOM) with the real engine
 *      (scripts/nostalgex-daily-manifest.js) on a night when a movie crosses midnight, every minute of the three
 *      hours before it: the row totals exactly the window, every programme is drawn at its time or, when the
 *      airing before it overlaps it, right after that airing, and one block is marked live.
 *   3. A hole in the schedule keeps its place, an overlap that covers "now" does not light the trimmed block,
 *      a sliver of a block (narrower than its padding) loses the padding, and a channel with nothing airing still
 *      draws its own row.
 *
 * No browser, no network. NX_TUNER_HTML=/path runs the page checks on another copy of the page (origin/main's,
 * for the negative control): it must fail. The same night in a real browser: scripts/program-row-layout-browser-smoke.mjs.
 * Run: `npm run test:program-row-layout`.
 */
import { readFileSync } from "node:fs";
import vm from "node:vm";

process.env.TZ = "America/Toronto";   // before any Date is made: local midnight is Toronto's

const root = new URL("../", import.meta.url);
const read = (p) => readFileSync(new URL(p, root), "utf8");
const layoutSrc = read("scripts/nostalgex-program-row-layout.js");
const dmSrc = read("scripts/nostalgex-daily-manifest.js");
const page = process.env.NX_TUNER_HTML ? readFileSync(process.env.NX_TUNER_HTML, "utf8") : read("plex-tuner.html");

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `\n    ${detail}` : ""}`); };

// ── The stub DOM and the page's own functions ──
class El {
  constructor(tag) {
    this.tag = tag; this.className = ""; this.children = []; this.dataset = {}; this.textContent = ""; this.title = ""; this.innerHTML = "";
    const props = new Map();
    this.style = new Proxy({ setProperty: (k, v) => props.set(k, v) }, { get: (t, k) => (k in t ? t[k] : props.get(k)), set: (t, k, v) => { t[k] = v; return true; } });
    const classes = () => this.className.split(/\s+/).filter(Boolean);
    this.classList = {
      add: (c) => { if (!classes().includes(c)) this.className = [...classes(), c].join(" "); },
      remove: (c) => { this.className = classes().filter((x) => x !== c).join(" "); },
      contains: (c) => classes().includes(c),
    };
  }
  appendChild(c) { if (c.tag === "fragment") this.children.push(...c.children); else this.children.push(c); return c; }
  addEventListener() {}
}

function fn(name) {
  const m = new RegExp(`^  (async )?function ${name}\\(`, "m").exec(page);
  if (!m) throw new Error(`plex-tuner.html: function ${name} not found`);
  let i = page.indexOf("{", page.indexOf(")", m.index));
  let depth = 0;
  for (; i < page.length; i++) {
    const c = page[i];
    if (c === "/" && page[i + 1] === "/") { i = page.indexOf("\n", i); continue; }
    if (c === "/" && page[i + 1] === "*") { i = page.indexOf("*/", i) + 1; continue; }
    if (c === "'" || c === '"' || c === "`") {
      const q = c; i++;
      while (page[i] !== q) { if (page[i] === "\\") i++; i++; }
      continue;
    }
    if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return page.slice(m.index, i + 1);
  }
  throw new Error(`unbalanced: ${name}`);
}

const RealDate = Date;
const store = new Map();
const els = new Map();
const byId = (id) => { if (!els.has(id)) els.set(id, new El("div")); return els.get(id); };
const ctx = {
  console, TextEncoder, now: 0, byId,
  localStorage: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => { store.set(k, String(v)); },
    removeItem: (k) => { store.delete(k); }, key: (i) => [...store.keys()][i] ?? null, get length() { return store.size; } },
  document: { getElementById: (id) => byId(id), createElement: (t) => new El(t), createDocumentFragment: () => new El("fragment") },
};
ctx.Date = class extends RealDate { constructor(...a) { super(...(a.length ? a : [ctx.now])); } static now() { return ctx.now; } };
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(dmSrc, ctx);
vm.runInContext(layoutSrc, ctx);
const Layout = ctx.NostalgexProgramRowLayout;

// ── 1. The module, against ProgramRowLayoutTests.swift ──
{
  const W = 7200;
  const seg = (list) => Layout.segments(list.map(([s, e]) => ({ startSec: s * 60, endSec: e * 60 })), 0, W)
    .map((x) => (x.kind === "gap" ? `gap ${x.fraction}` : `block ${x.index} ${x.fraction}`));
  const total = (list) => Layout.segments(list.map(([s, e]) => ({ startSec: s * 60, endSec: e * 60 })), 0, W).reduce((a, x) => a + x.fraction, 0);
  const eq = (label, got, want) => check(label, JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)}`);

  const pathological = [[-500, 90], [0, 90], [30, 200], [45, 46], [100, 400]];
  check("no input totals past the window", total(pathological) <= 1 + 1e-9, String(total(pathological)));
  check("every segment has a width", Layout.segments(pathological.map(([s, e]) => ({ startSec: s * 60, endSec: e * 60 })), 0, W).every((x) => x.fraction > 0));
  eq("a block straddling the window start is clipped to it", seg([[-30, 30], [30, 120]]), ["block 0 0.25", "block 1 0.75"]);
  eq("a hole becomes a spacer at its place", seg([[0, 30], [60, 120]]), ["block 0 0.25", "gap 0.25", "block 1 0.5"]);
  eq("leading dead air is a spacer, not a block pulled left", seg([[60, 120]]), ["gap 0.5", "block 0 0.5"]);
  eq("an overlap is trimmed from the later block", seg([[0, 60], [45, 105]]), ["block 0 0.5", "block 1 0.375"]);
  eq("a block swallowed by the one before it is skipped", seg([[0, 60], [10, 40]]), ["block 0 0.5"]);
  check("a contiguous day fills the window exactly", Math.abs(total([[-15, 45], [45, 90], [90, 150]]) - 1) < 1e-9);
  eq("blocks outside the window draw nothing", seg([[-120, -30], [130, 200]]), []);
  eq("an empty schedule draws nothing", seg([]), []);
  eq("indices point into the caller's order", seg([[60, 120], [0, 60]]), ["block 1 0.5", "block 0 0.5"]);
  eq("no window, no segments", Layout.segments([{ startSec: 0, endSec: 60 }], 0, 0), []);
}

// ── 2. renderGrid on a night a movie crosses midnight ──
vm.runInContext(`
  let CHANNELS = [];
  let currentChannel = null;
  let guideVisible = false, guidePromoKey = null, guideFocusIndex = 0, guideSlotOffset = 0;
  const WATERSHED_GUIDE_LABEL = 'HELD';
  function seasonalBundleOnOffer() { return null; }
  function chNum(ch) { return ch.id; }
  function escapeHtml(s) { return String(s); }
  function itemGuideTitle(i) { return i.title; }
  function getTimeFilteredPool(ch) { return ch.itemPool; }
  function manifestServerKey() { return 'smoke'; }
  function isWatershedHold() { return false; }
  function addStripeCells() {}
  ${fn("renderGrid")}
  this.grid = { set(c) { CHANNELS = c; }, offset(n) { guideSlotOffset = n; }, renderGrid };
`, ctx);

function lcg(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32); }
function moviePool(n, lo, hi, seed) {
  const r = lcg(seed);
  return Array.from({ length: n }, (_, i) => ({ ratingKey: `m${seed}_${i}`, title: `Movie ${seed}-${i}`, type: "movie", duration: lo + Math.floor(r() * (hi - lo + 1)), addedAt: 0 }));
}
function episodePool(shows, perShow, lo, hi, seed) {
  const r = lcg(seed);
  const out = [];
  for (let s = 0; s < shows; s++) for (let e = 0; e < perShow; e++) {
    out.push({ ratingKey: `e${seed}_${s}_${e}`, title: `Show ${seed}-${s}`, type: "episode", duration: lo + Math.floor(r() * (hi - lo + 1)), addedAt: 0 });
  }
  return out;
}
const mk = (id, name, itemPool) => ({ id, name, enabled: true, colorHex: "#fff", itemPool, schedule: [], _manifestBlocks: null });
const movies = mk(301, "MOVIES60", moviePool(60, 80, 148, 11));            // a movie channel: long airings
const episodes = mk(302, "EPISODES400", episodePool(25, 16, 20, 46, 22));  // an episode channel: several airings per window
const pool = movies.itemPool;
const DM = ctx.NostalgexDailyManifest;
const pct = (el) => parseFloat(el.style.width);

/** The channel as buildChannelSchedule leaves it at `nowSec`. */
function scheduleAt(ch, nowSec) {
  ctx.now = nowSec * 1000;
  const live = DM.buildSchedule(ch, ch.itemPool, nowSec, "smoke");
  ch._manifestBlocks = live.entries;
  ch.schedule = [live.nowPlaying || live.entries[0]];
}
/** The row renderGrid drew for the channel at `nowSec`: its children in order. */
function rowAt(ch, nowSec, offset = 0) {
  scheduleAt(ch, nowSec);
  ctx.grid.set([ch]);
  ctx.grid.offset(offset);
  byId("grid-body").children.length = 0;
  ctx.grid.renderGrid();
  const row = byId("grid-body").children.find((r) => r.dataset.channelId === ch.id);
  return row.children.find((c) => c.className === "grid-row-programs").children;
}

/** A night when the last airing of the day runs at least `minOverlapMin` past local midnight. */
function findNight(ch, minOverlapMin) {
  for (let d = 0; d < 30; d++) {
    const noon = new RealDate(2026, 10, 12 + d, 12, 0, 0).getTime();
    ctx.now = noon;
    const blocks = DM.getManifestBlocks(ch, ch.itemPool, noon, "smoke");
    const last = blocks[blocks.length - 1];
    const midnight = DM.startOfNextLocalDayMs(noon) / 1000;
    if (last.endSec - midnight >= minOverlapMin * 60) return { midnight, block: last, overlapMin: Math.round((last.endSec - midnight) / 60) };
  }
  return null;
}

/**
 * Every guide window of the three hours before midnight on a night an airing crosses it. The oracle is the
 * rule in the plainest terms: each airing is drawn at its time, or, when the airing before it overlaps it,
 * right after that one's end; an airing wholly inside the one before it is not drawn; nothing totals past 100%.
 */
function midnightNight(ch, minOverlapMin) {
  const night = findNight(ch, minOverlapMin);
  check(`${ch.name}: the lineup has a night when an airing crosses midnight`, Boolean(night));
  if (!night) return;
  const r = { windows: 0, wide: 0, maxPct: 0, late: 0, worstMin: 0, missing: 0, wrongLive: 0 };
  for (let t = night.midnight - 10800; t < night.midnight; t += 60) {
    const progs = rowAt(ch, t);
    const ws = Math.floor(t / 1800) * 1800, we = ws + 7200;
    r.windows++;
    const sum = progs.reduce((a, p) => a + pct(p), 0);
    r.maxPct = Math.max(r.maxPct, sum);
    if (sum > 100 + 1e-6) r.wide++;

    const expected = [];
    let cursor = ws;
    for (const b of ch._manifestBlocks.filter((b) => b.endSec > ws && b.startSec < we).sort((a, b) => a.startSec - b.startSec)) {
      const from = Math.max(b.startSec, cursor), to = Math.min(b.endSec, we);
      if (to <= from) continue;
      expected.push({ b, from });
      cursor = to;
    }
    const drawn = progs.filter((p) => p.className.startsWith("grid-program"));
    if (drawn.length !== expected.length) { r.missing++; continue; }

    let x = 0, worst = 0, k = 0;
    for (const p of progs) {
      if (p.className.startsWith("grid-program")) worst = Math.max(worst, Math.abs(ws + x - expected[k++].from));
      x += (pct(p) / 100) * 7200;
    }
    if (worst > 1) { r.late++; r.worstMin = Math.max(r.worstMin, Math.round(worst / 60)); }

    const live = drawn.filter((p) => p.className.includes("now-playing"));
    const under = ch._manifestBlocks.filter((b) => b.startSec <= t && t < b.endSec);
    if (live.length !== 1 || !under.some((b) => b.item.title === live[0].textContent)) r.wrongLive++;
  }
  console.log(`${ch.name}, ${new RealDate(night.midnight * 1000).toDateString()}: "${night.block.item.title}" ${night.block.item.duration} min, ${night.overlapMin} min past midnight`);
  console.log(`  ${r.windows} guide windows, 3 h before midnight: row wider than the window in ${r.wide} (widest ${r.maxPct.toFixed(1)}%),`
    + ` programmes drawn away from their time in ${r.late} (worst ${r.worstMin} min), airings missing or extra in ${r.missing}, wrong live block in ${r.wrongLive}`);
  check(`${ch.name}: the row is never wider than its window (widest ${r.maxPct.toFixed(1)}%, ${r.wide} windows)`, r.wide === 0);
  check(`${ch.name}: no programme is drawn away from its time (${r.late} windows, worst ${r.worstMin} min)`, r.late === 0);
  check(`${ch.name}: the airings drawn are the airings in the window`, r.missing === 0, `${r.missing} windows`);
  check(`${ch.name}: one live block, the one under the clock`, r.wrongLive === 0, `${r.wrongLive} windows`);

  const hour = rowAt(ch, night.midnight - 3600).reduce((a, p) => a + pct(p), 0);
  check(`${ch.name}: an hour before midnight the row is exactly the window (${hour.toFixed(1)}%)`, Math.abs(hour - 100) < 1e-6);
  // The guide's time cursor, moved to the first window after midnight, follows the same rule.
  const ahead = rowAt(ch, night.midnight - 1800, 3).reduce((a, p) => a + pct(p), 0);
  check(`${ch.name}: a window moved past midnight is exactly the window too (${ahead.toFixed(1)}%)`, Math.abs(ahead - 100) < 1e-6);
}
midnightNight(movies, 45);
midnightNight(episodes, 10);

// ── 3. Holes, a trimmed block under the clock, nothing airing ──
{
  const t0 = new RealDate(2026, 10, 20, 20, 0, 0).getTime() / 1000;   // 20:00, window 20:00 to 22:00
  const entry = (title, s, e) => ({ item: { ratingKey: title, title, duration: (e - s) / 60 }, startSec: t0 + s * 60, endSec: t0 + e * 60 });
  const rowFor = (entries, nowMin) => {
    const ch = { id: 7, name: "TEST", enabled: true, colorHex: "#fff", itemPool: pool, schedule: [entries[0]], _manifestBlocks: entries };
    ctx.now = (t0 + nowMin * 60) * 1000;
    ctx.grid.set([ch]);
    ctx.grid.offset(0);
    byId("grid-body").children.length = 0;
    ctx.grid.renderGrid();
    return byId("grid-body").children[0].children.find((c) => c.className === "grid-row-programs").children;
  };

  const hole = rowFor([entry("A", 0, 30), entry("B", 60, 120)], 10);
  check("a hole is a spacer between the blocks", hole.map((p) => p.className).join("|") === "grid-program now-playing|grid-gap|grid-program", hole.map((p) => p.className).join("|"));
  check("the programme after a hole is drawn at its time", hole.length === 3 && Math.abs(pct(hole[0]) + pct(hole[1]) - 50) < 1e-9, hole.map((p) => p.style.width).join(" "));

  const lap = rowFor([entry("Late movie", 0, 90), entry("Next day", 30, 120)], 45);
  check("an overlapped block is trimmed to what is left of the window", lap.length === 2 && Math.abs(pct(lap[1]) - 25) < 1e-9, lap.map((p) => p.style.width).join(" "));
  check("with the clock inside the overlap the earlier airing is the live one", lap[0].className.includes("now-playing") && !lap[1].className.includes("now-playing"), lap.map((p) => p.className).join("|"));

  // A few minutes of an airing cannot be narrower than its padding; the page drops the padding from slivers.
  const sliver = rowFor([entry("Long", 0, 112), entry("Short", 112, 120)], 5);
  check("a sliver of a block loses its padding so it cannot push the row past the window",
    sliver.length === 2 && !sliver[0].className.includes("sliver") && sliver[1].className.includes("grid-program--sliver"), sliver.map((p) => p.className).join("|"));

  const none = rowFor([], 0);
  check("a channel with nothing in the window still draws its row", none.length === 0, String(none.length));
}

if (failures.length) {
  console.error(`program-row-layout: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`program-row-layout: ${passed} checks passed`);
