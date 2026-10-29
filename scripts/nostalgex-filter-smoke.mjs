#!/usr/bin/env node
/**
 * Smoke test for scripts/nostalgex-channel-filter.cjs.
 *
 * Guards the rule-parity contract with Nostalgex tvOS
 * (Nostalgex/Nostalgex/App/AppState+Channels.swift → `filterItems`). Synthetic
 * items, plus one check against the shipped channels.json + manifest. No Plex
 * server, no network. Run: `npm run test:filter`.
 */
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const CF = require("./nostalgex-channel-filter.cjs");

let pass = 0;
const failures = [];
function check(name, actual, expected) {
  const ok = actual === expected;
  if (ok) pass++;
  else failures.push(`${name}: expected ${expected}, got ${actual}`);
}

const base = {
  title: "Test Movie",
  genres: ["Drama"],
  type: "movie",
  duration: 100,
  year: 2000,
  rating: 8,
  userRating: 0,
  viewCount: 0,
  addedAt: 0,
  contentRating: "PG-13",
  ratingKey: "1",
  librarySource: "movie",
};
const item = (o = {}) => ({ ...base, ...o });
const passes = (it, ch, opts) => CF.itemPasses(it, ch, opts) !== false;

// ── OMDb gates (CH141 FOREIGN FILMS, CH143 CULT CLASSICS) ──────────────────
const ch141 = { id: 212, rules: { genres: { include: ["Drama"] }, imdbRatingMin: 6.5, imdbVotesMin: 5000 } };
check("imdb: unenriched item is REJECTED (Swift guard-let semantics)", passes(item(), ch141), false);
check("imdb: rating + votes above floor passes", passes(item({ imdbRating: 7.1, imdbVotes: 9000 }), ch141), true);
check("imdb: rating exactly at floor passes (>=)", passes(item({ imdbRating: 6.5, imdbVotes: 5000 }), ch141), true);
check("imdb: rating below floor rejected", passes(item({ imdbRating: 6.4, imdbVotes: 9000 }), ch141), false);
check("imdb: votes below floor rejected", passes(item({ imdbRating: 8, imdbVotes: 4999 }), ch141), false);
check("imdb: only rating present, votes missing -> rejected", passes(item({ imdbRating: 8 }), ch141), false);
check("imdb: nested item.enrichment is read", passes(item({ enrichment: { imdbRating: 7, imdbVotes: 6000 } }), ch141), true);

const ch143 = { id: 214, rules: { genres: { include: ["Drama"] }, imdbVotesMin: 30000 } };
check("imdbVotesMin alone: unenriched rejected", passes(item(), ch143), false);
check("imdbVotesMin alone: 30000 passes", passes(item({ imdbVotes: 30000 }), ch143), true);

// ── ratingMin used to be dead code on any channel with a content rule ──────
const ch67 = { id: 67, rules: { genres: { include: ["Drama"] }, ratingMin: 8.2, durationRange: { min: 60 } } };
check("ratingMin enforced on a genre channel", passes(item({ rating: 8.0 }), ch67), false);
check("ratingMin satisfied by item.rating", passes(item({ rating: 8.3 }), ch67), true);
check("ratingMin satisfied by userRating", passes(item({ rating: 0, userRating: 9 }), ch67), true);
check("durationRange.min still enforced", passes(item({ rating: 9, duration: 40 }), ch67), false);

// ── releasedWithinMonths (CH49 FRESH) ─────────────────────────────────────
const thisYear = new Date().getFullYear();
const ch49 = { id: 49, rules: { genres: { include: ["Drama"] }, releasedWithinMonths: 6, durationRange: { min: 60 } } };
check("releasedWithinMonths: old year rejected", passes(item({ year: 1999 }), ch49), false);
check("releasedWithinMonths: current year passes (year fallback)", passes(item({ year: thisYear }), ch49), true);
check(
  "releasedWithinMonths: precise old date rejected",
  passes(item({ year: thisYear, originallyAvailableAt: `${thisYear - 3}-01-05` }), ch49),
  false,
);

