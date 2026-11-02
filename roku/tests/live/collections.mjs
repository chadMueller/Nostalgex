#!/usr/bin/env node
// Live check of server collections, with no TV: does the port read a real
// Plex server's collections and turn them into the same list, folds and
// channels as upstream's own module?
//
//   node tests/live/collections.mjs
//
// Upstream is the Nostalgex repo this port lives in (roku/..):
// the web tuner's loader, lifted out of plex-tuner.html unchanged, loads the
// library; scripts/nostalgex-collections.js reads the collections through
// the loader's plexLibraryFetchForServer, and every response is recorded;
// then buildCandidates and materialize run with what refreshCollectionChannels
// gives them (stock channels with a full pool, the FRANCHISES package's
// among them as fold targets, the membership manifest). Every collection is
// switched on, so each one's channel is checked.
//
// The port then runs in the off-device interpreter (tests/live/LiveCollections.brs)
// over the same library and the recorded responses, replayed through
// NxCollectionsFetchPlex, and the two are diffed. GET requests only, over
// HTTPS; Plex credentials come from .env (tests/live/plex-link.mjs) and
// nothing prints a token. The recording is library data and goes to
// out/live-collections.json (git-ignored, mode 600). It proves the port's
// reading of the responses and its collection logic, not the TV's network
// path, which `scripts/deploy.sh` builds then exercise.
import { execFileSync } from "node:child_process";
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { readEnv, servers } from "./plex-env.mjs";
import { CF, exclusiveRulesOf, loadLibrary, loader, upstream } from "./plex-loader.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..", "..");
const require = createRequire(import.meta.url);

// ── Upstream's loader (plex-loader.mjs) ─────────────────────────────────────
await import(pathToFileURL(join(upstream, "scripts", "nostalgex-collections.js")).href);
const C = globalThis.NostalgexCollections;

// HTTPS connections only, as the TV asks.
const token = readEnv().PLEX_TOKEN;
const list = (await servers(token)).map((s) => ({ ...s, connections: s.connections.filter((c) => c.protocol === "https") }));
console.log(`Loading the library with upstream's loader from ${list.length} server(s)...`);
const items = await loadLibrary(list);
console.log(`  ${items.length} items, ${items.filter((i) => i.type === "episode" && i.showKey).length} episodes with a show key`);

// ── Upstream's collections, every response recorded ────────────────────────
const recorded = [];
let raw = [];
for (const s of list) {
  const serverKey = s.machineIdentifier || "plex";
  const docs = {};
  const getJSON = async (path) => {
    const doc = await loader.plexLibraryFetchForServer(path, s);
    docs[path] = doc;
    return doc;
  };
  try {
    raw = raw.concat(await C.fetchPlexCollections(serverKey, getJSON));
  } catch (err) {
    console.log(`  ${s.name}: section list failed (${err.message})`);
  }
  recorded.push({ serverKey, docs });
}
console.log(`  ${raw.length} server collections, ${raw.filter((c) => c.childKeys.length).length} with children`);

// refreshCollectionChannels' inputs: every stock channel built over the whole
// library, kept when it fills its minimum, the FRANCHISES package's among them.
const config = require(join(upstream, "channels.json"));
const manifest = require(join(upstream, "channels-memberships.json"));
const exclusiveRules = exclusiveRulesOf(config);
const nowSec = Math.floor(Date.now() / 1000);
const keyFor = (it) => it.serverID || "plex";
const itemKey = (it) => `${keyFor(it)}|${it.ratingKey}`;
const staticChannels = [];
for (const ch of config.channels) {
  const pool = CF.filterPool(items, ch, { manifest, exclusiveRules, nowSec }).items;
  if (pool.length >= (ch.minItems || 50)) staticChannels.push({ id: ch.id, number: ch.number, name: ch.name, itemPool: pool });
}
const franchiseIDs = new Set((config.bundles.find((b) => b.id === "franchises") || {}).channelIDs || []);
const franchiseChannels = staticChannels.filter((ch) => franchiseIDs.has(ch.id));
const enabledKeys = raw.map((c) => c.id);
const candidates = C.buildCandidates(raw, C.indexLibrary(items, keyFor), {
  staticChannels,
  channelsByID: new Map(config.channels.map((ch) => [ch.id, ch])),
  franchiseChannels, itemKey, enabledKeys: new Set(enabledKeys), manifest,
});
const { channels } = C.materialize(candidates);
console.log(`  upstream: ${candidates.length} candidates, ${candidates.filter((c) => c.foldedInto).length} folded, `
  + `${candidates.filter((c) => c.showCount).length} holding shows, ${channels.length} channels from CH 500`);

// ── The port, over the same data ────────────────────────────────────────────
const slim = (it) => ({ ratingKey: it.ratingKey, serverIndex: keyFor(it), type: it.type, title: it.title, showKey: it.showKey ?? null, tmdbID: it.tmdbID ?? null });
mkdirSync(join(repo, "out"), { recursive: true }); // absent in a fresh clone or worktree
writeFileSync(join(repo, "out", "live-collections.json"), JSON.stringify({
  servers: recorded, serverKeys: {}, items: items.map(slim), enabledKeys,
  staticChannels: staticChannels.map((ch) => ({ id: ch.id, number: ch.number, name: ch.name })),
  channels: config.channels.map((ch) => ({ id: ch.id, number: ch.number, name: ch.name })),
  franchiseChannels: franchiseChannels.map((ch) => ({ id: ch.id, number: ch.number, name: ch.name, pool: ch.itemPool.map(slim) })),
}), { mode: 0o600 });
const out = execFileSync("npx", ["-y", "-p", "@rokucommunity/brs@0.47.6", "brs", "--root", repo,
  join(here, "LiveCollections.brs"), ...["util", "franchise", "guide", "filter", "schedule", "collections"].flatMap((d) =>
    readdirSync(join(repo, "source", d)).filter((f) => f.endsWith(".brs")).map((f) => join(repo, "source", d, f)))],
{ cwd: repo, maxBuffer: 1 << 28 }).toString();
const port = out.split("\n").filter((l) => l.startsWith("LIVECOL "));
if (!port.includes("LIVECOL DONE")) { console.log(out.slice(-2000)); throw new Error("the port's run did not finish"); }

const want = [
  `LIVECOL RAW ${raw.length}`,
  ...raw.map((c) => `LIVECOL RAWROW ${c.id} ${c.childKeys.length}`),
  ...candidates.map((c) => `LIVECOL CAND ${c.id}\t${c.title}\t${C.memberSummary(c)}\t${C.duplicateWarning(c) ?? "-"}\t${c.foldedInto ?? "-"}\t${c.items.map(itemKey).join(",")}`),
  ...channels.map((ch) => `LIVECOL CHANNEL ${ch.number} ${ch.collectionID} ${ch.itemPool.length}`),
  "LIVECOL DONE",
];
let problems = 0;
const n = Math.max(want.length, port.length);
for (let i = 0; i < n; i++) {
  if (want[i] !== port[i]) {
    problems++;
    if (problems <= 20) console.log(`  line ${i + 1}:\n    upstream ${(want[i] || "(none)").slice(0, 300)}\n    port     ${(port[i] || "(none)").slice(0, 300)}`);
  }
}
if (problems) {
  console.log(`\nMISMATCH: ${problems} line(s) differ`);
  process.exit(1);
}
console.log(`\nMATCH: ${raw.length} collections read, ${candidates.length} listed or folded, ${channels.length} channels, line for line as upstream's module.`);
