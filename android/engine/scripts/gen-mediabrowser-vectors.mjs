// The web tuner's Jellyfin and Emby scan (fetchJellyfinLibraryFromServer), run over the saved
// server answers the Roku port also tests against (roku/tests/fixtures/mediabrowser-server.json),
// written out for MediaBrowserScanTest. The Kotlin scan has to make the same items in the same
// order. Run by the engine's `genMediaBrowserVectors` task before its tests.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../..");
const out = process.argv[2];
if (!out) throw new Error("usage: gen-mediabrowser-vectors.mjs <out.json>");

// The daily manifest engine, which the scan converts ticks and dates with. Loading it sets
// globalThis.NostalgexDailyManifest; what require hands back is empty here.
const { createRequire } = await import("node:module");
createRequire(import.meta.url)(resolve(repoRoot, "scripts/nostalgex-daily-manifest.js"));
const { mediaBrowserVectors } = await import(resolve(repoRoot, "roku/tests/gen-mediabrowser.mjs"));
const vectors = await mediaBrowserVectors(repoRoot);
const fixture = JSON.parse((await import("node:fs")).readFileSync(resolve(repoRoot, "roku/tests/fixtures/mediabrowser-server.json"), "utf8"));
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify({ fixture, ...vectors }, null, 1));
console.log(`mediabrowser vectors: ${vectors.items.length} items, ${vectors.requests.length} requests`);
