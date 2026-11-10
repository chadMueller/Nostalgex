#!/usr/bin/env node
// The STOP WAITING watch (scripts/nostalgex-load-stall.js) without a browser: the Apple TV's
// detector cases, with time under the test's control. The page and a real scan are
// scripts/stop-waiting-browser-smoke.mjs.
import assert from "node:assert/strict";
import "./nostalgex-load-stall.js";

const L = globalThis.NostalgexLoadStall;
let checks = 0;
const ok = (cond, label) => { assert.ok(cond, label); checks += 1; };
const eq = (a, b, label) => { assert.deepEqual(a, b, label); checks += 1; };

// The two numbers, as the Apple TV and Roku have them.
eq([L.WARN_AFTER_MS, L.STALL_AFTER_MS, L.POLL_MS], [60000, 210000, 2000], "60 s, 210 s, looks every 2 s");

// The page looks every 2 s; a look is the only thing that moves the detector. `until` looks at
// every poll up to that time and returns the last verdict.
const until = (d, sample, from, to) => { let r; for (let t = from + 2000; t <= to; t += 2000) r = d.evaluate(sample, t); return r; };

// Any change in the sample is progress; only silence counts.
{
  const d = L.createDetector("a", 0);
  eq(until(d, "a", 0, 2000).verdict, "progressing", "quiet for 2 s");
  eq(until(d, "a", 2000, 58000).verdict, "progressing", "quiet for 58 s");
  eq(until(d, "a", 58000, 60000).verdict, "slow", "quiet for 60 s: tell the viewer");
  eq(until(d, "a", 60000, 208000).verdict, "slow", "quiet for 208 s");
  eq(until(d, "a", 208000, 210000).verdict, "stalled", "quiet for 210 s: give up");
}
// A slow scan that keeps moving is never stalled, however long it takes.
{
  const d = L.createDetector("p0", 0);
  let verdict = "progressing";
  for (let t = 2000, n = 1; t <= 3600000; t += 2000, n += (t % 40000 === 0 ? 1 : 0)) {
    const r = d.evaluate(`p${n}`, t);   // the sample changes every 40 s
    if (r.verdict !== "progressing") verdict = r.verdict;
  }
  eq(verdict, "progressing", "an hour of a page every 40 s is not a stall");
}
// Progress resets the quiet time.
{
  const d = L.createDetector("a", 0);
  eq(until(d, "a", 0, 100000).verdict, "slow", "100 s quiet");
  eq(d.evaluate("b", 102000).verdict, "progressing", "a change: progressing");
  eq(until(d, "b", 102000, 160000).verdict, "progressing", "58 s since the change");
  eq(until(d, "b", 160000, 162000).verdict, "slow", "60 s since the change");
}
// A page that was asleep (lid closed, throttled tab) is not a quiet server (the Roku port's rule).
{
  const d = L.createDetector("a", 0);
  d.evaluate("a", 2000);
  eq(d.evaluate("a", 2000 + 45 * 60000).verdict, "progressing", "45 minutes asleep, then a look: not counted");
  eq(d.evaluate("a", 2000 + 45 * 60000 + 2000).verdict, "progressing", "and the next look");
}
// sampleKey: every counter and the answers count move it.
{
  const base = { phase: "scanningLibrary", detail: "Movies", scanSectionIndex: 1, scanTotalSections: 4, scanItemsFound: 100 };
  const k = L.sampleKey(base, 5);
  ok(k !== L.sampleKey({ ...base, scanItemsFound: 101 }, 5), "items found");
  ok(k !== L.sampleKey({ ...base, scanSectionIndex: 2 }, 5), "section");
  ok(k !== L.sampleKey({ ...base, detail: "Movies (300/900)" }, 5), "detail");
  ok(k !== L.sampleKey(base, 6), "an answered request");
  eq(k, L.sampleKey({ ...base }, 5), "the same state is the same key");
}
// The watch, with a clock and a timer the test drives.
function rig() {
  let now = 0;
  let fn = null;
  const events = { verdicts: [], abandons: [] };
  let sample = "a";
  const w = L.watch({
    sample: () => sample, now: () => now,
    setInterval: (f) => { fn = f; return 1; }, clearInterval: () => { fn = null; },
    onVerdict: (v, q) => events.verdicts.push(v), onAbandon: (user, q) => events.abandons.push([user, q]),
  });
  // Time passes in the page's own 2 s looks.
  const advance = (ms, newSample) => { if (newSample !== undefined) sample = newSample; for (let t = 0; t < ms; t += 2000) { now += Math.min(2000, ms - t); if (fn) fn(); } };
  return { w, events, advance, running: () => fn !== null };
}
{
  const r = rig();
  r.advance(62000);
  eq(r.events.verdicts.at(-1), "slow", "watch: slow after 62 s");
  eq(r.w.stopWaiting(), true, "watch: a press while running counts");
  eq(r.events.abandons, [[true, 0]], "watch: abandoned by the viewer");
  eq(r.events.verdicts.at(-1), "progressing", "watch: the block goes with the scan");
  ok(!r.running(), "watch: the timer is stopped");
  eq(r.w.stopWaiting(), false, "watch: a second press is nothing");
  eq(r.w.abandoned, { userInitiated: true, quietMs: 0 }, "watch: says how it ended");
}
{
  const r = rig();
  r.advance(208000);
  eq(r.events.abandons, [], "watch: not at 208 s");
  r.advance(2000);
  eq(r.events.abandons, [[false, 210000]], "watch: gives up on its own at 210 s");
  ok(!r.running(), "watch: and stops looking");
}
// A press belongs to the scan it was made on: a finished watch ignores it, a new watch is not affected.
{
  const first = rig();
  first.advance(1000);
  first.w.stop();                      // server 1's scan finished
  const second = rig();                // server 2's scan starts a watch of its own
  eq(first.w.stopWaiting(), false, "press after the first scan ended: nothing");
  eq(second.events.abandons, [], "the second scan is not abandoned by it");
  eq(second.w.abandoned, null, "and its watch is still running");
  ok(second.running(), "and looking");
}
console.log(`load stall smoke: ${checks} checks passed (60 s / 210 s, silence only, sleep not counted, a press belongs to its scan)`);