// ── keywords are ADDITIVE and matched by EXACT equality ───────────────────
const kwCh = { id: 900, rules: { genres: { include: ["Comedy"] }, keywords: ["road trip"] } };
check("keyword broadens: keyword hit passes despite genre miss", passes(item({ genres: ["Drama"], tmdbKeywords: ["road trip"] }), kwCh), true);
check("keyword exact: 'road trip movie' does not match rule 'road trip'", passes(item({ genres: ["Drama"], tmdbKeywords: ["road trip movie"] }), kwCh), false);
check("keyword never gates: genre alone still passes", passes(item({ genres: ["Comedy"] }), kwCh), true);

const gateCh = { id: 901, rules: { genres: { include: ["Comedy"] }, keywords: ["wedding"], keywordsRequireAnyGenre: ["Romance"] } };
check("keywordsRequireAnyGenre: substring genre match counts", passes(item({ genres: ["Romantic Comedy"], tmdbKeywords: ["wedding"] }), gateCh), true);
check("keywordsRequireAnyGenre: unrelated genre blocks the keyword path", passes(item({ genres: ["Horror"], tmdbKeywords: ["wedding"] }), gateCh), false);

// keywordGatedGenres: broad genre needs a keyword too
const kgCh = { id: 902, rules: { genres: { include: ["Music", "Musical"] }, keywords: ["broadway"], keywordGatedGenres: ["Music"] } };
check("keywordGatedGenres: gated genre without keyword rejected", passes(item({ genres: ["Music"] }), kgCh), false);
check("keywordGatedGenres: gated genre with keyword passes", passes(item({ genres: ["Music"], tmdbKeywords: ["broadway"] }), kgCh), true);
check("keywordGatedGenres: exact-match only, 'Musical' not gated", passes(item({ genres: ["Musical"] }), kgCh), true);

// keywordsExclude is SOFT — unenriched items pass
const exCh = { id: 903, rules: { genres: { include: ["Drama"] }, keywordsExclude: ["anime"] } };
check("keywordsExclude: unenriched passes (soft)", passes(item(), exCh), true);
check("keywordsExclude: exact keyword blocks", passes(item({ tmdbKeywords: ["anime"] }), exCh), false);
check("keywordsExclude: exact match only", passes(item({ tmdbKeywords: ["animesque"] }), exCh), true);

// ── networks (was computed but never evaluated) ───────────────────────────
const netCh = { id: 120, rules: { networks: ["HBO"] } };
check("networks: enrichment network matches", passes(item({ networks: ["HBO Max"] }), netCh), true);
check("networks: no network data -> no match, channel has no other rule", passes(item(), netCh), false);

// ── rewatched === viewCount >= 3 ─────────────────────────────────────────
const rwCh = { id: 1, rules: { type: "movie", rewatched: true } };
check("rewatched: viewCount 2 rejected", passes(item({ viewCount: 2 }), rwCh), false);
check("rewatched: viewCount 3 passes", passes(item({ viewCount: 3 }), rwCh), true);

// ── year range uses originallyAvailableAt fallback ───────────────────────
const yrCh = { id: 92, rules: { genres: { include: ["Drama"] }, yearRange: { min: 1980, max: 1989 } } };
check("yearRange: in range", passes(item({ year: 1985 }), yrCh), true);
check("yearRange: out of range", passes(item({ year: 1995 }), yrCh), false);
check("yearRange: no year at all passes (sparse metadata)", passes(item({ year: null }), yrCh), true);
check(
  "yearRange: derived from originallyAvailableAt when year missing",
  passes(item({ year: null, originallyAvailableAt: "1995-06-01" }), yrCh),
  false,
);

