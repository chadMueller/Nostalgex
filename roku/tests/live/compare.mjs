#!/usr/bin/env node
// Live parity check: does the TV build the same library, channel pools and
// schedules as upstream's own code, from the same Plex server?
//
//   scripts/deploy.sh --live          # TV: load the library, print fingerprints
//   node tests/live/compare.mjs [out/live-<tv>.log]
//
// The reference is upstream itself, the Nostalgex repo this port lives in: the web tuner's loader functions are
// lifted out of plex-tuner.html unchanged and run here against the server,
// then upstream's filter and schedule modules run over the result. Plex
// credentials come from .env (tests/live/plex-link.mjs); nothing here prints a
// token. The full reference lines go to out/live-reference.tsv (git-ignored)
// for inspecting a mismatch.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { readEnv, servers } from "./plex-env.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..", "..");
// Upstream is the Nostalgex repo this port lives in (roku/..), the same tree
// data/ links to.
const upstream = resolve(repo, "..");
const require = createRequire(import.meta.url);
const logPath = process.argv[2] || join(repo, "out", `live-${(readEnv().ROKU_HOSTS || "").split(" ")[0]}.log`);

// ── The TV's fingerprints ───────────────────────────────────────────────────
const tv = { items: new Map(), order: [], channels: new Map() };
for (const raw of readFileSync(logPath, "utf8").split("\n")) {
  const line = raw.replace(/\r$/, "").trim();
  let m;
  if ((m = line.match(/^LIVEITEM (\S+) (\w+)$/))) { tv.items.set(m[1], m[2]); tv.order.push(m[1]); }
  else if ((m = line.match(/^LIVE ITEMS\s+(\d+)\s+(\w+)$/))) tv.all = { count: Number(m[1]), sha: m[2] };
  else if ((m = line.match(/^LIVE CLOCK\s+(\d+)\s+(\d+)\s+(\d+)$/))) tv.clock = { nowSec: +m[1], dayStart: +m[2], dayNumber: +m[3] };
  else if ((m = line.match(/^LIVECH\s+(\d+)\s+(\d+)(?:\s+(\w+)\s+(\w+))?$/))) tv.channels.set(+m[1], { count: +m[2], pool: m[3], schedule: m[4] });
}
if (!tv.all || !tv.clock) throw new Error(`no complete live run in ${logPath}`);

// ── Upstream's loader, lifted out of plex-tuner.html ────────────────────────
const html = readFileSync(join(upstream, "plex-tuner.html"), "utf8");
function lift(name) {
  const at = html.search(new RegExp(`(?:async\\s+)?function\\s+${name}\\s*\\(`));
  if (at < 0) throw new Error(`plex-tuner.html has no function ${name}`);
  let i = html.indexOf("(", at), depth = 0;
  for (; ; i++) { if (html[i] === "(") depth++; else if (html[i] === ")" && --depth === 0) break; }
  i = html.indexOf("{", i);
  const start = i;
  for (depth = 0; ; i++) { if (html[i] === "{") depth++; else if (html[i] === "}" && --depth === 0) break; }
  return html.slice(at, i + 1) + "\n";
}
const pageSize = html.match(/const PLEX_PAGE_SIZE = (\d+);/)[1];
const loaderSource = [`const PLEX_PAGE_SIZE = ${pageSize};`,
  ...["plexLibraryFetchForServer", "fetchPlexSectionPaged", "scanOnePlexServer", "pickBestVersion", "resolutionHeight", "formatDuration"].map(lift),
  "globalThis.scanOnePlexServer = scanOnePlexServer;"].join("\n");

const CF = require(join(upstream, "scripts", "nostalgex-channel-filter.cjs"));
new Function(readFileSync(join(upstream, "scripts", "nostalgex-music-brainz.js"), "utf8"))();
new Function("module", readFileSync(join(upstream, "scripts", "nostalgex-daily-manifest.js"), "utf8"))(undefined);
const MD = globalThis.NostalgexDailyManifest;
const quiet = { ...console, log() {}, warn() {} };
const context = vm.createContext({
  fetch, console: quiet, AbortController, setTimeout, clearTimeout, URLSearchParams,
  discoveredGenres: {},
  channelFilter: () => CF,
  NostalgexMusicBrainz: globalThis.NostalgexMusicBrainz,
  // The loader's minute and date conversions (minutesFromPlexMs) live in the engine.
  NostalgexDailyManifest: MD,
});
context.globalThis = context;
vm.runInContext(loaderSource, context);
const LL = { state: {}, pulsePhase: async () => {}, setPhase: () => {} };

console.log("Loading the library with upstream's loader...");
const list = await servers(readEnv().PLEX_TOKEN);
let items = [];
for (const s of list) {
  const got = await context.scanOnePlexServer(s, LL, items.length, list.length > 1);
  items = items.concat(got);
}

