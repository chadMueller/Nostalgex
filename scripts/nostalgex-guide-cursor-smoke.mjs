#!/usr/bin/env node
/**
 * The guide's programme cursor (scripts/nostalgex-guide-cursor.js) against the Apple TV's vectors:
 * Nostalgex/NostalgexTests/GuideProgramCursorTests.swift, replayed here case for case.
 *
 * A row: A on now (-10 to 22 min), B 22 to 23 (one minute), a gap to 50, C 50 to 170 (two hours), D 170 to 200.
 * `now` is 5 minutes in; the window starts at 0 and the view is 120 minutes.
 *
 * No network. Run: `npm run test:guide-cursor`.
 */
import { readFileSync } from "node:fs";
await import("./nostalgex-guide-cursor.js");
const GC = globalThis.NostalgexGuideCursor;

let passed = 0;
const failures = [];
const eq = (label, got, want) => { if (JSON.stringify(got) === JSON.stringify(want)) passed += 1; else failures.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };

const t0 = 1_800_000_000;   // the window's start, 30 minute aligned
const at = (min) => t0 + min * 60;
const entry = (id, from, to) => ({ id, startSec: at(from), endSec: at(to) });
const row = () => [entry("A", -10, 22), entry("B", 22, 23), entry("C", 50, 170), entry("D", 170, 200)];
const id = (e) => (e ? e.id : null);

// Right goes programme by programme, whatever the length, over a gap.
{
  const now = at(5), r = row();
  let cursor = null;
  eq("nil is the live programme", id(GC.current(r, cursor, now)), "A");
  const ids = [];
  for (let n = GC.next(r, cursor, now); n; n = GC.next(r, cursor, now)) { ids.push(n.id); cursor = GC.cursorFor(n, now); }
  eq("a one-minute programme, then over the gap, then a two-hour one", ids, ["B", "C", "D"]);
}

// Left goes back and stops at the live programme.
{
  const now = at(5), r = row();
  let cursor = at(170);   // on D
  const ids = [];
  for (let p = GC.previous(r, cursor, now); p; p = GC.previous(r, cursor, now)) { ids.push(p.id); cursor = GC.cursorFor(p, now); }
  eq("back from D", ids, ["C", "B", "A"]);
  eq("back on the live programme the cursor is null", cursor, null);
  eq("Left from the live programme goes to the stripe", GC.previous(r, null, now), null);
}

// Up and Down keep the time: on another row the cursor is on the programme covering it, or in a gap on none.
{
  const now = at(5);
  const other = [entry("X", -20, 40), entry("Y", 60, 90)];
  eq("another row at 22 min", id(GC.current(other, at(22), now)), "X");
  eq("a gap at that time", GC.current(other, at(50), now), null);
  eq("Right from a gap goes to the first programme after it", id(GC.next(other, at(50), now)), "Y");
  eq("Left from a gap goes to the one before that has not ended", id(GC.previous(other, at(50), now)), "X");
}

// A cursor left behind by the clock is at now.
{
  const now = at(25), r = row();
  eq("B ended at 23; now is in the gap", GC.current(r, at(22), now), null);
  eq("Right from there is C", id(GC.next(r, at(22), now)), "C");
}

// The window moves only when the programme would leave the two-hour view, to the slot its start is in.
{
  const now = at(5), r = row();
  const off = (e, offset) => GC.windowOffset(e, offset, t0, now, 44);
  eq("B at 22 min is in view", off(r[1], 0), 0);
  eq("C at 50 min is in view", off(r[2], 0), 0);
  eq("D at 170 min is past the 120 min view: the slot its start is in", off(r[3], 0), 5);
  eq("back to C from there: the slot C starts in", off(r[2], 5), 1);
  eq("the live programme: the slot now is in", off(r[0], 1), 0);
  eq("a start in the last 15 minutes of the view moves the view", off(entry("late", 110, 140), 0), 3);
  eq("a start before the view moves it", off(entry("early", 20, 40), 3), 0);
  eq("the offset never passes the last one", off(entry("far", 5000, 5100), 0), 44);
}

// entryAfter: the first to start at or after the end of the programme.
{
  const r = row();
  eq("after A is B", id(GC.entryAfter(r, r[0])), "B");
  eq("after B is C (over the gap)", id(GC.entryAfter(r, r[1])), "C");
  eq("after D is none", GC.entryAfter(r, r[3]), null);
}

// The page uses it: the keys, the highlight, the info panel and the reset (checked in a browser by guide-cursor-browser-smoke).
const html = readFileSync(new URL("../plex-tuner.html", import.meta.url), "utf8");
eq("the page loads the cursor module", html.includes('<script src="scripts/nostalgex-guide-cursor.js"></script>'), true);
eq("Left and Right call the programme cursor, not the 30 minute step", /moveGuideCursor\(key === 'ArrowRight'\)/.test(html) && !/moveGuideTime\(key === 'ArrowRight' \? 1 : -1\)/.test(html), true);

if (failures.length) {
  console.error(`guide cursor: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`guide cursor: ${passed} checks passed (the Apple TV's GuideProgramCursorTests vectors)`);
