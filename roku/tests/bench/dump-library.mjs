#!/usr/bin/env node
// Save the signed-in Plex library, as upstream's loader reads it, with its
// shared-cache enrichment rows, for tests/bench/run.sh:
//
//   node tests/bench/dump-library.mjs     # writes out/bench/library.json
//
// The loader is upstream's own, through tests/live/plex-loader.mjs, as the
// live tools run it (upstream is the Nostalgex repo this port lives in). The
// file holds one person's library, so it stays in out/ (git-ignored).
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readEnv, servers } from "../live/plex-env.mjs";
import { loadLibrary } from "../live/plex-loader.mjs";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const env = readEnv();
const items = await loadLibrary(await servers(env.PLEX_TOKEN));

// The shared cache's rows for the library's TMDB ids, as the TV reads them.
const rows = [];
const ids = [...new Set(items.map((it) => it.tmdbID).filter((v) => v != null))];
if (env.NOSTALGEX_SUPABASE_URL && env.NOSTALGEX_SUPABASE_ANON_KEY) {
  const h = { apikey: env.NOSTALGEX_SUPABASE_ANON_KEY, Authorization: `Bearer ${env.NOSTALGEX_SUPABASE_ANON_KEY}` };
  for (let i = 0; i < ids.length; i += 200) {
    const url = `${env.NOSTALGEX_SUPABASE_URL.replace(/\/$/, "")}/rest/v1/media_enrichments?tmdb_id=in.(${ids.slice(i, i + 200).join(",")})&select=*`;
    const res = await fetch(url, { headers: h });
    if (res.ok) rows.push(...(await res.json()));
  }
}

mkdirSync(join(repo, "out", "bench"), { recursive: true });
writeFileSync(join(repo, "out", "bench", "library.json"), JSON.stringify({ items, enrichmentRows: rows }), { mode: 0o600 });
console.log(`${items.length} items, ${rows.length} enrichment rows -> out/bench/library.json`);
