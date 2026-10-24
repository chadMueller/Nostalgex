// Jellyfin/Emby library vectors: upstream's own fetchJellyfinLibraryFromServer,
// lifted out of plex-tuner.html and run over saved server answers with fetch
// stubbed, so the port's scan (source/mediabrowser/) turns the same answers
// into the same items in the same order.
//
// The answers in tests/fixtures/mediabrowser-server.json are trimmed from a
// Jellyfin 12.2 test server (the fields the scan reads, no file paths) plus
// made-up cases: paging past 200, a music-video library, several sources,
// missing fields, an episode list that fails, air dates, and Emby Dolby Vision
// subtypes (ExtendedVideoSubType). Called by tests/gen-vectors.mjs,
// which owns the output.
import { readFileSync } from "node:fs";
import { join } from "node:path";

// The text of `function name(` through its matching close brace.
function lift(source, signature) {
  const at = source.indexOf(signature);
  if (at < 0) throw new Error(`upstream plex-tuner.html changed shape: no ${signature}`);
  // The body opens after the parameter list, which can hold a `{}` default.
  let depth = 0;
  let close = at + signature.length - 1;
  for (; close < source.length; close++) {
    if (source[close] === "(") depth++;
    else if (source[close] === ")" && --depth === 0) break;
  }
  depth = 0;
  for (let i = source.indexOf("{", close); i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return source.slice(at, i + 1);
  }
  throw new Error(`unbalanced ${signature}`);
}

// Answers a stubbed fetch from the fixture: the views list, then /Items by
// ParentId and IncludeItemTypes, paged by StartIndex and Limit as the server
// pages them. A parent listed in `fail` answers 500.
export function serveFixture(fx, url) {
  const u = new URL(url, "http://server.invalid");
  if (u.pathname.endsWith("/UserViews") || /\/Users\/[^/]+\/Views$/.test(u.pathname)) {
    return { status: 200, body: { Items: fx.views, TotalRecordCount: fx.views.length } };
  }
  if (u.pathname.endsWith("/Items")) {
    const parent = u.searchParams.get("ParentId");
    if ((fx.fail || []).includes(parent)) return { status: 500, body: {} };
    const all = (fx.items[parent] || []).filter((it) => it.Type === u.searchParams.get("IncludeItemTypes"));
    const start = Number(u.searchParams.get("StartIndex") || 0);
    const limit = Number(u.searchParams.get("Limit") || all.length);
    return { status: 200, body: { Items: all.slice(start, start + limit), TotalRecordCount: all.length } };
  }
  return { status: 404, body: {} };
}

export async function mediaBrowserVectors(upstream) {
  const html = readFileSync(join(upstream, "plex-tuner.html"), "utf8");
  const fx = JSON.parse(readFileSync(new URL("./fixtures/mediabrowser-server.json", import.meta.url), "utf8"));
  new Function("globalThis", "window", readFileSync(join(upstream, "scripts", "nostalgex-music-brainz.js"), "utf8"))(globalThis, globalThis);
  // Its URL helpers, which the scan reads (embyDoviProfile since upstream ccb6854).
  new Function("module", readFileSync(join(upstream, "scripts", "nostalgex-jellyfin-urls.js"), "utf8"))(undefined);

  const requests = [];
  let result = null;
  const env = {
    fetch: async (url) => {
      requests.push(url.replace("http://server.invalid", ""));
      const r = serveFixture(fx, url);
      return { status: r.status, ok: r.status >= 200 && r.status < 300, json: async () => r.body };
    },
    NostalgexLibraryLoad: {
      show() {}, hide() {}, refreshStepRail() {}, async pulsePhase() {}, setPhase() {},
      isFirstLibraryLoad: () => false, state: {},
    },
    NostalgexMusicBrainz: globalThis.NostalgexMusicBrainz,
    // The web tuner's later steps (MusicBrainz lookups, channel building)
    // aren't the scan: keep what the scan made.
    finalizeLibraryWithMusicBrainz: async (items) => { result = items; return items; },
  };
  const body = [
    lift(html, "function pickBestVersion("),
    lift(html, "function formatDuration("),
    lift(html, "async function fetchJellyfinLibraryFromServer("),
    "return fetchJellyfinLibraryFromServer({ background: true });",
  ].join("\n");
  const run = new Function(
    "fetch", "globalThis", "plexServerUrl", "jellyfinUserId", "mediaBackend", "bundles", "enabledBundleIDs",
    "discoveredGenres", "jellyfinAuthHeader", "backendDisplayName", "adoptMediaBrowserKind",
    "finalizeLibraryWithMusicBrainz", "NostalgexJellyfinUrls", "CHANNELS", "switchChannel", "console",
    "NostalgexDailyManifest",
    body,
  );
  const quiet = { log() {}, warn() {} };
  const urls = globalThis.NostalgexJellyfinUrls;
  await run(
    env.fetch, { ...globalThis, ...env }, "http://server.invalid", fx.userId, "jellyfin", [], new Set(),
    {}, () => "", () => "Jellyfin", () => {}, env.finalizeLibraryWithMusicBrainz, urls, [], () => {}, quiet,
    globalThis.NostalgexDailyManifest,
  );
  // `meta` is display text, which the port's guide builds; `subtitles` the web
  // tuner's own subtitle menu, which the port fills from the stream.
  const items = result.map(({ meta, subtitles, ...rest }) => rest);
  return { userId: fx.userId, requests, items };
}
