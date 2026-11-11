#!/usr/bin/env node
// The starvation watch, the failure run and the capped-retry ladder, replaying Nostalgex/NostalgexTests/PlaybackStarvationTests.swift.
await import("./nostalgex-playback-recovery.js");
const R = globalThis.NostalgexPlaybackRecovery;
let passed = 0; const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const feed = (m, playheads, remaining = 3000) => { for (let i = 0; i < playheads.length; i++) { const v = m.observe(playheads[i], i, false, remaining); if (v) return v; } return null; };
const playing = (from, seconds) => Array.from({ length: seconds }, (_, i) => from + i);
const frozen = (at, seconds) => Array(seconds).fill(at);

{ const m = R.createStarvationMonitor(); check("a healthy stream never starves", feed(m, playing(0, 600)) === null && m.armed); }
{
  const m = R.createStarvationMonitor(); let trace = [], head = 0;
  for (let i = 0; i < 3; i++) { trace = trace.concat(playing(head, 25)); head += 25; trace = trace.concat(frozen(head, 10)); }
  trace = trace.concat(playing(head, 5));
  const v = feed(m, trace);
  check("three stalls inside the window are starving", v && v.stalls === 3 && v.longestStallSeconds >= 9, JSON.stringify(v));
}
{ const m = R.createStarvationMonitor(); const v = feed(m, playing(100, 30).concat(frozen(130, 25))); check("one long freeze is starving on its own", v && v.stalls === 1 && v.longestStallSeconds >= R.HARD_STALL_SECONDS, JSON.stringify(v)); }
{ const m = R.createStarvationMonitor(); check("startup is not a stall", feed(m, frozen(0, 60)) === null && !m.armed); }
{
  const m = R.createStarvationMonitor(); let trace = [], head = 0;
  for (let i = 0; i < 40; i++) { trace = trace.concat(playing(head, 8)); head += 8; trace = trace.concat(frozen(head, 2)); }
  check("brief segment pauses are not stalls", feed(m, trace) === null);
}
{
  const m = R.createStarvationMonitor(); let trace = [], head = 0;
  for (let i = 0; i < 3; i++) { trace = trace.concat(playing(head, 90)); head += 90; trace = trace.concat(frozen(head, 5)); }
  trace = trace.concat(playing(head, 5));
  check("stalls spread wider than the window do not add up", feed(m, trace) === null);
}
{
  const m = R.createStarvationMonitor(); for (let i = 0; i < 10; i++) m.observe(i, i, false, 3000);
  let any = null; for (let i = 10; i < 60; i++) { const v = m.observe(10, i, true, 3000); if (v) any = v; }
  check("paused samples are ignored", any === null);
}
{
  // A stall begins, the viewer pauses for a minute and resumes: that is not a freeze.
  const m = R.createStarvationMonitor(); for (let i = 0; i < 10; i++) m.observe(i, i, false, 3000);
  m.observe(10, 10, false, 3000); m.observe(10, 12, false, 3000);
  let any = null; for (let i = 13; i < 73; i++) { const v = m.observe(10, i, true, 3000); if (v) any = v; }
  const after = m.observe(10, 73, false, 3000);
  check("a stall in progress does not survive a pause", any === null && after === null, JSON.stringify(after));
}
{
  const m = R.createStarvationMonitor();
  const v = feed(m, playing(0, 30).concat(frozen(30, 40)), 4);   // 4 s from the end: the tail belongs to the end fallback
  check("the tail of an item is not starvation", v === null);
}

{
  const run = R.createFailureRun();
  let stopped = false; for (let i = 0; i < 4; i++) stopped = run.recordFailure(7);
  check("four failures in a row do not stop the channel", !stopped && !run.isStopped);
  check("the fifth does", run.recordFailure(7) === true && run.isStopped);
  run.reset(); check("a picture (reset) starts the count again", run.count === 0 && !run.isStopped);
  run.recordFailure(7); run.recordFailure(7); check("another channel starts its own count", run.recordFailure(8) === false && run.count === 1);
}
check("the limit is five", R.FAILURE_RUN_LIMIT === 5);

check("direct play goes to the server stream", R.nextRung("direct", false, false) === "server");
check("a server stream goes to one retry capped at 1080p", R.nextRung("server", false, false) === "capped1080");
check("not if the viewer already caps quality at 1080p or lower", R.nextRung("server", true, false) === "fail");
check("not twice", R.nextRung("server", false, true) === "fail");
check("a capped retry that fails is a failure", R.nextRung("server", false, true) === "fail");

if (failures.length) { console.error(`playback recovery smoke: ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`playback recovery smoke: ${passed} checks passed`);
