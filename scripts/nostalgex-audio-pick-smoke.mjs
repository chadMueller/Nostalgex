#!/usr/bin/env node
// The audio-track pick and the commentary rule, against scripts/audio-pick-golden.json (the Apple TV's test vectors).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const here = (p) => fileURLToPath(new URL(p, import.meta.url));
await import("./nostalgex-language.js");
await import("./nostalgex-audio-pick.js");
const A = globalThis.NostalgexAudioPick;
const golden = JSON.parse(readFileSync(here("./audio-pick-golden.json"), "utf8"));
let passed = 0; const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

for (const t of golden.commentaryTitles.yes) check(`isCommentary: ${t}`, A.isCommentary(t) === true);
for (const t of golden.commentaryTitles.no) check(`not commentary: ${JSON.stringify(t)}`, A.isCommentary(t) === false);
check("isCommentary(null) is false", A.isCommentary(null) === false);
check("either title can say it", A.isCommentary(null, "Director's commentary") === true);

for (const c of golden.jellyfinAndEmby) {
  const got = A.preferredAudioStream(c.streams, { audioLanguage: c.audioLanguage, preferredLanguages: c.preferredLanguages });
  check(c.name, (got ? got.index : null) === c.expect, `got ${got ? got.index : null}, want ${c.expect}`);
}
for (const c of golden.plex) {
  const got = A.plexAudioStream(c.streams);
  check(`plex: ${c.name}`, (got ? got.id : null) === c.expect, `got ${got ? got.id : null}, want ${c.expect}`);
}
check("no streams: null", A.preferredAudioStream([], {}) === null && A.preferredAudioStream(undefined, {}) === null && A.plexAudioStream(undefined) === null);

if (failures.length) { console.error(`audio pick smoke: ${failures.length} failed, ${passed} passed`); for (const f of failures) console.error("  FAIL " + f); process.exit(1); }
console.log(`audio pick smoke: ${passed} checks passed`);
