#!/usr/bin/env node
/**
 * Golden vectors for the global Watershed setting.
 *
 * Reads scripts/watershed-golden.json, the same file
 * Nostalgex/NostalgexTests/WatershedGoldenTests.swift reads, and runs every case against
 * plex-tuner.html's getTimeFilteredPool and isWatershedHold (lifted out of the page the
 * same way scripts/nostalgex-rating-smoke.mjs lifts getTimeFilteredPool for the VHS VAULT
 * check). Both engines must agree on which items a channel's pool keeps at a given local
 * hour with the toggle on or off, and on whether a channel counts as a Watershed hold.
 *
 * Run: `npm run test:watershed`
 */
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
// Loading this sets globalThis.NostalgexChannelFilter as a side effect (its own module
// tail does this unconditionally), which is how getTimeFilteredPool's usRating lookup
// normalises GB-15/GB-18/TV-MA the same way the Apple TV's ContentRating.usLabel does.
require("./nostalgex-channel-filter.cjs");

const root = new URL("../", import.meta.url);
const golden = JSON.parse(readFileSync(new URL("scripts/watershed-golden.json", root), "utf8"));
const html = readFileSync(new URL("plex-tuner.html", root), "utf8");

function liftFunction(src, name) {
  const at = src.search(new RegExp(`function\\s+${name}\\s*\\(`));
  if (at < 0) throw new Error(`plex-tuner.html has no function ${name}`);
  let i = src.indexOf("{", src.indexOf(")", at));
  for (let depth = 0; ; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) break;
  }
  return src.slice(at, i + 1);
}

// isWatershedHold calls getTimeFilteredPool by name, so both have to be defined in the
// same evaluated scope rather than lifted and evaluated one at a time.
const { getTimeFilteredPool, isWatershedHold } = new Function(
  `${liftFunction(html, "getTimeFilteredPool")}\n${liftFunction(html, "isWatershedHold")}\n` +
    "return { getTimeFilteredPool, isWatershedHold };",
)();

function atLocalHour(hour, fn) {
  const RealDate = globalThis.Date;
  const ms = new RealDate(2026, 9, 21, hour, 30).getTime();
  globalThis.Date = class extends RealDate {
    constructor(...a) { if (a.length) super(...a); else super(ms); }
    static now() { return ms; }
  };
  try { return fn(); } finally { globalThis.Date = RealDate; }
}

const failures = [];
let passed = 0;

for (const c of golden.cases) {
  const pool = c.pool.map((p) => ({ ratingKey: p.ratingKey, contentRating: p.contentRating, type: p.type }));
  const channel = {
    itemPool: pool,
    timeRestrictions: c.hasOwnBlockRatings
      ? { blockRatings: { ratings: ["R", "NC-17"], blockBefore: 21, blockAfter: null } }
      : null,
  };

  const problems = [];
  const gotPool = atLocalHour(c.hour, () => getTimeFilteredPool(channel, c.watershedEnabled).map((i) => i.ratingKey));
  const gotHold = atLocalHour(c.hour, () => isWatershedHold(channel, c.watershedEnabled));

  const wantPool = JSON.stringify(c.expectPool);
  const gotPoolJSON = JSON.stringify(gotPool);
  if (gotPoolJSON !== wantPool) problems.push(`pool ${gotPoolJSON}, want ${wantPool}`);
  if (gotHold !== c.expectHold) problems.push(`hold ${gotHold}, want ${c.expectHold}`);

  if (problems.length) failures.push(`${c.name}: ${problems.join("; ")}`);
  else passed += 1;
}

if (failures.length) {
  console.error(`watershed: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`watershed: ${passed} cases passed`);