// ── content ratings + allowUnrated ───────────────────────────────────────
const crCh = { id: 904, rules: { genres: { include: ["Drama"] }, contentRatings: ["PG", "PG-13"], allowUnrated: true } };
check("contentRatings: listed rating passes", passes(item({ contentRating: "PG" }), crCh), true);
check("contentRatings: unlisted rating rejected", passes(item({ contentRating: "R" }), crCh), false);
check("allowUnrated: empty rating passes", passes(item({ contentRating: "" }), crCh), true);

// ── genre locks ──────────────────────────────────────────────────────────
const plainCh = { id: 905, rules: { genres: { include: ["Drama"] } } };
check("genre lock: horror blocked from a non-horror channel", passes(item({ genres: ["Drama", "Horror"] }), plainCh), false);
check("genre lock: sport NOT globally blocked", passes(item({ genres: ["Drama", "Sport"] }), plainCh), true);
check("source: musicVideo excluded when channel sets no source", passes(item({ librarySource: "musicVideo" }), plainCh), false);

// ── manifest claim + manifestOnly + exclusivity ──────────────────────────
const manifest = { items: { "movie:555": { channels: [906], exclusive: null }, "movie:777": { channels: [907], exclusive: 907 } } };
const moCh = { id: 906, rules: { manifestOnly: true, genres: { include: ["Comedy"] } } };
check("manifestOnly: unclaimed item rejected even on genre match", passes(item({ genres: ["Comedy"] }), moCh, { manifest }), false);
check("manifest claim: claimed item passes without genre match", passes(item({ tmdbID: 555 }), moCh, { manifest }), true);

// manifestOnlyGenreFallback: a manifestOnly channel can opt in to a second,
// additive claim path (STAND-UP's real shape). The gate is per-channel, keyed
// off keywordGatedGenres, not automatic — the same bare genre that's rejected
// above still gets rejected here unless the channel's own rules let it through
// ungated or via a keyword.
const moFallbackCh = {
  id: 908,
  rules: {
    manifestOnly: true,
    manifestOnlyGenreFallback: true,
    genres: { include: ["Comedy", "Stand-Up"] },
    keywords: ["stand-up comedy"],
    keywordGatedGenres: ["Comedy"],
  },
};
check(
  "manifestOnlyGenreFallback off: unclaimed genre match still rejected (moCh has no opt-in)",
  passes(item({ genres: ["Stand-Up"] }), moCh, { manifest }),
  false,
);
check(
  "manifestOnlyGenreFallback on: narrow ungated genre tag reaches the channel unclaimed",
  passes(item({ genres: ["Stand-Up"] }), moFallbackCh, { manifest }),
  true,
);
check(
  "manifestOnlyGenreFallback on: the gated bare genre alone still fails without the keyword",
  passes(item({ genres: ["Comedy"] }), moFallbackCh, { manifest }),
  false,
);
check(
  "manifestOnlyGenreFallback on: the keyword unlocks the gated bare genre",
  passes(item({ genres: ["Comedy"], enrichment: { keywords: ["stand-up comedy"] } }), moFallbackCh, { manifest }),
  true,
);
check(
  "manifestOnlyGenreFallback on: an existing manifest claim still works too (additive, not a replacement)",
  passes(item({ tmdbID: 909, genres: ["Drama"] }), moFallbackCh, {
    manifest: { items: { "movie:909": { channels: [908], exclusive: null } } },
  }),
  true,
);
check("manifest exclusive: locked item blocked elsewhere", passes(item({ tmdbID: 777, genres: ["Drama"] }), plainCh, { manifest }), false);

// A manifest claim must not bypass the channel's own genres.exclude. The manifest
// is built from TMDB "similar" expansion, which put Aladdin (Animation, Family)
// on SCI-FI, a channel that explicitly excludes both.
const sciCh = { id: 911, rules: { genres: { include: ["Science Fiction"], exclude: ["Animation", "Family", "Kids"] } } };
const sciManifest = { items: { "movie:812": { channels: [911], exclusive: null }, "movie:813": { channels: [911], exclusive: null } } };
check("manifest claim: excluded genre still rejected (Aladdin off SCI-FI)",
  passes(item({ tmdbID: 812, title: "Aladdin", genres: ["Animation", "Family"] }), sciCh, { manifest: sciManifest }), false);
