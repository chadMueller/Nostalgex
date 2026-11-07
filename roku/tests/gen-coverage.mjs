// Library coverage vectors (#207), from upstream's scripts/nostalgex-library-coverage.js
// and the filter's itemPasses, run exactly as plex-tuner.html runs them
// (runLibraryCoverage). Called by tests/gen-vectors.mjs, which owns the output
// and --check.
//
// The library and channels are the filter vectors' (tests/gen-filter.mjs):
// real channels and a library built to hit each one, cut down (below). That library holds
// one or two titles per channel, so each case gives the channels a minItems of
// its own: 1 (any hit covers), 2, a mix by channel id, and the real ones (no
// channel reaches them). A case may add built collection and franchise pools.
// For each case the vector holds what compute returns, formatLine's line with
// a skipped count, and orphanReport's line.
import { createRequire } from "node:module";
import { join } from "node:path";
import { filterVectors, CLOCKS } from "./gen-filter.mjs";

export async function coverageVectors(upstream) {
  const require = createRequire(import.meta.url);
  require(join(upstream, "scripts", "nostalgex-library-coverage.js"));
  const LC = globalThis.NostalgexLibraryCoverage;
  const CF = require(join(upstream, "scripts", "nostalgex-channel-filter.cjs"));
  const config = require(join(upstream, "channels.json"));
  const manifest = require(join(upstream, "channels-memberships.json"));
  const fv = filterVectors(upstream);
  const exclusiveRules = fv.exclusiveRules;
  // Only the real channels: synthetic ones reuse their ids.
  const real = new Set(config.channels.map((c) => c.id));
  // Every fourth real channel and every second title: the interpreter runs
  // the filter at about 2 ms a title and channel, and each case is a full
  // pass, so the whole set would take over an hour off-device.
  const base = fv.channels.filter((c, i) => real.has(c.id) && fv.channels.findIndex((d) => d.id === c.id) === i)
    .filter((c, i) => i % 4 === 0);
  // Every loaded title has a runtime (the loaders drop the rest), so the
  // console line never reads "undefinedm".
  const items = fv.items.filter((it, i) => i % 2 === 0).map((it) => ({ ...it, duration: it.duration || 90 }));
  const realMin = Object.fromEntries(config.channels.map((c) => [c.id, c.minItems]));

  const cases = [
    { name: "min 1", min: () => 1, skipped: 0 },
    { name: "min 2", min: () => 2, skipped: 3 },
    { name: "min by id", min: (c) => 1 + (c.id % 3), skipped: 1234 },
    { name: "real minItems", min: (c) => realMin[c.id], skipped: 0 },
    // A built collection and a franchise channel: their pools count whatever
    // their size, on top of every channel short of its minimum.
    { name: "real minItems, built pools", min: (c) => realMin[c.id], skipped: 12, dynamic: [[0, 5, 9], [5, 40]] },
    { name: "min 2, built pools", min: () => 2, skipped: 0, dynamic: [[1, 2, 3, 4]] },
  ];
  const out = [];
  for (const clock of CLOCKS) {
    const ctx = clock.name === "A" ? fv.clocks[0] : fv.clocks[1];
    for (const c of cases) {
      const channels = base.map((ch) => ({ id: ch.id, rules: ch.rules, category: ch.category, minItems: c.min(ch) }));
      const dynamicIdx = (c.dynamic || []).map((pool) => pool.filter((i) => i < items.length));
      const dynamicPools = dynamicIdx.map((pool) => pool.map((i) => items[i]));
      const opts = { manifest, exclusiveRules, backend: clock.backend, nowSec: ctx.nowSec };
      const result = await withClock(clock.iso, () => LC.compute({
        items, channels, dynamicPools,
        passes: (item, ch) => CF.itemPasses(item, ch, opts) !== false,
        keyOf: (it) => `${it.ratingKey}`,
        yieldFn: async () => {},
      }));
      out.push({
        clock: clock.name,
        name: c.name,
        minItems: channels.map((ch) => ch.minItems),
        dynamic: dynamicIdx,
        skipped: c.skipped,
        loaded: result.loaded,
        onChannels: result.onChannels,
        totalLoaded: result.totalLoaded,
        totalOnChannels: result.totalOnChannels,
        orphanSample: result.orphanSample.map((it) => it.ratingKey),
        line: LC.formatLine(result, c.skipped) || "",
        report: LC.orphanReport(result, 7),
      });
    }
  }
  return {
    clocks: fv.clocks,
    exclusiveRules,
    channels: base.map((c) => ({ id: c.id, category: c.category, rules: c.rules })),
    items,
    cases: out,
  };
}

async function withClock(iso, fn) {
  const RealDate = globalThis.Date;
  const fixed = new RealDate(iso).getTime();
  class PinnedDate extends RealDate {
    constructor(...args) {
      if (args.length === 0) super(fixed);
      else super(...args);
    }
    static now() { return fixed; }
  }
  globalThis.Date = PinnedDate;
  try {
    return await fn();
  } finally {
    globalThis.Date = RealDate;
  }
}
