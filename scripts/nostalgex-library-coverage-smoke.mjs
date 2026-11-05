#!/usr/bin/env node
/**
 * The library coverage line (Settings) and the COVERAGE console line, as the Apple TV's
 * LibraryDiagnostics.coverage / coverageLine / orphanReport (appletv/library-coverage-counts).
 *
 *   - the wording: upper case, " · " between parts, thousands separators, a part left out at zero,
 *     the split by kind only when more than one kind has titles on no channel;
 *   - the numbers: the same as a plain loop over the real channels.json with the real filter (the
 *     definition in scripts/qa/library-coverage.mjs on the Apple TV branch), on a synthetic library;
 *   - the count runs in slices, gives the page back between them, and stops when it is cancelled;
 *   - a channel whose pool falls short of its minItems does not cover a title, a built collection or
 *     franchise channel does, and the package switches do not move the number;
 *   - the console line carries the fields the rules read.
 *
 * No browser, no network. Run: `npm run test:library-coverage`.
 */
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import "./nostalgex-library-coverage.js";

const require = createRequire(import.meta.url);
const CF = require("./nostalgex-channel-filter.cjs");
const LC = globalThis.NostalgexLibraryCoverage;
const root = fileURLToPath(new URL("../", import.meta.url));
const config = JSON.parse(readFileSync(join(root, "channels.json"), "utf8"));
const manifest = JSON.parse(readFileSync(join(root, "channels-memberships.json"), "utf8"));
const exclusiveRules = (config.exclusiveRules || []).map((r) => ({
  channelIDs: r.channelIDs || (r.channelID != null ? [r.channelID] : []),
  genres: r.genres || [], titleContains: r.titleContains || [], editorialTitles: r.editorialTitles || [],
  manifestExclusive: !!r.manifestExclusive, type: r.type || null, source: r.source || null,
}));
const opts = { manifest, exclusiveRules, backend: "plex", nowSec: 1730000000 };
const passes = (item, channel) => CF.itemPasses(item, channel, opts) !== false;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const same = (label, a, b) => check(label, JSON.stringify(a) === JSON.stringify(b), `${JSON.stringify(a)} vs ${JSON.stringify(b)}`);

// ── The wording ──
const cov = (loaded, onChannels) => {
  const sum = (m) => Object.values(m).reduce((a, b) => a + b, 0);
  return { loaded, onChannels, totalLoaded: sum(loaded), totalOnChannels: sum(onChannels), totalOnNoChannel: sum(loaded) - sum(onChannels), orphanSample: [] };
};
same("line: counts, the split by kind, and skipped",
  LC.formatLine(cov({ movie: 1792, episode: 10017 }, { movie: 1788, episode: 9845 }), 12),
  "11,633 OF 11,809 ON CHANNELS · 176 ON NO CHANNEL (4 MOVIES, 172 EPISODES) · 12 SKIPPED (NO RUNTIME)");
same("line: one kind on no channel gets no split", LC.formatLine(cov({ movie: 1792 }, { movie: 1788 }), 0), "1,788 OF 1,792 ON CHANNELS · 4 ON NO CHANNEL");
same("line: nothing on no channel, nothing skipped", LC.formatLine(cov({ movie: 40 }, { movie: 40 }), 0), "40 OF 40 ON CHANNELS");
same("line: three kinds", LC.formatLine(cov({ movie: 10, episode: 10, musicVideo: 10 }, { movie: 9, episode: 9, musicVideo: 9 }), 0),
  "27 OF 30 ON CHANNELS · 3 ON NO CHANNEL (1 MOVIES, 1 EPISODES, 1 MUSIC VIDEOS)");
same("line: only skipped titles", LC.formatLine(null, 3), "3 SKIPPED (NO RUNTIME)");
same("line: nothing to say", LC.formatLine(null, 0), null);
same("line: an empty library is not a count", LC.formatLine(cov({}, {}), 0), null);

// ── A synthetic library ──
const GENRES = ["Action", "Comedy", "Drama", "Thriller", "Horror", "Romance", "Science Fiction", "Adventure", "Animation", "Family", "Crime", "Mystery", "War", "Western", "Documentary", "Music", "Fantasy", ""];
const CERTS = ["G", "PG", "PG-13", "R", "NC-17", "", "TV-14", "TV-MA", "TV-Y"];
const STUDIOS = ["Universal Pictures", "Warner Bros.", "Paramount Pictures", "20th Century Fox", "", "Miramax"];
const N = 3000;
const items = Array.from({ length: N }, (_, i) => {
  const episode = i % 3 === 0;
  const clip = i % 50 === 7;
  return {
    title: `Title ${(i * 7919) % 5000}`, episodeTitle: episode ? `Episode ${i}` : "", year: i % 11 === 0 ? "" : 1950 + (i % 75), contentRating: CERTS[i % CERTS.length],
    duration: 20 + (i % 120), ratingKey: String(1000 + i), serverUrl: "http://server.invalid",
    genres: i % 13 === 0 ? [] : [GENRES[i % GENRES.length], GENRES[(i * 5 + 1) % GENRES.length]].filter(Boolean),
    rating: i % 4 === 0 ? 0 : 4 + (i % 50) / 10, userRating: 0, type: episode ? "episode" : "movie", viewCount: i % 4, addedAt: 1600000000 + i,
    studio: STUDIOS[i % STUDIOS.length], librarySource: clip ? "musicVideo" : episode ? "tv" : "movie", tmdbID: i % 5 === 0 ? null : String(5000 + i),
  };
});
const channels = config.channels.filter((c) => c.rules).map((c) => ({ id: c.id, rules: c.rules, category: c.category, minItems: c.minItems }));