check("manifest claim: allowed item still passes on the same channel",
  passes(item({ tmdbID: 813, title: "Blade Runner", genres: ["Science Fiction"] }), sciCh, { manifest: sciManifest }), true);
check("manifest claim: exclude is case-insensitive",
  passes(item({ tmdbID: 812, title: "Aladdin", genres: ["ANIMATION"] }), sciCh, { manifest: sciManifest }), false);

// Shipped data, not synthetic: MARVEL's tmdbCollections once listed 295 (the
// Pirates of the Caribbean Collection), so all five Pirates films played on
// MARVEL via a manifest claim. Read the real files so a regenerated manifest
// cannot bring them back unnoticed.
{
  const fs = require("node:fs");
  const path = require("node:path");
  const root = path.join(path.dirname(require("node:url").fileURLToPath(import.meta.url)), "..");
  const realManifest = JSON.parse(fs.readFileSync(path.join(root, "channels-memberships.json"), "utf8"));
  const marvel = JSON.parse(fs.readFileSync(path.join(root, "channels.json"), "utf8")).channels.find((c) => c.id === 101);
  const disney = { genres: ["Adventure", "Fantasy", "Action"], studio: "Walt Disney Pictures" };
  for (const id of [22, 58, 285, 1865, 166426]) {
    check(`shipped manifest: Pirates movie:${id} not on MARVEL`, passes(item({ tmdbID: id, ...disney }), marvel, { manifest: realManifest }), false);
  }
  check("shipped manifest: Iron Man still on MARVEL", passes(item({ tmdbID: 1726, title: "Iron Man", genres: ["Action", "Science Fiction"], studio: "Paramount" }), marvel, { manifest: realManifest }), true);
}

const exclusiveRules = [{ channelIDs: [130], genres: ["Holiday"], titleContains: ["Christmas"], editorialTitles: ["Elf"] }];
check("exclusiveRules: holiday title blocked from other channels", passes(item({ title: "A Christmas Story" }), plainCh, { exclusiveRules }), false);
check("exclusiveRules: owner channel keeps it", passes(item({ title: "A Christmas Story", genres: ["Drama"] }), { id: 130, rules: { genres: { include: ["Drama"] } } }, { exclusiveRules }), true);

// ── title-curated channel (title list is the allowlist) ──────────────────
const tcCh = { id: 908, rules: { type: "episode", titleContains: ["Bluey"], genres: { include: ["Animation"] } } };
check("title-curated: listed show passes even with year suffix", passes(item({ title: "Bluey (2018)", type: "episode", genres: ["Comedy"] }), tcCh), true);
check("title-curated: unlisted show rejected", passes(item({ title: "Peppa Pig", type: "episode", genres: ["Animation"] }), tcCh), false);
check("titleExcludes: word-boundary, 'war' does not kill 'Warden'", passes(item({ title: "The Warden" }), { id: 909, rules: { genres: { include: ["Drama"] }, titleExcludes: ["war"] } }), true);

// ── artist-prefixed haystack (music videos), mirrors Swift filterTitleHaystack
const mvCh = { id: 910, rules: { source: "musicVideo", titleContains: ["Nirvana"] } };
check("music video: artist is part of the title haystack", passes(item({ title: "Smells Like Teen Spirit", artist: "Nirvana", librarySource: "musicVideo", genres: [] }), mvCh), true);

console.log(`${pass} passed, ${failures.length} failed`);
if (failures.length) {
  failures.forEach((f) => console.error("  FAIL " + f));
  process.exit(1);
}
