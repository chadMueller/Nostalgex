#!/usr/bin/env node
/**
 * Puts the Apple TV's answers into scripts/franchise-lineup-golden.json.
 *
 * The expected answers in that file are not written by any engine that is checked
 * against it. FranchiseLineupGoldenTests.swift builds every case with the app's own
 * code and, when TEST_RUNNER_NOSTALGEX_GOLDEN_DUMP names a file, writes what it got
 * there instead of comparing. This script merges that dump in:
 *
 *   TEST_RUNNER_NOSTALGEX_GOLDEN_DUMP=/tmp/dump.json xcodebuild test ... \
 *     -only-testing:NostalgexTests/FranchiseLineupGoldenTests
 *   node scripts/merge-franchise-lineup-golden.mjs /tmp/dump.json
 *
 * Read the diff before committing it: a changed answer is a change in the Apple TV's
 * behaviour, and the web tuner, Docker and Roku have to follow it.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const path = resolve(here, "franchise-lineup-golden.json");
const dumpPath = process.argv[2];
if (!dumpPath) {
  console.error("usage: merge-franchise-lineup-golden.mjs <dump.json>");
  process.exit(2);
}
const golden = JSON.parse(readFileSync(path, "utf8"));
const dump = JSON.parse(readFileSync(dumpPath, "utf8"));

if (dump.classifier.length !== golden.classifier.length) throw new Error("classifier cases differ from the dump");
if (dump.blocks.length !== golden.blocks.length) throw new Error("block cases differ from the dump");
if (dump.lineups.length !== golden.lineups.length) throw new Error("lineups differ from the dump");

golden.classifier.forEach((c, i) => { c.expected = dump.classifier[i]; });
golden.blocks.forEach((b, i) => { b.kept = dump.blocks[i].kept; b.skipped = dump.blocks[i].skipped; });

// Swift leaves a nil out; the file writes it as null, so every engine reads the same shape.
const nullable = {
  found: ["covered"],
  rows: ["stockChannelID", "channelNumber"],
  collections: ["foldedInto"],
};
golden.lineups.forEach((s, i) => {
  const e = dump.lineups[i];
  for (const [key, fields] of Object.entries(nullable)) {
    for (const row of e[key]) for (const f of fields) if (row[f] === undefined) row[f] = null;
  }
  s.expected = {
    found: e.found,
    stockPools: e.stockPools,
    switchedOffStock: e.switchedOffStock,
    rows: e.rows,
    collections: e.collections,
    channels: e.channels,
    overCap: e.overCap,
    guide: e.guide,
  };
});

// Compact: whatever fits on one line stays on one, long lists of ids wrap.
function fmt(v, indent = "") {
  const flat = JSON.stringify(v);
  if (flat === undefined) return "null";
  if (flat.length + indent.length <= 118 || typeof v !== "object" || v === null) return flat;
  const inner = indent + " ";
  if (Array.isArray(v)) {
    if (v.every((x) => typeof x !== "object" || x === null)) {
      const lines = [];
      let line = "";
      for (const x of v) {
        const piece = JSON.stringify(x);
        if (line && (inner + line + ", " + piece).length > 118) { lines.push(line + ","); line = piece; }
        else line = line ? line + ", " + piece : piece;
      }
      if (line) lines.push(line);
      return "[\n" + lines.map((l) => inner + l).join("\n") + "\n" + indent + "]";
    }
    return "[\n" + v.map((x) => inner + fmt(x, inner)).join(",\n") + "\n" + indent + "]";
  }
  return "{\n" + Object.entries(v).map(([k, x]) => `${inner}${JSON.stringify(k)}: ${fmt(x, inner)}`).join(",\n") + "\n" + indent + "}";
}

writeFileSync(path, fmt(golden) + "\n");
console.log(`merged ${dump.classifier.length} classifier cases, ${dump.blocks.length} block cases and ${dump.lineups.length} lineups into ${path}`);