// The oracle: one plain loop, no slices (scripts/qa/library-coverage.mjs).
function oracle() {
  const covered = new Set();
  let reaching = 0;
  for (const channel of channels) {
    const pool = items.filter((it) => passes(it, channel));
    if (pool.length < (channel.minItems || 50)) continue;
    reaching += 1;
    for (const it of pool) covered.add(it.ratingKey);
  }
  const loaded = {}, onChannels = {}, orphans = [];
  for (const it of items) {
    const k = LC.kindOf(it);
    loaded[k] = (loaded[k] || 0) + 1;
    if (covered.has(it.ratingKey)) onChannels[k] = (onChannels[k] || 0) + 1; else orphans.push(it);
  }
  return { loaded, onChannels, orphans, reaching };
}
const want = oracle();

const full = await LC.compute({ items, channels, passes });
same("numbers: loaded per kind match the plain loop", full.loaded, want.loaded);
same("numbers: on channels per kind match the plain loop", full.onChannels, want.onChannels);
same("numbers: total on no channel", full.totalOnNoChannel, want.orphans.length);
check("numbers: the library is not all on channels and not all orphans (the test means something)", full.totalOnChannels > 0 && full.totalOnNoChannel > 0 && want.reaching > 5, `${full.totalOnChannels} on, ${full.totalOnNoChannel} off, ${want.reaching} channels`);
const sorted = want.orphans.map((o) => o.title).sort((a, b) => a.localeCompare(b, "en", { sensitivity: "base" })).slice(0, 25);
same("numbers: the sample is the first 25 on no channel, by title", full.orphanSample.map((o) => o.title), sorted);

// ── Slices ──
{
  let yields = 0;
  const clock = { t: 0 };
  const r = await LC.compute({ items, channels, passes, sliceMs: 5, now: () => (clock.t += 1), yieldFn: async () => { yields += 1; } });
  same("slices: the same numbers when it rests all the time", [r.loaded, r.onChannels], [want.loaded, want.onChannels]);
  check("slices: it gives the page back often, not once at the end", yields > N / 400, `${yields} rests for ${N} titles and ${channels.length} channels`);
}
{
  let calls = 0;
  let rests = 0;
  const r = await LC.compute({ items, channels, passes: (...a) => { calls += 1; return passes(...a); }, sliceMs: 0, yieldFn: async () => { rests += 1; }, isCancelled: () => rests >= 3 });
  check("cancel: a newer library stops the count and returns nothing", r === null, JSON.stringify(r));
  check("cancel: it stops early, not after the whole library", calls < N * channels.length / 10, `${calls} tests of ${N * channels.length}`);
}

// ── What covers a title ──
{
  const few = [items[1], items[2]];
  const take = () => true;
  const small = await LC.compute({ items: few, channels: [{ id: 1, rules: {}, minItems: 5 }], passes: take });
  check("a channel short of its minItems covers nothing", small.totalOnChannels === 0 && small.totalOnNoChannel === 2, JSON.stringify(small));
  const enough = await LC.compute({ items: few, channels: [{ id: 1, rules: {}, minItems: 2 }], passes: take });
  check("a channel at its minItems covers its titles", enough.totalOnChannels === 2, JSON.stringify(enough));
  const built = await LC.compute({ items: few, channels: [], passes: take, dynamicPools: [[{ ...few[0] }]] });
  check("a built collection or franchise channel covers its titles (by server and key, not by object)", built.totalOnChannels === 1 && built.orphanSample[0].ratingKey === few[1].ratingKey, JSON.stringify(built));
  const off = channels.map((c) => ({ ...c, enabled: false, package: "off" }));
  const r = await LC.compute({ items, channels: off, passes });
  same("package switches do not move the number", [r.loaded, r.onChannels], [want.loaded, want.onChannels]);
  const none = await LC.compute({ items: [], channels, passes });
  check("an empty library counts nothing", none.totalLoaded === 0 && LC.formatLine(none, 0) === null);
}

// ── The console line ──
{
  const line = LC.orphanReport({ ...cov({ movie: 3, episode: 2 }, { movie: 2, episode: 2 }), orphanSample: [
    { title: "Lost Film", year: "", rating: 0, genres: [], studio: "", contentRating: "", duration: 88, tmdbID: null, type: "movie" },
    { title: "Odd Show", episodeTitle: "Pilot", year: 1999, rating: 7.25, genres: ["Drama", "Mystery"], studio: "Acme", contentRating: "TV-14", duration: 22, tmdbID: "12", type: "episode" },
  ] }, 4);
  check("console: counts, then the titles on no channel", line.startsWith("COVERAGE: 4 of 5 on a channel with every package on, 1 on none; 4 on the channels in the guide now (movie 2/3, episode 2/2, musicVideo 0/0). Not on any channel (first 2): "), line);
  check("console: a bare title says what is missing", line.includes('"Lost Film" (no year, unrated, no rating, no genre, no studio, 88m, no TMDB)'), line);
  check("console: a full title carries year, certificate, rating, genres, studio, runtime and TMDB", line.includes('"Odd Show: Pilot" (1999, TV-14, 7.3, Drama|Mystery, Acme, 22m, TMDB)') || line.includes('"Odd Show: Pilot" (1999, TV-14, 7.2, Drama|Mystery, Acme, 22m, TMDB)'), line);
  check("console: an unknown count of channels in the guide reads ?", LC.orphanReport(cov({ movie: 1 }, { movie: 1 }), null).includes("? on the channels in the guide now"));
}

if (failures.length) {
  console.error(`library coverage smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`library coverage smoke: ${passed} checks passed (${N} titles, ${channels.length} channels, ${want.reaching} reach their minimum, ${full.totalOnNoChannel} on none)`);
