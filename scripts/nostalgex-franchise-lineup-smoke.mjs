#!/usr/bin/env node
/**
 * Golden-vector test for the franchise channels and the FRANCHISES / OTHER COLLECTIONS split:
 * scripts/nostalgex-collections.js (`classify`, `keptInDisplayOrder`, `materialize`) and
 * scripts/nostalgex-franchise-lineup.js (`build`).
 *
 * Reads scripts/franchise-lineup-golden.json, franchises.json and channels.json, the same
 * files Nostalgex/NostalgexTests/FranchiseLineupGoldenTests.swift reads. The expected
 * answers in the file were written by that Swift test from the Apple TV's own code, so
 * passing here means the web tuner and Docker build the same franchise channels, folds,
 * Settings rows and numbers as the Apple TV from the same library. The Roku tests read a
 * byte copy of the file.
 *
 * Run: `npm run test:franchise-lineup`
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deepStrictEqual } from "node:assert/strict";
import "./nostalgex-channel-filter.cjs";
import "./nostalgex-franchise-builder.js";
import "./nostalgex-collections.js";
import "./nostalgex-franchise-lineup.js";

const C = globalThis.NostalgexCollections;
const FL = globalThis.NostalgexFranchiseLineup;
const here = dirname(fileURLToPath(import.meta.url));
const golden = JSON.parse(readFileSync(resolve(here, "franchise-lineup-golden.json"), "utf8"));
const dictionary = JSON.parse(readFileSync(resolve(here, "..", "franchises.json"), "utf8"));
const channelsJson = JSON.parse(readFileSync(resolve(here, "..", "channels.json"), "utf8"));

let passed = 0;
const failures = [];

function check(label, fn) {
  try {
    fn();
    passed += 1;
  } catch (err) {
    failures.push(`${label}\n    ${String(err.message).split("\n").slice(0, 24).join("\n    ")}`);
  }
}

/** The library item the page holds for a golden item. */
function toItem(g) {
  const isEpisode = g.type === "episode";
  const item = {
    id: g.id,
    ratingKey: g.id,
    serverID: "srv",
    type: g.type,
    title: g.title,
    tmdbID: g.tmdbID ?? g.id,
    genres: g.genres ?? [],
    duration: isEpisode ? 45 : 120,
    librarySource: isEpisode ? "tv" : "movie",
  };
  if (isEpisode) {
    item.episodeTitle = g.episodeTitle ?? "Pilot";
    if (g.showKey != null) item.showKey = g.showKey;
  }
  if (g.enrichment) item.enrichment = g.enrichment;
  return item;
}

// ── The collection classifier ──

for (const c of golden.classifier) {
  check(`classifier: ${c.name}`, () => {
    deepStrictEqual(C.classify(c.title, c.items.map(toItem)), c.expected);
  });
}

// ── The blocks ──

for (const b of golden.blocks) {
  check(`block: ${b.name}`, () => {
    const entries = b.entries.map((e) => ({ id: e.id, name: e.name, stableID: e.id, films: e.films }));
    const got = C.keptInDisplayOrder(entries, b.capacity);
    deepStrictEqual(got.kept.map((e) => e.id), b.kept);
    deepStrictEqual(got.skipped, b.skipped);
  });
}

// ── The lineups ──

const kindOf = (id) => (id >= C.ID_BASE ? "otherCollection" : id >= C.FRANCHISE_COLLECTION_ID_BASE ? "franchiseCollection" : "found");
const BUNDLE_CHANNEL_IDS = channelsJson.bundles.find((b) => b.id === "franchises").channelIDs;

function runLineup(s) {
  const items = s.items.map(toItem);
  const enabledIDs = new Set(s.enabledFranchiseIDs);
  const disabledIDs = new Set(s.disabledFranchiseIDs);
  const itemById = new Map(items.map((i) => [i.id, i]));
  const defs = new Map(channelsJson.channels.map((c) => [c.id, c]));
  const stockChannels = Object.keys(s.stock).map((id) => {
    const def = defs.get(Number(id));
    return {
      id: def.id, number: def.number, name: def.name, stock: true, category: def.category,
      itemPool: s.stock[id].map((x) => itemById.get(x)),
    };
  });
  const raw = s.collections.map((c) => ({ id: c.id, title: c.title, childKeys: c.members, serverKey: "srv" }));
  const result = FL.build({
    definitions: dictionary,
    packageOn: s.packageOn,
    enabledIDs,
    disabledIDs,
    items,
    stockChannels,
    bundleChannelIDs: BUNDLE_CHANNEL_IDS,
    itemKey: (it) => it.ratingKey,
    manifest: s.manifest,
    exclusiveRules: s.exclusiveRules,
    collections: {
      raw,
      indexByServer: C.indexLibrary(items, () => "srv"),
      staticChannels: stockChannels,
      channelsByID: new Map(stockChannels.map((c) => [c.id, c])),
      enabledKeys: new Set(s.enabledCollectionIDs),
      manifest: s.manifest,
    },
  });

  const ids = (list) => list.map((i) => i.id);
  const unioned = new Map(stockChannels.map((c) => [c.id, [...c.itemPool, ...(result.stockAdditions.get(c.id) || [])]]));
  const byCollection = new Map(result.candidates.map((c) => [c.id, c]));
  const overCap = {};
  if (result.overCapFound) overCap.foundFranchises = result.overCapFound;
  if (result.overCapFranchises) overCap.collectionFranchises = result.overCapFranchises;
  if (result.overCapCustom) overCap.otherCollections = result.overCapCustom;

  // The guide, as the page filters it: the classics and the runtime channels.
  const guide = [...stockChannels, ...result.channels]
    .filter((ch) => FL.franchiseChannelVisible(ch, {
      packageOn: s.packageOn, bundleChannelIDs: BUNDLE_CHANNEL_IDS, switchedOffStock: result.switchedOffStock,
    }))
    .map((ch) => ch.number)
    .filter((n) => n >= 300 && n <= 499)
    .sort((a, b) => a - b);

  return {
    candidates: byCollection,
    stockChannels,
    got: {
      found: result.found.map((f) => ({
        id: f.id, name: f.name, covered: f.coveredByChannelID, fromDictionary: f.fromDictionary, enabled: f.enabled,
        movies: ids(f.movies), tvItems: ids(f.tvItems),
      })),
      stockPools: Object.fromEntries([...unioned].map(([id, pool]) => [String(id), ids(pool)])),
      switchedOffStock: [...result.switchedOffStock].sort((a, b) => a - b),
      rows: result.rows,
      collections: s.collections.map((c) => {
        const cand = byCollection.get(c.id);
        return { id: c.id, title: cand.title, category: cand.category, foldedInto: cand.foldedInto };
      }),
      channels: result.channels.map((ch) => ({
        number: ch.number, id: ch.id, name: ch.name, kind: kindOf(ch.id), items: ids(ch.itemPool),
      })),
      overCap,
      guide,
    },
  };
}

