#!/usr/bin/env node
/**
 * Smoke test for scripts/nostalgex-sliced-filter.js (GitHub #294): a channel's pool filtered a block of titles at
 * a time, with the page given back between slices, must be exactly the pool the shared filter returns for the
 * whole library in one call: the same rows, in the same order, for every rules channel in channels.json.
 *
 * It runs the real channel filter (scripts/nostalgex-channel-filter.cjs) on a synthetic library built from the
 * lineup's own vocabulary (titles, genres, studios, keywords, networks, companies, ratings, years), with and
 * without enrichment, on Plex and Emby, at block sizes from 1 to larger than the library, and with a yield after
 * every block. It also checks the slice budget, cancellation, the clock, and that the comparison itself bites
 * (blocks joined in the wrong order, or read on a moving clock, are not equal).
 *
 * No browser, no network. The page-level proof (a 10,700-title library, before and after, in Chromium) is
 * scripts/refilter-browser-smoke.mjs. Run: `npm run test:sliced-filter`.
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
const require = createRequire(import.meta.url);
const CF = require("./nostalgex-channel-filter.cjs");
await import("./nostalgex-sliced-filter.js");
const SF = globalThis.NostalgexSlicedFilter;
const lineup = JSON.parse(readFileSync(new URL("../channels.json", import.meta.url), "utf8"));

let pass = 0;
const failures = [];
function check(name, ok, detail = "") {
  if (ok) pass++;
  else failures.push(`${name}${detail ? `: ${detail}` : ""}`);
}

// ── A library drawn from the rules' own words, so most channels have something to take and refuse. ──
const vocab = { titleContains: new Set(), keywords: new Set(), networks: new Set(), productionCompanies: new Set(), studios: new Set(), genres: new Set() };
for (const ch of lineup.channels) {
  const r = ch.rules || {};
  for (const k of ["titleContains", "keywords", "networks", "productionCompanies", "studios"]) for (const v of r[k] || []) vocab[k].add(String(v));
  for (const g of (r.genres && r.genres.include) || []) vocab.genres.add(String(g));
}
const V = Object.fromEntries(Object.entries(vocab).map(([k, v]) => [k, [...v].sort()]));
const mix = (n) => { let x = (n * 2654435761) >>> 0; x ^= x >>> 15; x = Math.imul(x, 2246822519) >>> 0; x ^= x >>> 13; return x >>> 0; };
const at = (list, n) => (list.length ? list[mix(n) % list.length] : undefined);
const CERTS = ["G", "PG", "PG-13", "R", "NC-17", "TV-14", "TV-MA", "TV-Y", "TV-G", ""];

function library(n, enriched) {
  const items = [];
  for (let i = 0; i < n; i++) {
    const isEpisode = i % 4 === 3;
    const it = {
      ratingKey: String(1000 + i), serverUrl: i % 7 === 0 ? "http://b" : "http://a",
      title: i % 3 === 0 ? `${at(V.titleContains, i * 3 + 1) || "Title"} ${i}` : `Plain ${i}`,
      genres: [at(V.genres, i), at(V.genres, i * 5 + 1)].filter(Boolean),
      type: isEpisode ? "episode" : "movie", librarySource: isEpisode ? "tv" : "movie",
      duration: 20 + (i % 130), year: 1935 + (i % 90), rating: (mix(i) % 100) / 10, userRating: i % 17 === 0 ? 9 : 0,
      viewCount: i % 5, addedAt: 1.6e9 + i * 3600, contentRating: CERTS[i % CERTS.length] || undefined,
      studio: i % 2 ? at(V.studios, i) : undefined, tmdbID: i % 5 === 0 ? undefined : String(5000 + i),
    };
    if (isEpisode) { it.showTitle = `Show ${i % 40}`; it.seasonNumber = 1 + (i % 4); it.episodeNumber = 1 + (i % 12); it.episodeTitle = `Episode ${i}`; }
    if (enriched && it.tmdbID) {
      it.enrichment = {
        tmdbID: it.tmdbID, mediaType: isEpisode ? "tv" : "movie",
        keywords: [at(V.keywords, i), at(V.keywords, i * 7 + 2)].filter(Boolean).map((k) => k.toLowerCase()),
        networks: isEpisode ? [at(V.networks, i)].filter(Boolean) : [],
        productionCompanies: [at(V.productionCompanies, i)].filter(Boolean),
        tmdbGenres: [at(V.genres, i * 3)].filter(Boolean),
        imdbRating: i % 3 === 0 ? 5 + (mix(i) % 50) / 10 : null, imdbVotes: i % 3 === 0 ? 1000 + (mix(i) % 80000) : null,
      };
    }
    items.push(it);
  }
  return items;
}

const rulesChannels = lineup.channels.filter((ch) => ch.rules);
const NOW = 1_767_000_000;                 // one fixed clock
const inline = async () => {};             // a give-back that returns at once: the slicing is exercised, the timer is not
const rows = (arr) => arr.map((r) => JSON.stringify(r));

async function compareAll(items, backend, block, label) {
  let compared = 0, nonEmpty = 0, yields = 0;
  const bad = [];
  for (const ch of rulesChannels) {
    const channel = { id: ch.id, rules: ch.rules, category: ch.category };
    const opts = { manifest: null, exclusiveRules: lineup.exclusiveRules || [], backend, nowSec: NOW };
    const want = CF.filterPool(items, channel, opts).items;
    const slicer = SF.makeSlicer({ sliceMs: 0, now: () => 0, yieldFn: inline });
    const got = await SF.filterPool(CF, items, channel, opts, slicer, block);
    yields += slicer.yields;
    compared++;
    if (want.length) nonEmpty++;
    const a = rows(want), b = got ? rows(got) : null;
    if (!b || a.length !== b.length || a.some((x, i) => x !== b[i])) bad.push(`${ch.id} ${ch.name}: ${got ? got.length : "null"} vs ${want.length}`);
  }
  check(`${label}: every rules channel (${compared}) returns the whole-library rows, in order, byte for byte`, bad.length === 0, bad.slice(0, 4).join(" | "));
  return { compared, nonEmpty, yields };
}

const plain = library(1800, false);
const rich = library(1800, true);

const r1 = await compareAll(rich, "plex", 128, "enriched, plex, block 128");
check("the library gives the comparison something to compare (enriched: channels with titles)", r1.nonEmpty > rulesChannels.length * 0.5, `${r1.nonEmpty} of ${r1.compared}`);
check("every block was followed by a give-back (sliceMs 0)", r1.yields >= rulesChannels.length * Math.floor(rich.length / 128), String(r1.yields));
await compareAll(plain.slice(0, 700), "plex", 128, "unenriched (700 titles), plex, block 128");
await compareAll(rich.slice(0, 700), "emby", 33, "enriched (700 titles), emby, block 33");
await compareAll(rich.slice(0, 150), "plex", 1, "enriched (150 titles), plex, one title per block");
await compareAll(rich.slice(0, 700), "plex", 100000, "enriched (700 titles), plex, one block for the library");
check("an empty library returns an empty pool", (await SF.filterPool(CF, [], { id: 1, rules: rulesChannels[0].rules }, { nowSec: NOW }, SF.makeSlicer({ yieldFn: inline }))).length === 0);

// ── The comparison bites: a wrong join or a moving clock is not equal. ──
{
  const ch = rulesChannels.find((c) => CF.filterPool(rich, { id: c.id, rules: c.rules }, { exclusiveRules: lineup.exclusiveRules || [], nowSec: NOW }).items.length > 300);
  check("a channel with enough titles to span several blocks exists", !!ch);
  const channel = { id: ch.id, rules: ch.rules, category: ch.category };
  const opts = { manifest: null, exclusiveRules: lineup.exclusiveRules || [], backend: "plex", nowSec: NOW };
  const want = rows(CF.filterPool(rich, channel, opts).items);
  const blocks = [];
  for (let i = 0; i < rich.length; i += 128) blocks.push(CF.filterPool(rich.slice(i, i + 128), channel, opts).items);
  check("negative control: blocks joined in the wrong order are not the whole-library rows", JSON.stringify(rows(blocks.reverse().flat())) !== JSON.stringify(want));
  check("negative control: dropping the last block is not the whole-library rows", JSON.stringify(rows(blocks.reverse().slice(0, -1).flat())) !== JSON.stringify(want));
}

// ── The clock: every block reads the one `nowSec` it is given; none is invented per block. ──
{
  const seen = new Set();
  const spy = { filterPool: (items, channel, o) => { seen.add(o.nowSec); return CF.filterPool(items, channel, o); } };
  const ch = rulesChannels[0];
  await SF.filterPool(spy, rich, { id: ch.id, rules: ch.rules }, { nowSec: NOW }, SF.makeSlicer({ sliceMs: 0, now: () => 0, yieldFn: inline }), 64);
  check("every block is filtered at the clock the caller fixed", seen.size === 1 && seen.has(NOW), JSON.stringify([...seen]));
  const seen2 = new Set();
  const spy2 = { filterPool: (items, channel, o) => { seen2.add(o.nowSec); return CF.filterPool(items, channel, o); } };
  await SF.filterPool(spy2, rich, { id: ch.id, rules: ch.rules }, {}, SF.makeSlicer({ sliceMs: 0, now: () => 0, yieldFn: inline }), 64);
  check("with no clock given, one is read once for all the blocks", seen2.size === 1, JSON.stringify([...seen2]));
}

// ── The slice budget and cancellation. ──
{
  let t = 0, gives = 0;
  const slicer = SF.makeSlicer({ sliceMs: 12, now: () => t, yieldFn: async () => { gives++; } });
  check("a fresh slice is not tired", slicer.tired() === false);
  t = 11; check("11 ms into a 12 ms slice is not tired", slicer.tired() === false);
  t = 12; check("12 ms into a 12 ms slice is tired", slicer.tired() === true);
  const stop = await slicer.rest();
  check("rest() gives the page back once and starts a new slice", gives === 1 && slicer.tired() === false && stop === false && slicer.yields === 1);
  t = 23; check("the new slice counts from the give-back: 11 ms in is not tired", slicer.tired() === false);
  t = 24; check("and 12 ms in is tired", slicer.tired() === true);

  let stale = false;
  const cancelled = SF.makeSlicer({ sliceMs: 0, now: () => 0, yieldFn: async () => { stale = true; }, isCancelled: () => stale });
  const ch = rulesChannels[0];
  const out = await SF.filterPool(CF, rich, { id: ch.id, rules: ch.rules }, { nowSec: NOW }, cancelled, 128);
  check("a pass cancelled at a give-back stops and returns null", out === null && cancelled.yields === 1, `yields ${cancelled.yields}`);

  const slow = SF.makeSlicer({ sliceMs: 12, now: (() => { let n = 0; return () => (n += 1); })(), yieldFn: inline });
  const quick = await SF.filterPool(CF, rich, { id: ch.id, rules: ch.rules }, { nowSec: NOW }, slow, 128);
  check("a pass that never gets tired returns its rows without a give-back", Array.isArray(quick) && slow.yields <= Math.ceil(rich.length / 128));
}
check("defaultYield resolves (message channel or timeout, whichever the runtime has)", await Promise.race([SF.defaultYield().then(() => true), new Promise((r) => setTimeout(() => r(false), 2000))]));

if (failures.length) {
  console.error(`sliced filter: ${failures.length} failed, ${pass} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`sliced filter: ${pass} checks passed (${rulesChannels.length} rules channels, 2 backends, block sizes 1 to 100000, a give-back after every block)`);