// ── Same fingerprints as tests/live/LiveMain.brs ────────────────────────────
const FIELDS = ["ratingKey", "type", "title", "episodeTitle", "artist", "year", "contentRating", "duration", "genres",
  "rating", "userRating", "viewCount", "addedAt", "studio", "librarySource", "tmdbID", "partKey", "container", "summary", "thumb", "art"];
const value = (v) => (v == null ? "~" : String(v).replace(/\\/g, "\\\\").replace(/\t/g, "\\t").replace(/\n/g, "\\n").replace(/\r/g, "\\r"));
const lineOf = (it) => FIELDS.map((f) => (Array.isArray(it[f]) ? it[f].map(value).join("|") : value(it[f]))).join("\t");
const sha1 = (s) => createHash("sha1").update(s, "utf8").digest("hex");

const lines = items.map(lineOf);
writeFileSync(join(repo, "out", "live-reference.tsv"), lines.join("\n") + "\n", { mode: 0o600 });
const all = createHash("sha1");
for (const l of lines) all.update(l + "\n", "utf8");
const ref = { count: items.length, sha: all.digest("hex") };

let problems = 0;
const report = (msg) => { problems++; if (problems <= 40) console.log("  " + msg); };

console.log(`\nLibrary: upstream ${ref.count} items, TV ${tv.all.count}`);
if (ref.sha === tv.all.sha) console.log("  identical (every field of every item, in the same order)");
else {
  const refKeys = items.map((it) => String(it.ratingKey));
  if (refKeys.join(",") !== tv.order.join(",")) report("item ORDER differs");
  const tvSet = new Set(tv.order);
  for (const k of refKeys) if (!tvSet.has(k)) report(`only upstream has ${k}`);
  const refSet = new Set(refKeys);
  for (const k of tv.order) if (!refSet.has(k)) report(`only the TV has ${k}`);
  items.forEach((it, i) => {
    const want = sha1(lines[i]).slice(0, 12);
    const got = tv.items.get(String(it.ratingKey));
    if (got && got !== want) report(`item ${it.ratingKey} differs; upstream line ${i + 1} of out/live-reference.tsv`);
  });
}

// Channel pools and today's schedule, at the TV's own clock and day.
const config = require(join(upstream, "channels.json"));
const manifest = require(join(upstream, "channels-memberships.json"));
const exclusiveRules = (config.exclusiveRules || []).map((r) => ({
  channelIDs: r.channelIDs || (r.channelID != null ? [r.channelID] : []),
  genres: r.genres || [], titleContains: r.titleContains || [], editorialTitles: r.editorialTitles || [],
  manifestExclusive: !!r.manifestExclusive,
}));
// The rest of the web tuner's path from pool to airtime: the pool in library
// order, getTimeFilteredPool lifted from plex-tuner.html, getManifestBlocks from
// the module over a stand-in localStorage, cleared as a library load clears it.
const tuner = new Function(`${lift("getTimeFilteredPool")}\nreturn { getTimeFilteredPool };`)();
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k), key: (i) => [...store.keys()][i] ?? null, get length() { return store.size; },
};
const RealDate = globalThis.Date;
const fixed = tv.clock.nowSec * 1000;
globalThis.Date = class extends RealDate {
  constructor(...a) { if (a.length) super(...a); else super(fixed); }
  static now() { return fixed; }
};
let channelsSame = 0;
for (const ch of config.channels) {
  const pool = CF.filterPool(items, ch, { manifest, exclusiveRules, nowSec: tv.clock.nowSec }).items;
  const poolSha = sha1(pool.map((i) => `${i.ratingKey}:${i.poolVia}`).join(",")).slice(0, 12);
  const aired = MD.getManifestBlocks(ch, tuner.getTimeFilteredPool({ ...ch, itemPool: pool }), tv.clock.nowSec * 1000, "live");
  const schedSha = sha1(aired.map((b) => `${b.item.ratingKey}@${b.startSec}-${b.endSec}`).join(",")).slice(0, 12);
  const got = tv.channels.get(ch.id);
  if (!got) { report(`channel ${ch.id} missing from the TV's output`); continue; }
  // The TV's SHA-1 of an empty string is blank, so an empty channel has a count only.
  if (got.count === 0 && pool.length === 0) { channelsSame++; continue; }
  if (got.count !== pool.length || got.pool !== poolSha) report(`channel ${ch.id} ${ch.name}: pool differs (upstream ${pool.length}, TV ${got.count})`);
  else if (got.schedule !== schedSha) report(`channel ${ch.id} ${ch.name}: same pool, schedule differs`);
  else channelsSame++;
}
globalThis.Date = RealDate;
console.log(`Channels: ${channelsSame} of ${config.channels.length} identical in pool and in what airs today`);

if (problems) {
  console.log(`\nMISMATCH: ${problems} problem(s)${problems > 40 ? " (first 40 shown)" : ""}`);
  process.exit(1);
}
console.log("\nMATCH: the TV's library, pools and schedules are identical to upstream's.");