for (const s of golden.lineups) {
  check(`lineup: ${s.name}`, () => {
    if (!s.expected) throw new Error("the golden file has no expected answer for this lineup");
    const { got } = runLineup(s);
    // The nullable fields are written as null in the file.
    const norm = (v) => JSON.parse(JSON.stringify(v, (_, x) => (x === undefined ? null : x)));
    for (const key of ["found", "stockPools", "switchedOffStock", "rows", "collections", "channels", "overCap", "guide"]) {
      deepStrictEqual(norm(got[key]), s.expected[key], `${key}`);
    }
  });

  // The Swift test is given the name match and the manifest overlap of each collection as
  // inputs. This engine works them out itself; they must come to the same thing.
  check(`lineup inputs: ${s.name}`, () => {
    const { candidates } = runLineup(s);
    for (const c of s.collections) {
      const cand = candidates.get(c.id);
      deepStrictEqual(cand.matchedChannel, c.matchedChannel ?? null, `name match of ${c.id}`);
      const o = cand.contentOverlap;
      const want = c.contentOverlap;
      deepStrictEqual(
        o ? { channelID: o.channelID, overlapCount: o.overlapCount, totalCount: o.totalCount } : null,
        want ? { channelID: want.channelID, overlapCount: want.overlapCount, totalCount: want.totalCount } : null,
        `manifest overlap of ${c.id}`,
      );
    }
  });
}

// ── What the golden file does not reach ──

check("numbers: the blocks sit where the Apple TV puts them", () => {
  deepStrictEqual(
    [C.FOUND_ID_BASE, C.FRANCHISE_COLLECTION_ID_BASE, C.ID_BASE],
    [1000000, 1010000, 1020000],
  );
  deepStrictEqual([C.FRANCHISE_NUMBER_BASE, C.FRANCHISE_NUMBER_END, C.FRANCHISE_CAPACITY], [310, 399, 90]);
  deepStrictEqual([C.NUMBER_BASE, C.NUMBER_END, C.CAPACITY], [400, 499, 100]);
});

check("channels.json: the classics are CH 300-306 and nothing numbered reaches 310-499", () => {
  const franchises = channelsJson.bundles.find((b) => b.id === "franchises");
  deepStrictEqual(
    franchises.channelIDs.map((id) => channelsJson.channels.find((c) => c.id === id).number),
    [300, 301, 302, 303, 304, 305, 306],
  );
  const clash = channelsJson.channels.filter((c) => c.number >= 310 && c.number <= 499).map((c) => c.number);
  deepStrictEqual(clash, []);
});

check("materialize: without categories or found franchises it is the original one block", () => {
  const items = [1, 2, 3].map((n) => ({ ratingKey: `k${n}`, type: "movie", title: `M${n}`, duration: 100 }));
  const cand = (id, title) => ({ id, title, items, movieCount: 3, enabled: true, foldedInto: null });
  const { channels, overCap, overCapFranchises, overCapFound } = C.materialize([cand("a", "A SAGA"), cand("b", "B")]);
  deepStrictEqual(channels.map((c) => [c.number, c.id, c.name]), [[400, 1020000, "A SAGA"], [401, 1020001, "B"]]);
  deepStrictEqual([overCap, overCapFranchises, overCapFound], [0, 0, 0]);
});

check("classify: music videos and the like are films, episodes are not", () => {
  deepStrictEqual(C.classify("Reality TV", [{ type: "episode", title: "Alpha Island" }, { type: "episode", title: "Bravo" }]), "custom");
});

const total = passed + failures.length;
if (failures.length) {
  console.error(`franchise lineup golden: ${failures.length} of ${total} FAILED`);
  for (const f of failures) console.error(`  x ${f}`);
  process.exit(1);
}
console.log(
  `franchise lineup golden: ${total} checks passed (${golden.classifier.length} classifier cases, ` +
    `${golden.blocks.length} block cases, ${golden.lineups.length} lineups)`,
);
