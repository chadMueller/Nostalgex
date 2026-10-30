#!/usr/bin/env node
/**
 * Golden vectors for scripts/nostalgex-channel-filter.cjs.
 *
 * Reads scripts/filter-golden.json, the same file
 * Nostalgex/NostalgexTests/FilterGoldenTests.swift reads, and runs every case
 * against the shipped channels.json, its exclusive rules and
 * channels-memberships.json. Both engines must agree, so the web tuner, the
 * Docker image and the Apple TV app put the same title on the same channels.
 *
 * Run: `npm run test:filter-golden`
 */
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const CF = require("./nostalgex-channel-filter.cjs");
const root = new URL("../", import.meta.url);
const read = (p) => JSON.parse(readFileSync(new URL(p, root), "utf8"));
const golden = read("scripts/filter-golden.json");
const config = read("channels.json");
const manifest = read("channels-memberships.json");

// Same normalisation as plex-tuner.html loadStockChannelsFromJSON.
const exclusiveRules = (config.exclusiveRules || []).map((r) => ({
  channelIDs: r.channelIDs || (r.channelID != null ? [r.channelID] : []),
  genres: r.genres || [],
  titleContains: r.titleContains || [],
  editorialTitles: r.editorialTitles || [],
  manifestExclusive: !!r.manifestExclusive,
  type: r.type || null,
  source: r.source || null,
}));
const channels = new Map(config.channels.map((c) => [c.id, c]));

function toItem(g) {
  const item = {
    title: g.title,
    artist: g.artist ?? null,
    episodeTitle: g.episodeTitle ?? null,
    summary: g.summary ?? "",
    originallyAvailableAt: g.originallyAvailableAt ?? null,
    year: g.year ?? null,
    type: g.type || "movie",
    librarySource: g.librarySource || (g.type === "episode" ? "tv" : "movie"),
    genres: g.genres || [],
    contentRating: g.contentRating ?? null,
    duration: g.duration ?? 100,
    rating: g.rating ?? 0,
    userRating: 0,
    viewCount: 0,
    addedAt: 0,
    studio: g.studio ?? null,
    tmdbID: g.tmdbID ?? null,
    ratingKey: "golden",
    doviProfile: g.doviProfile ?? null,
  };
  if (g.enrichment) {
    item.enrichment = {
      keywords: g.enrichment.keywords || [],
      productionCompanies: g.enrichment.productionCompanies || [],
      networks: g.enrichment.networks || [],
      tmdbGenres: g.enrichment.tmdbGenres || [],
      imdbRating: g.enrichment.imdbRating ?? null,
    };
  }
  return item;
}

let passed = 0;
const failures = [];
for (const c of golden.cases) {
  const item = toItem(c.item);
  const pass = (id) => {
    const ch = channels.get(id);
    if (!ch) throw new Error(`channel id ${id} is not in channels.json`);
    return CF.itemPasses(item, ch, { manifest, exclusiveRules, backend: c.item.backend || "plex" }) !== false;
  };
  const problems = [];
  try {
    for (const id of c.in || []) if (!pass(id)) problems.push(`not on ${id} ${channels.get(id).name}`);
    for (const id of c.out || []) if (pass(id)) problems.push(`on ${id} ${channels.get(id).name}`);
  } catch (err) {
    problems.push(err.message);
  }
  if (problems.length) failures.push(`${c.name}: ${problems.join("; ")}`);
  else passed += 1;
}

if (failures.length) {
  console.error(`filter golden: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`filter golden: ${passed} cases passed`);
