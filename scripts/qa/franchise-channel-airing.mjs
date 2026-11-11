// Usage: TZ=America/New_York node --env-file=.env scripts/qa/franchise-channel-airing.mjs <from ISO> <to ISO>
// Replays the Apple TV's daily-manifest pack with the web engine (a parity-tested port) over the real
// Plex movie library. Prints which film airs on franchise channel 105 (CH 305) in a local-time window.
// Usage: TZ=America/New_York node --env-file=<repo>/.env airing.mjs <from ISO> <to ISO> 
import { readFileSync, writeFileSync } from "node:fs";
import vm from "node:vm";
import { createRequire } from "node:module";
const R = decodeURIComponent(new URL("../../", import.meta.url).pathname.replace(/\/$/, ""));
const require = createRequire(R + "/");
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
const base = process.env.PLEX_URL.replace(/\/$/, ""), tok = process.env.PLEX_TOKEN;
const get = async (p) => { const r = await fetch(base + p + (p.includes("?") ? "&" : "?") + "X-Plex-Token=" + tok, { headers: { Accept: "application/json" } }); if (!r.ok) throw new Error(r.status + " " + p.replace(/Token=.*/,"")); return r.json(); };

const t0 = Date.now();
const raw = (await get("/library/sections/1/all?includeGuids=1")).MediaContainer.Metadata;
console.error(`movies fetched: ${raw.length} in ${Date.now() - t0} ms`);


const CF = require(R + "/scripts/nostalgex-channel-filter.cjs");
const manifest = JSON.parse(readFileSync(R + "/channels-memberships.json", "utf8"));
const chans = JSON.parse(readFileSync(R + "/Nostalgex/Nostalgex/channels.json", "utf8"));
const parseTmdb = (r) => { for (const g of r.Guid || []) { const m = String(g.id).match(/tmdb:\/\/(\d+)/); if (m) return m[1]; } return null; };
const items = raw.map((r) => ({
  ratingKey: String(r.ratingKey), title: r.title, episodeTitle: null, displayTitle: r.title, type: "movie", librarySource: "movie",
  year: r.year || null, duration: r.duration ? Math.trunc(r.duration / 60000) : 0, viewCount: r.viewCount || 0,
  contentRating: (r.contentRating || "").trim() || null, addedAt: r.addedAt || 0,
  genres: (r.Genre || []).map((g) => g.tag.toLowerCase()), studio: (r.studio || "").trim() || null, summary: r.summary || "", tmdbID: parseTmdb(r),
}));
const nowSec = Math.floor(Date.now() / 1000);
const poolOf = (c) => CF.filterPool(items, c, { manifest, nowSec, exclusiveRules: chans.exclusiveRules || [] }).items;
const src = readFileSync(R + "/scripts/nostalgex-daily-manifest.js", "utf8");
function engine() {
  const store = new Map();
  const localStorage = { getItem: (k) => store.has(k) ? store.get(k) : null, setItem: (k, v) => { store.set(k, String(v)); }, removeItem: (k) => { store.delete(k); }, key: (i) => [...store.keys()][i] ?? null, get length() { return store.size; } };
  const ctx = { Date, TextEncoder, localStorage }; ctx.globalThis = ctx; vm.createContext(ctx); vm.runInContext(src, ctx); return ctx.NostalgexDailyManifest;
}
const mi = chans.channels.find((c) => c.id === 105);
const miPool = poolOf(mi);
console.log("CH", mi.number, mi.name, "pool:", miPool.length, miPool.map((i) => `${i.ratingKey}:${i.title}(${i.duration}m)`).join(" | "));
const fromMs = Date.parse(process.argv[2]), toMs = Date.parse(process.argv[3]);
const fmt = (s) => new Date(s * 1000).toLocaleString("en-US", { timeZone: "America/New_York", hour12: false, month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
const lineups = {
  "A alone": () => [],
  "B 7 franchise channels": () => chans.channels.filter((c) => c.category === "franchise"),
  "C all channels (movie pools only)": () => chans.channels,
};
for (const [name, pick] of Object.entries(lineups)) {
  for (const prime of [true, false]) {
    const M = engine();
    const lineup = pick().map((c) => ({ channel: { id: c.id, number: c.number ?? c.id, isPremiereChannel: Boolean(c.premiere), timeRestrictions: c.timeRestrictions || null }, pool: poolOf(c) })).filter((e) => e.pool.length);
    M.setLineup(lineup.length ? lineup : null);
    const ch = { id: 105, number: 305, isPremiereChannel: false, timeRestrictions: null };
    const days = [];
    for (let d = -2; d <= 0; d++) { if (!prime && d < 0) continue; days.push(fromMs + d * 86400000); }
    let out = [];
    const tStart = process.hrtime.bigint();
    for (const day of days) {
      const t1 = process.hrtime.bigint();
      for (const e of lineup) M.getManifestBlocks(e.channel, e.pool, day, "fp");
      const blocks = M.getManifestBlocks(ch, miPool, day, "fp");
      if (day === days.at(-1)) out = blocks;
      console.error(`  [${name}${prime ? "" : " no-yesterday"}] pack day ${new Date(day).toISOString().slice(0,10)} lineup=${lineup.length} ch: ${(Number(process.hrtime.bigint() - t1) / 1e6).toFixed(0)} ms`);
    }
    const endDay = new Date(fromMs).toLocaleDateString("en-CA", { timeZone: "America/New_York" });
    console.log(`\n== ${name}${prime ? "" : " (no stored yesterday)"}: CH305 blocks on ${endDay}: ${out.length}`);
    for (const b of out) { const hit = b.startSec * 1000 < toMs && b.endSec * 1000 > fromMs; console.log(`${hit ? ">>" : "  "} ${fmt(b.startSec)} - ${fmt(b.endSec)}  ${b.item.ratingKey} ${b.item.title}`); }
  }
}
