#!/usr/bin/env node
// UP NEXT IN n MIN: the wording the Apple TV's Now Playing panel uses (UpNextLabel in NowPlayingPanelLogic.swift).
await import("./nostalgex-up-next.js");
const { label } = globalThis.NostalgexUpNext;
const cases = [
  [0, "UP NEXT IN LESS THAN 1 MIN"], [59.9, "UP NEXT IN LESS THAN 1 MIN"], [-5, "UP NEXT IN LESS THAN 1 MIN"], [NaN, "UP NEXT IN LESS THAN 1 MIN"],
  [60, "UP NEXT IN 1 MIN"], [119, "UP NEXT IN 1 MIN"], [12 * 60 + 30, "UP NEXT IN 12 MIN"], [59 * 60 + 59, "UP NEXT IN 59 MIN"],
  [3600, "UP NEXT IN 1 HR"], [3600 + 5 * 60 + 40, "UP NEXT IN 1 HR 5 MIN"], [2 * 3600, "UP NEXT IN 2 HR"], [2 * 3600 + 59 * 60, "UP NEXT IN 2 HR 59 MIN"],
];
let bad = 0;
for (const [sec, want] of cases) { const got = label(sec); if (got !== want) { bad += 1; console.error(`  FAIL ${sec}: got "${got}", want "${want}"`); } }
if (bad) { console.error(`up next smoke: ${bad} failed`); process.exit(1); }
console.log(`up next smoke: ${cases.length} checks passed`);
