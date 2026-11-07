#!/usr/bin/env node
/**
 * Where the library's titles land with every package on, by the web tuner's copy of the channel
 * filter (scripts/nostalgex-channel-filter.cjs). The Apple TV computes the same number for the
 * "N OF M ON CHANNELS" line under RESCAN LIBRARY; this runs the other engine over the same
 * items, so the two can be compared.
 *
 *   node scripts/qa/library-coverage.mjs <folder>
 *
 * <folder> holds items.json (the library, as LibraryCoverageHarness writes it) and, if there, the
 * Apple TV's swift-result.json to compare with. Cold enrichment: no TMDB data is fed in.
 *
 * Definition: a title is on a channel when it is in the pool of at least one of channels.json's
 * channels whose pool reaches its minItems, whether or not that channel's package is on.
 */
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

const require = createRequire(import.meta.url);
const CF = require("../nostalgex-channel-filter.cjs");
const root = new URL("../../", import.meta.url);
const read = (p) => JSON.parse(readFileSync(new URL(p, root), "utf8"));
const config = read("channels.json");
const manifest = read("channels-memberships.json");
const exclusiveRules = (config.exclusiveRules || []).map((r) => ({
  channelIDs: r.channelIDs || (r.channelID != null ? [r.channelID] : []),
  genres: r.genres || [], titleContains: r.titleContains || [], editorialTitles: r.editorialTitles || [],
  manifestExclusive: !!r.manifestExclusive, type: r.type || null, source: r.source || null,
}));

const dir = process.argv[2];
if (!dir) { console.error("usage: library-coverage.mjs <folder>"); process.exit(2); }
const raw = JSON.parse(readFileSync(join(dir, "items.json"), "utf8"));
const items = raw.map((r, i) => ({
  title: r.title, artist: r.artist ?? null, episodeTitle: r.episodeTitle ?? null, summary: r.summary ?? "",
  originallyAvailableAt: r.originallyAvailableAt ?? null, year: r.year ?? null, type: r.type || "movie",
  librarySource: r.librarySource || (r.type === "episode" ? "tv" : "movie"), genres: r.genres || [],
  contentRating: r.contentRating ?? null, duration: r.duration ?? 100, rating: r.rating ?? 0, userRating: r.userRating ?? 0,
  viewCount: r.viewCount ?? 0, addedAt: r.addedAt ?? 0, studio: r.studio ?? null, tmdbID: r.tmdbID ?? null,
  ratingKey: r.ratingKey ?? String(i), doviProfile: r.doviProfile ?? null, _id: r.id ?? String(i),
}));
const kind = (it) => (it.type === "episode" ? "episode" : it.librarySource === "musicVideo" ? "musicVideo" : "movie");

const covered = new Set();
const webPools = {};
let shown = 0;
const started = Date.now();
for (const channel of config.channels) {
  const pool = items.filter((it) => CF.itemPasses(it, channel, { manifest, exclusiveRules, backend: "plex" }) !== false);
  webPools[String(channel.id)] = pool.map((it) => it._id);
  if (pool.length < (channel.minItems ?? 1)) continue;
  shown += 1;
  for (const it of pool) covered.add(it._id);
}
const seconds = (Date.now() - started) / 1000;
const js = {};
for (const it of items) {
  const k = kind(it);
  js[k] ??= { loaded: 0, onChannels: 0, orphans: 0 };
  js[k].loaded += 1;
  if (covered.has(it._id)) js[k].onChannels += 1; else js[k].orphans += 1;
}
console.log(`web filter: ${items.length} titles, ${shown} of ${config.channels.length} channels reach their minItems, ${seconds.toFixed(1)}s`);
console.log(JSON.stringify(js));

const swiftFile = join(dir, "swift-result.json");
if (existsSync(swiftFile)) {
  const swift = JSON.parse(readFileSync(swiftFile, "utf8")).swift;
  let same = true;
  for (const k of new Set([...Object.keys(js), ...Object.keys(swift)])) {
    const a = js[k] ?? { loaded: 0, onChannels: 0, orphans: 0 }, b = swift[k] ?? { loaded: 0, onChannels: 0, orphans: 0 };
    const ok = a.loaded === b.loaded && a.onChannels === b.onChannels && a.orphans === b.orphans;
    if (!ok) same = false;
    console.log(`${k.padEnd(11)} web ${a.onChannels}/${a.loaded} (${a.orphans} on none)   apple tv ${b.onChannels}/${b.loaded} (${b.orphans} on none)   ${ok ? "same" : "DIFFERENT"}`);
  }
  // Where they differ: the channels whose pools are not the same set, with the titles that are in one
  // pool and not the other (only when swift-pools.json is there). One difference is known and on
  // purpose: a channel with a productionCompanies rule is matched by the web filter against the Plex
  // studio when the title has no enrichment record (scripts/nostalgex-channel-filter.cjs, "Plex studio
  // is the partial stand-in"; this script feeds none), and by the Apple TV against the enrichment only. With cold enrichment
  // that makes the web count a little higher; with TMDB records in the gap closes.
  const poolsFile = join(dir, "swift-pools.json");
  let unexplained = false;
  if (!same && existsSync(poolsFile)) {
    const swiftPools = JSON.parse(readFileSync(poolsFile, "utf8"));
    const byId = new Map(items.map((it) => [it._id, it]));
    const byChannel = new Map(config.channels.map((c) => [String(c.id), c]));
    for (const [id, web] of Object.entries(webPools)) {
      const swift = swiftPools[id];
      if (swift === undefined) continue;
      const w = new Set(web), sw = new Set(swift);
      const onlyWeb = web.filter((x) => !sw.has(x)), onlySwift = swift.filter((x) => !w.has(x));
      if (!onlyWeb.length && !onlySwift.length) continue;
      const c = byChannel.get(id);
      const known = (c?.rules?.productionCompanies || []).length > 0 && onlySwift.length === 0
        && onlyWeb.every((x) => { const it = byId.get(x); return it && it.studio; });
      if (!known) unexplained = true;
      console.log(`channel ${id} ${c?.name ?? ""} (minItems ${c?.minItems ?? 1}): web ${web.length}, apple tv ${swift.length}, ${known ? "the Plex-studio stand-in (expected)" : "UNEXPLAINED"}`);
      if (!known) {
        const show = (label, ids) => ids.slice(0, 6).forEach((x) => {
          const it = byId.get(x);
          console.log(`   ${label}: ${it?.title} (${it?.year ?? "no year"}, ${it?.contentRating ?? "unrated"}, ${(it?.genres || []).join("|") || "no genre"}, ${it?.studio ?? "no studio"})`);
        });
        show("only on the web filter", onlyWeb); show("only on the apple tv", onlySwift);
      }
    }
  }
  if (same) console.log("the two engines agree");
  else if (!existsSync(poolsFile)) console.log("the two engines DISAGREE (no swift-pools.json to say where)");
  else if (unexplained) console.log("the two engines DISAGREE, and not only through the Plex-studio stand-in");
  else console.log("the two engines agree, apart from the Plex-studio stand-in on productionCompanies channels (expected; the web count is the higher one on a cold library)");
  process.exit(same || (existsSync(poolsFile) && !unexplained) ? 0 : 1);
}
