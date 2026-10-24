// Shared by the live tools: upstream's own library loader, lifted out of
// plex-tuner.html unchanged and run against a real Plex server, with the
// modules it calls. Upstream is the Nostalgex repo this port lives in
// (roku/..), the same tree data/ links to.
//
// The loader catches each section's error and warns, on a console silenced
// here, so a global it calls that isn't in the context below doesn't throw:
// every section comes back empty. loadLibrary refuses an empty library.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
export const upstream = resolve(here, "..", "..", "..");
const require = createRequire(import.meta.url);

const html = readFileSync(join(upstream, "plex-tuner.html"), "utf8");
export function lift(name) {
  const at = html.search(new RegExp(`(?:async\\s+)?function\\s+${name}\\s*\\(`));
  if (at < 0) throw new Error(`plex-tuner.html has no function ${name}`);
  let i = html.indexOf("(", at), depth = 0;
  for (; ; i++) { if (html[i] === "(") depth++; else if (html[i] === ")" && --depth === 0) break; }
  i = html.indexOf("{", i);
  for (depth = 0; ; i++) { if (html[i] === "{") depth++; else if (html[i] === "}" && --depth === 0) break; }
  return html.slice(at, i + 1) + "\n";
}

export const CF = require(join(upstream, "scripts", "nostalgex-channel-filter.cjs"));
new Function(readFileSync(join(upstream, "scripts", "nostalgex-music-brainz.js"), "utf8"))();
new Function("module", readFileSync(join(upstream, "scripts", "nostalgex-daily-manifest.js"), "utf8"))(undefined);
export const MD = globalThis.NostalgexDailyManifest;

const pageSize = html.match(/const PLEX_PAGE_SIZE = (\d+);/)[1];
const loaderSource = [`const PLEX_PAGE_SIZE = ${pageSize};`,
  ...["plexLibraryFetchForServer", "fetchPlexSectionPaged", "scanOnePlexServer", "pickBestVersion", "resolutionHeight", "formatDuration"].map(lift),
  "globalThis.scanOnePlexServer = scanOnePlexServer;", "globalThis.plexLibraryFetchForServer = plexLibraryFetchForServer;"].join("\n");
const quiet = { ...console, log() {}, warn() {} };
// Every global the lifted functions call. A new one in plex-tuner.html goes here.
export const loader = vm.createContext({
  fetch, console: quiet, AbortController, setTimeout, clearTimeout, URLSearchParams,
  discoveredGenres: {},
  channelFilter: () => CF,
  NostalgexMusicBrainz: globalThis.NostalgexMusicBrainz,
  NostalgexDailyManifest: MD,
});
loader.globalThis = loader;
vm.runInContext(loaderSource, loader);
const LL = { state: {}, pulsePhase: async () => {}, setPhase: () => {} };

// The whole library of every server in `list` (plex-env.mjs's servers()).
export async function loadLibrary(list) {
  let items = [];
  for (const s of list) items = items.concat(await loader.scanOnePlexServer(s, LL, items.length, list.length > 1));
  if (items.length === 0) {
    throw new Error("upstream's loader returned no items; check that every global it calls is in plex-loader.mjs's context");
  }
  return items;
}

// channels.json's exclusiveRules as filterPool takes them.
export const exclusiveRulesOf = (config) => (config.exclusiveRules || []).map((r) => ({
  channelIDs: r.channelIDs || (r.channelID != null ? [r.channelID] : []),
  genres: r.genres || [], titleContains: r.titleContains || [], editorialTitles: r.editorialTitles || [],
  manifestExclusive: !!r.manifestExclusive,
}));
