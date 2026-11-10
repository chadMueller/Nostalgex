#!/usr/bin/env node
// Music video title cleanup (N-034), against scripts/music-title-golden.json, the file the Swift
// and Roku ports are to match. Negative control: the cleanup as it was before N-034 fails the
// cases it was reported for.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

globalThis.window = globalThis;
await import("./nostalgex-music-brainz.js");
const MB = globalThis.NostalgexMusicBrainz;
const golden = JSON.parse(readFileSync(new URL("./music-title-golden.json", import.meta.url), "utf8"));

let checks = 0;
for (const c of golden.clean) {
  assert.equal(MB.cleanTitle(c.in), c.out, `clean(${JSON.stringify(c.in)})`);
  checks += 1;
}
for (const c of golden.parse) {
  const r = MB.parseTitle(c.in);
  assert.deepEqual({ artist: r.artist, song: r.song }, { artist: c.artist, song: c.song }, `parse(${JSON.stringify(c.in)})`);
  checks += 1;
}

// Nothing in a cleaned title is left empty or half-open, whatever the input.
const reported = golden.clean.filter((c) => /\((?:official|music|lyric|video|hd|remastered|audio)/i.test(c.in) && !/live|explicit|extended/i.test(c.in));
for (const c of reported) {
  const out = MB.cleanTitle(c.in);
  assert.ok(!/\(\s*\)|\(\s|\s\)/.test(out), `no empty or padded parentheses in ${JSON.stringify(out)}`);
  checks += 1;
}

// The cleanup before N-034, kept here to prove the cases bite.
function before(raw) {
  let t = String(raw || "").replace(/_/g, " ");
  t = t.replace(/\[[^\]]*\]|\{[^}]*\}/g, "");
  t = t.replace(/\s*\((?:19|20)\d\d\)\s*$/, "");
  t = t.replace(/\([^)]*(?:19|20)\d\d[^)]*\)/g, "");
  t = t.replace(/\b(official|video|hd|hq|lyrics?|remaster(?:ed)?|mv|xvid|dvdrip|vgb|prv)\b!?/gi, "");
  t = t.replace(/\s+/g, " ");
  return t.replace(/^[\s\-!.]+|[\s\-!.]+$/g, "");
}
assert.equal(before("Song (Official Music Video)"), "Song ( Music )");
assert.equal(before("Song (Official Video)"), "Song ( )");
const bitten = golden.clean.filter((c) => before(c.in) !== c.out).length;
assert.ok(bitten >= 18, `the old cleanup fails ${bitten} of the golden cases`);
checks += 3;

console.log(`music title smoke: ${checks} checks passed (${golden.clean.length} clean cases, ${golden.parse.length} parse cases; the old cleanup fails ${bitten} of the clean cases)`);
