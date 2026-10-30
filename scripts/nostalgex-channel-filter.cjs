/**
 * Shared channel pool filter — same rules as Nostalgex tvOS
 * (Nostalgex/Nostalgex/App/AppState+Channels.swift → `filterItems`) and channels.json.
 * Used by plex-tuner.html (browser) and devtools (Node).
 * Canonical JS copy — edit this file only; keep AppState+Channels.swift in parity.
 *
 * ENRICHMENT DATA (important):
 * tvOS reads TMDB/OMDb enrichment off `MediaEnrichment` (keywords, networks,
 * productionCompanies, imdbRating, imdbVotes, rtScore, metacriticScore, awards, and
 * tmdbGenres for a channel with `matchTmdbGenres`).
 * On the web an item may carry the same values either flat on the item or under
 * `item.enrichment` — `enrichedValue()` reads both. The browser tuner attaches
 * `item.enrichment` from scripts/nostalgex-enrichment.js (shared Supabase cache,
 * then the TMDB relay). Until it lands, or for an item TMDB has no record of,
 * enrichment-gated rules behave exactly as they do on tvOS with a missing
 * enrichment record:
 *   - additive rules (keywords, networks, productionCompanies) simply don't match
 *   - keywordsExclude is SOFT — unenriched items pass
 *   - OMDb gates (imdbRatingMin/imdbVotesMin/rtScoreMin/metacriticMin/wonOscar)
 *     are HARD — unenriched items are REJECTED (mirrors AppState+Channels.swift
 *     "OMDb rating gates" block)
 * That last one means FOREIGN FILMS and CULT CLASSICS come back empty on any
 * host without OMDb data. The web relay does not proxy OMDb, so the web only has
 * OMDb values an Apple TV already wrote to the shared cache. That is the tvOS
 * behaviour; do not "fix" it by letting unrated items through.
 */

const HORROR = new Set(["horror"]);
const REALITY = new Set(["reality", "game show", "game-show", "reality-tv"]);
const ANIMATION = new Set(["animation", "animated", "cartoon"]);
// "history" is deliberately NOT here (or in WAR). Plex tags dramas like
// Apollo 13, Dallas Buyers Club and 12 Years a Slave as History, and no
// channel includes History, so locking it barred those films from every
// channel, including ones the manifest explicitly claimed them for.
// Mirrors AppState+Channels.swift.
const DOCUMENTARY = new Set(["documentary", "docuseries"]);
const SPORT = new Set(["sport", "sports", "sports film"]);
const MUSIC = new Set(["music", "music video", "musical"]);
const WAR = new Set(["war", "war & politics"]);
const WESTERN = new Set(["western"]);
const TALKSHOW = new Set(["talk show", "talk", "news"]);
const ADULT_RATINGS = new Set(["R", "NC-17", "TV-MA", "18", "18+", "X", "NR"]);

// Ratings from other countries. Every rating rule is written in US labels: the
// kids and family adult gate below, `contentRatings` allow-lists and VHS VAULT's
// 9 PM `blockRatings`. Jellyfin and Emby store a certificate from anywhere else
// with its country in front (TmdbUtils.BuildParentalRating: "GB-15", "GB-12A",
// and Germany as "FSK-16"), Plex as "gb/15", and some libraries carry the bare
// label ("12A") or "TV-12A". usContentRating() turns a label it recognises into
// the US label of the same age band, a film label for a film and a TV label for
// an episode (TWEEN TV lists only TV labels, FAMILY HOUR only film ones).
// Anything else comes back exactly as it went in, every US label included, so a
// US library builds the same pools as before. Where a label sits between two
// bands it takes the stricter one. The bands and labels follow Jellyfin's
// Localization/Ratings tables.
// Keep in sync with Nostalgex/Nostalgex/Models/ContentRating.swift and
// roku/source/filter/ChannelFilter.brs (NxUsContentRating); all three read
// scripts/rating-golden.json.
const RATING_BANDS = {
  all: ["G", "TV-G"],
  pg: ["PG", "TV-PG"],
  teen: ["PG-13", "TV-14"],
  mature: ["R", "TV-MA"],
  adult: ["NC-17", "TV-MA"],
};
// Compared upper-cased with spaces removed, so "pg-13" or "TV-14 " is left alone too.
const US_RATINGS = new Set(["G", "PG", "PG-13", "R", "NC-17", "NR", "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "TV-PG", "TV-14", "TV-MA"]);
// Word labels by country. Numbers ("15", "FSK-16", "12+") go by age in
// ratingAgeBand, for any country.
const RATING_WORDS = {
  GB: { U: "all", UC: "all", PG: "pg", "12A": "teen", "12PG": "teen", R18: "adult" },
  IE: { G: "all", PG: "pg", "12A": "teen", "12PG": "teen", "15A": "mature", "15PG": "mature" },
  AU: { P: "all", C: "all", G: "all", PG: "pg", M: "mature", "MA15+": "mature", "AV15+": "mature", "R18+": "mature", "X18+": "adult" },
  NZ: { G: "all", PG: "pg", R13: "teen", RP13: "teen", M: "mature", R15: "mature", R16: "mature", RP16: "mature", R18: "mature", RP18: "mature", R: "adult" },
  CA: { C: "all", G: "all", C8: "pg", PG: "pg", "14A": "teen", "18A": "mature", R: "adult", A: "adult" },
  FR: { U: "all", TP: "all" },
  NL: { AL: "all", MG6: "pg" },
};
// A label with no country, or after "TV-". Only labels with one meaning
// everywhere; "M" and "A" mean different things in different countries.
const RATING_BARE = {
  U: "all", UC: "all", "12A": "teen", "12PG": "teen", "14A": "teen", "15A": "mature", "18A": "mature",
  "MA15+": "mature", "R18+": "mature", R18: "adult", "X18+": "adult",
};

/** "0" is everyone, up to 10 is PG, up to 14 is PG-13 / TV-14, older is R / TV-MA. */
function ratingAgeBand(label) {
  const m = /^(\d{1,2})\+?$/.exec(label);
  if (!m) return null;
  const age = Number(m[1]);
  if (age === 0) return "all";
  if (age <= 10) return "pg";
  if (age <= 14) return "teen";
  return "mature";
}

/**
 * The US label the channel rules read for this rating. `type` is the item's type:
 * an episode gets a TV label, anything else a film label. Returns `raw` itself
 * (null, "", a US label, anything unrecognised) when there is nothing to map.
 */
function usContentRating(raw, type) {
  if (typeof raw !== "string") return raw;
  const key = raw.toUpperCase().replace(/\s+/g, "");
  if (key === "" || US_RATINGS.has(key)) return raw;
  let country = null;
  let label = key;
  if (key.startsWith("FSK")) {
    country = "DE";
    label = key.slice(3).replace(/^-/, "");
  } else {
    const m = /^([A-Z]{2})[-/](.+)$/.exec(key);
    if (m) {
      // "TV-12A" is a bare 12A, not a country called TV.
      if (m[1] !== "TV") country = m[1] === "UK" ? "GB" : m[1];
      label = m[2];
    }
  }
  let band = ratingAgeBand(label);
  if (!band) {
    if (country) band = RATING_WORDS[country]?.[label] ?? (label === "X" ? "adult" : null);
    else band = RATING_BARE[label] ?? null;
  }
  if (!band) return raw;
  return RATING_BANDS[band][type === "episode" ? 1 : 0];
}

function includeList(rules) {
  return rules?.genres?.include || [];
}

function channelIncludesGenre(rules, genreSet) {
  return includeList(rules).some((g) => genreSet.has(g.toLowerCase()));
}

function titleContainsWord(haystack, needle) {
  const n = needle.toLowerCase();
  if (!n) return false;
  const escaped = n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`\\b${escaped}\\b`).test(haystack);
}

function stripYearSuffix(s) {
  return s.toLowerCase().replace(/ \(\d{4}\)$/, "");
}

function parseYear(item) {
  const y = item.year;
  if (y == null || y === "") return null;
  const n = typeof y === "number" ? y : parseInt(String(y), 10);
  return Number.isFinite(n) ? n : null;
}

/** Mirrors Swift `itemReleaseYear`: Plex `year`, else the year of `originallyAvailableAt`. */
function releaseYear(item) {
  const y = parseYear(item);
  if (y != null) return y;
  const raw = item.originallyAvailableAt;
  if (typeof raw === "string") {
    const m = raw.match(/^(\d{4})-\d{2}-\d{2}/);
    if (m) return Number(m[1]);
  }
  return null;
}

function passesYearRange(item, rules) {
  if (!rules?.yearRange) return true;
  const year = releaseYear(item);
  if (year == null) return true;
  if (rules.yearRange.min != null && year < rules.yearRange.min) return false;
  if (rules.yearRange.max != null && year > rules.yearRange.max) return false;
  return true;
}

function manifestClaimsChannel(item, channelID, manifest) {
  if (!manifest?.items || !item.tmdbID) return false;
  const mediaType = item.type === "episode" ? "tv" : "movie";
  const entry = manifest.items[`${mediaType}:${item.tmdbID}`];
  return Boolean(entry?.channels?.includes(channelID));
}

/**
 * Mirrors Swift `ExclusiveRule.matches` (Models/Channel.swift). Keep them in step;
 * scripts/filter-golden.json is read by both.
 *
 * A lock looks at the item's own title: the film or show name, the song for a
 * music video, never the artist. Year suffix " (YYYY)" stripped, case ignored.
 *   - editorialTitles: the exact title (raw or stripped)
 *   - titleContains: whole words, the same boundary rule as a channel's
 *     `titleContains` (titleContainsWord). It used to be a raw substring test, so
 *     "Scream" locked Kicking & Screaming away from every channel it belongs on and
 *     "Santa" caught Santana. The web also matched the artist, Swift did not.
 *   - genres: substring of a genre tag, unchanged
 *
 * A lock can be scoped with `type` (movie|episode) and `source` (movie|tv|musicVideo).
 * When set, the lock only applies to items of that type and library source. The
 * holiday lock is `type: movie, source: movie`: it reads a film's title, so a show
 * whose name has a holiday word (Santa Clarita Diet) and a Christmas song on a music
 * video were locked to movie channels that can never air them, and aired nowhere.
 */
function exclusiveRuleApplies(item, rule) {
  if (rule.type && (item.type || "movie") !== rule.type) return false;
  if (rule.source && (item.librarySource || "movie") !== rule.source) return false;
  return true;
}

function exclusiveRuleMatches(item, itemGenres, rule) {
  if (!exclusiveRuleApplies(item, rule)) return false;
  const raw = String(item.title || "").toLowerCase();
  const title = stripYearSuffix(raw).trim();
  if ((rule.editorialTitles || []).some((t) => {
    const candidate = t.toLowerCase();
    return title === candidate || raw === candidate;
  })) return true;
  if ((rule.titleContains || []).some((t) => titleContainsWord(title, t))) return true;
  const g = rule.genres || [];
  if (g.length && itemGenres.some((ig) => g.some((rg) => ig.includes(rg.toLowerCase())))) return true;
  return false;
}

/** Plex GUIDs: `tmdb://456` or agent URLs containing `tmdb://456`. */
function parseTmdbIdFromPlex(raw, isEpisode = false) {
  const candidates = [];
  if (Array.isArray(raw.Guid)) candidates.push(...raw.Guid.map((g) => g.id));
  if (raw.guid) candidates.push(raw.guid);
  if (isEpisode && raw.grandparentGuid) candidates.push(raw.grandparentGuid);
  if (isEpisode && raw.parentGuid) candidates.push(raw.parentGuid);
  for (const id of candidates) {
    const m = String(id).match(/tmdb:\/\/(\d+)/);
    if (m) return Number(m[1]);
  }
  return null;
}

function channelRequiresAnimationGenre(rules) {
  return includeList(rules || {}).some((g) =>
    [...ANIMATION].some((a) => g.toLowerCase().includes(a)),
  );
}

function itemHasAnimationGenre(itemGenres) {
  return itemGenres.some(
    (g) => ANIMATION.has(g) || [...ANIMATION].some((a) => g.includes(a)),
  );
}

/**
 * Read an enrichment field that tvOS reads off `MediaEnrichment`. Accepts the
 * value flat on the item or nested under `item.enrichment` (devtools snapshots
 * use the flat shape). Returns null when absent — callers must then behave the
 * same way Swift does with a nil enrichment record.
 */
function enrichedValue(item, key) {
  const e = item.enrichment;
  if (e && e[key] != null) return e[key];
  if (item[key] != null) return item[key];
  return null;
}

function enrichedList(item, key) {
  const v = enrichedValue(item, key);
  return Array.isArray(v) ? v.map((x) => String(x).toLowerCase()) : [];
}

/**
 * True when no channel may take `item`, whatever its rules: on Emby, a Dolby Vision profile 5
 * file (`item.doviProfile === 5`, from Emby's ExtendedVideoSubType, see point 11 in
 * nostalgex-jellyfin-urls.js). Emby 4.10.1.0 sends profile 5 to a browser re-encoded with no
 * tone mapping and to the Apple TV with no Dolby Vision signalling, so both draw it green and
 * purple, and no request changes that (measured 2026-10-19). Profile 8 keeps an HDR10 base
 * layer and stays. Plex and Jellyfin are untouched. An unknown profile (null) is kept.
 * The item stays in the library; only channel pools leave it out.
 * Mirrors ChannelEligibility.isLeftOffChannels in Nostalgex/Nostalgex/Services/ChannelEligibility.swift.
 * @param {object} item
 * @param {string} [backend] 'plex', 'jellyfin' or 'emby' (the tuner's mediaBackend)
 */
function isLeftOffChannels(item, backend) {
  return backend === "emby" && !!item && item.doviProfile === 5;
}

/** `items` without the ones isLeftOffChannels leaves out, in the same order. */
function onChannels(items, backend) {
  if (backend !== "emby") return items;
  return items.filter((it) => !isLeftOffChannels(it, backend));
}

/**
 * Episode rules. Mirrors AppState+Channels.swift (`hasEpisodeRules`, `episodeRulesMatch`);
 * scripts/filter-golden.json pins both.
 *
 * They read an item's OWN title: the episode title for an episode, the title (year
 * suffix stripped) for anything else, so a half-hour special stored as a film ("A
 * Charlie Brown Christmas") matches the same way an episode does. Whole words, case
 * ignored, the same boundary rule as `titleContains`.
 *   - episodeTitleContains: a word in the own title
 *   - episodeSummaryContains: a word in the item's summary
 *   - episodeSeasonalTitleContains: a word in the own title that only counts for an
 *     episode first aired inside `episodeAirWindow` ({ from: "MM-DD", to: "MM-DD" },
 *     inclusive, wrapping the new year when from > to). "Holiday" in December is
 *     The Holiday Armadillo; "Roman Holiday" in September is a trip to Rome. Films
 *     never take this path: the web carries no release date for them.
 *   - episodeTitleExcludes: a word in the own title that vetoes the item
 * A channel with any of the first three is episode-curated: an item must match one of
 * them, and nothing else widens it.
 */
function hasEpisodeRules(r) {
  return ["episodeTitleContains", "episodeSummaryContains", "episodeSeasonalTitleContains"]
    .some((k) => Array.isArray(r?.[k]) && r[k].length > 0);
}

function ownTitleLower(item) {
  if (item.type === "episode") return String(item.episodeTitle || "").toLowerCase();
  return stripYearSuffix(String(item.title || ""));
}

/** "MM-DD" -> month * 100 + day, or null. */
function parseMonthDay(s) {
  const m = /^(\d{1,2})-(\d{1,2})$/.exec(String(s ?? "").trim());
  return m ? Number(m[1]) * 100 + Number(m[2]) : null;
}

/** First-aired month * 100 + day from `originallyAvailableAt` (YYYY-MM-DD...), or null. */
function airMonthDay(item) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(item.originallyAvailableAt || ""));
  return m ? Number(m[2]) * 100 + Number(m[3]) : null;
}

function inAirWindow(item, window) {
  const from = parseMonthDay(window?.from);
  const to = parseMonthDay(window?.to);
  const md = airMonthDay(item);
  if (from == null || to == null || md == null) return false;
  return from <= to ? md >= from && md <= to : md >= from || md <= to;
}

function episodeRulesMatch(item, r) {
  const own = ownTitleLower(item);
  const has = (list, hay) => Array.isArray(list) && hay.length > 0
    && list.some((t) => titleContainsWord(hay, t));
  if (has(r.episodeTitleExcludes, own)) return false;
  if (has(r.episodeTitleContains, own)) return true;
  if (Array.isArray(r.episodeSummaryContains) && r.episodeSummaryContains.length
      && has(r.episodeSummaryContains, String(item.summary || "").toLowerCase())) return true;
  if (item.type === "episode" && Array.isArray(r.episodeSeasonalTitleContains)
      && r.episodeSeasonalTitleContains.length && inAirWindow(item, r.episodeAirWindow)
      && has(r.episodeSeasonalTitleContains, own)) return true;
  return false;
}

/**
 * @param {object} item — normalized pool item (title, genres[], type, tmdbID, …)
 * @param {{ id: number, rules?: object, category?: string }} channel
 * @param {{ manifest?: object, nowSec?: number, backend?: string }} [opts]
 * @returns {false | { pass: true, via: 'rules' | 'manifest' | 'editorial' }}
 */
function itemPasses(item, channel, opts = {}) {
  // Emby Dolby Vision profile 5: on no channel, whatever the rules say.
  if (isLeftOffChannels(item, opts.backend)) return false;
  const r = channel.rules || {};
  const category = channel.category || null;
  const manifest = opts.manifest || null;
  const nowSec = opts.nowSec ?? Math.floor(Date.now() / 1000);
  const currentYear = new Date().getFullYear();
  // Mirrors AppState+Channels.swift `filterTitleHaystack`: artist FIRST, then
  // title, joined with a space, lowercased, then the trailing " (YYYY)" stripped.
  const titleLower = stripYearSuffix(
    [item.artist || "", item.title || ""].filter(Boolean).join(" "),
  );
  // The server's genres. A lock's genre test always reads these, on both engines.
  const plexGenres = (item.genres || []).map((g) => String(g).toLowerCase());
  // `matchTmdbGenres`: this channel also sees the item's TMDB genres (enrichment
  // `tmdbGenres`). A Plex listing carries two genres per film, so a Hallmark-style
  // Christmas romance often reads "Family, Drama" while TMDB says "TV Movie,
  // Romance, Family". Unenriched items fall back to the server's genres.
  // Mirrors AppState+Channels.swift.
  const itemGenres = r.matchTmdbGenres
    ? [...new Set([...plexGenres, ...enrichedList(item, "tmdbGenres")])]
    : plexGenres;

  // Episode rules: an episode's own title and summary rather than the show name. A
  // Christmas special lives in "The One with the Holiday Armadillo", not in "Friends".
  // Keep in sync with AppState+Channels.swift (`episodeRulesMatch`).
  const isEpisodeCurated = hasEpisodeRules(r);
  const matchesEpisodeRules = isEpisodeCurated && episodeRulesMatch(item, r);

  const matchesTitleRule = (() => {
    if (!Array.isArray(r.titleContains) || !r.titleContains.length) return true;
    return r.titleContains.some((t) => titleContainsWord(titleLower, t));
  })();

  const itemSource = item.librarySource || "movie";
  if (r.source) {
    if (itemSource !== r.source) return false;
  } else if (itemSource === "musicVideo") {
    return false;
  }

  const isKids = category === "kids";
  const hasFamilyGenre = includeList(r).some((g) => g.toLowerCase() === "family");
  const isFamilySafe = isKids || hasFamilyGenre;
  if (isFamilySafe && item.contentRating && ADULT_RATINGS.has(usContentRating(item.contentRating, item.type))) {
    return false;
  }

  const hasGenreInclude = includeList(r).length > 0;
  const hasStudioRule = Array.isArray(r.studios) && r.studios.length > 0;
  const isStudioChannel = hasStudioRule && !hasGenreInclude;

  // Episode rules are a curated list the same way a title list is, so they open the
  // Animation lock too: Bluey's and The Simpsons' Christmas episodes belong on the
  // holiday TV channels.
  const hasTitleCurated =
    (Array.isArray(r.titleContains) && r.titleContains.length > 0) || isEpisodeCurated;
  const allowsAnimation =
    isStudioChannel || channelIncludesGenre(r, ANIMATION) || isKids || hasTitleCurated;
  const allowsHorror = isStudioChannel || channelIncludesGenre(r, HORROR);
  const allowsReality = isStudioChannel || channelIncludesGenre(r, REALITY);
  const allowsDocumentary = isStudioChannel || channelIncludesGenre(r, DOCUMENTARY);

  const allowsWar = isStudioChannel || channelIncludesGenre(r, WAR);
  const allowsWestern = isStudioChannel || channelIncludesGenre(r, WESTERN);
  const allowsTalkShow = isStudioChannel || channelIncludesGenre(r, TALKSHOW);

  if (itemGenres.some((g) => HORROR.has(g)) && !allowsHorror) return false;
  if (itemGenres.some((g) => REALITY.has(g)) && !allowsReality) return false;
  if (itemGenres.some((g) => ANIMATION.has(g)) && !allowsAnimation) return false;
  if (itemGenres.some((g) => DOCUMENTARY.has(g)) && !allowsDocumentary) return false;
  // Sport genre is not globally blocked — sports movies (Rudy, The Sixth Man, Space Jam)
  // can appear on any channel their other genres qualify them for.
  // Music genre lock removed to match tvOS (AppState.swift): the source filter
  // already keeps music videos out of channels that don't opt in via
  // `source: musicVideo`, and music feature films (8 Mile, La La Land,
  // Bohemian Rhapsody) need to flow through movie channels.
  if (itemGenres.some((g) => WAR.has(g)) && !allowsWar) return false;
  if (itemGenres.some((g) => WESTERN.has(g)) && !allowsWestern) return false;
  if (itemGenres.some((g) => TALKSHOW.has(g)) && !allowsTalkShow) return false;

  const isExplicitReality = channelIncludesGenre(r, REALITY);
  if (isExplicitReality && !itemGenres.some((g) => REALITY.has(g))) return false;

  if (Array.isArray(r.editorialOverrides) && r.editorialOverrides.length) {
    if (r.editorialOverrides.some((t) => titleLower === t.toLowerCase())) {
      return { pass: true, via: "editorial" };
    }
  }

  // Manifest-level exclusivity. The manifest builder may flag an item as
  // exclusive to a single channel (e.g. stand-up specials lock to STAND-UP via
  // the "stand-up comedy" TMDB keyword) — those items must not appear anywhere
  // else, even when the channel's own rules would otherwise match.
  if (manifest?.items && item.tmdbID) {
    const mediaType = item.type === "episode" ? "tv" : "movie";
    const entry = manifest.items[`${mediaType}:${item.tmdbID}`];
    if (entry && entry.exclusive != null && entry.exclusive !== channel.id) {
      return false;
    }
  }

  if (manifest && manifestClaimsChannel(item, channel.id, manifest)) {
    if (r.type && item.type !== r.type) return false;
    if (!passesYearRange(item, r)) return false;
    if (Array.isArray(r.titleContains) && r.titleContains.length && !matchesTitleRule) {
      return false;
    }
    // Nor past the episode rules: a claim for an episode-curated channel still has to
    // be a holiday episode. Keep in sync with AppState+Channels.swift.
    if (isEpisodeCurated && !matchesEpisodeRules) return false;
    // titleExcludes outranks a manifest claim for the same reason genres.exclude does:
    // SCREAM ADULTS lists "Ring" for The Ring, and the manifest handed it The Lord of
    // the Rings: The Fellowship of the Ring. Keep in sync with AppState+Channels.swift.
    const manifestTitleExcludes = r.titleExcludes || [];
    if (manifestTitleExcludes.length &&
        manifestTitleExcludes.some((t) => titleContainsWord(titleLower, t))) {
      return false;
    }
    // genres.exclude still applies to a manifest claim. The manifest is built by
    // expanding TMDB "similar" titles out from a handful of exemplars, which
    // drifts: SCI-FI (excludes Animation/Family/Kids) was being handed Aladdin,
    // The Return of Jafar and TMNT purely because they were "similar" to
    // something. A channel's own exclusions are an editorial statement about
    // what must never appear on it, so they outrank a similarity guess.
    // Includes stay bypassed on purpose, since widening membership past
    // genres.include is the whole point of the manifest.
    const manifestExcludes = r.genres?.exclude || [];
    if (manifestExcludes.length) {
      const blocked = manifestExcludes.some((e) =>
        itemGenres.some((g) => g.includes(e.toLowerCase())),
      );
      if (blocked) return false;
    }
    return { pass: true, via: "manifest" };
  }

  // manifestOnly: membership normally comes solely from the manifest. A channel
  // can opt in to a second, additive claim path by also setting
  // manifestOnlyGenreFallback: true, the normal content-matching block below
  // then runs too, the same keyword/genre/keywordGatedGenres rules as any other
  // channel. STAND-UP opts in this way: Comedy/Documentary alone still need the
  // "stand-up comedy"/"comedian" keyword (keywordGatedGenres), but the narrower
  // "Stand-Up" server genre tag is specific enough on its own, so a title TMDB
  // never tagged with that keyword can still reach the channel if the server
  // tagged it that way. The flag is a per-channel opt-in, not an automatic
  // inference, it does not itself guard against a catch-all, the channel's own
  // rules do, so each manifestOnly channel's rules get reviewed before it's set.
  // CRITERION defines no genre/keyword rules at all; ANIME, WORLD HORROR and
  // MYSTERY BOX TV haven't opted in (same gap, tracked separately). Keep in
  // sync with AppState+Channels.swift.
  if (r.manifestOnly && !r.manifestOnlyGenreFallback) return false;

  if (Array.isArray(r.titleExcludes) && r.titleExcludes.length) {
    if (r.titleExcludes.some((t) => titleContainsWord(titleLower, t))) return false;
  }

  // Channel exclusivity (mirrors AppState): block items owned by another channel.
  const exclusiveRules = opts.exclusiveRules || [];
  for (const rule of exclusiveRules) {
    const ids = rule.channelIDs || (rule.channelID != null ? [rule.channelID] : []);
    if (ids.includes(channel.id)) continue;
    if (!exclusiveRuleApplies(item, rule)) continue;
    // Server genres only, as Swift's ExclusiveRule.matches reads item.genres.
    if (exclusiveRuleMatches(item, plexGenres, rule)) return false;
    if (rule.manifestExclusive && manifest && ids.some((id) => manifestClaimsChannel(item, id, manifest))) {
      return false;
    }
  }

  if (r.type && item.type !== r.type) return false;

  if (!passesYearRange(item, r)) return false;

  if (Array.isArray(r.contentRatings) && r.contentRatings.length) {
    const rating = usContentRating(item.contentRating, item.type) || "";
    if (rating === "" && r.allowUnrated) {
      /* pass */
    } else if (!r.contentRatings.includes(rating)) {
      return false;
    }
  }

  // No `contentRatingMax` here on purpose. It used to be implemented on this side
  // only, with no counterpart in Swift and no channel using it — so the first
  // channel to adopt it would have filtered on web and not on Apple TV. Use
  // `contentRatings` (an explicit allow-list, honoured by both) instead, or add a
  // max-rating rule to BOTH surfaces at once.

  if (r.durationRange) {
    const min = r.durationRange.min ?? r.durationRange.minMinutes;
    const max = r.durationRange.max ?? r.durationRange.maxMinutes;
    if (min != null && item.duration < min) return false;
    if (max != null && item.duration > max) return false;
  }

  const itemYear = parseYear(item) ?? 0;
  const isNewRelease = itemYear >= currentYear - 1;
  if (r.watchedOnly && (item.viewCount || 0) < 1 && !isNewRelease) return false;
  if (r.unwatchedOnly && ((item.viewCount || 0) > 0 || isNewRelease)) return false;
  if (r.rewatched && (item.viewCount || 0) < 3) return false;

  // Episode-curated channels: the episode rules are the allowlist, and nothing widens it.
  if (isEpisodeCurated && !matchesEpisodeRules) return false;

  const titleContains = matchesTitleRule;

  const genreInclude = r.genres?.include || [];
  const genreRequireAll = r.genres?.requireAll || [];
  const genreExclude = r.genres?.exclude || [];
  const itemTmdbKeywords = Array.isArray(item.tmdbKeywords)
    ? item.tmdbKeywords.map((k) => String(k).toLowerCase())
    : enrichedList(item, "keywords");

  if (genreExclude.length) {
    const blocked = genreExclude.some((e) =>
      itemGenres.some((g) => g.includes(e.toLowerCase())),
    );
    if (blocked) return false;
  }

  // Soft exclude: unenriched items pass (mirrors AppState+Channels.swift
  // "TMDB keyword exclude"). Keyword comparison is EXACT equality in Swift
  // (`itemKW.contains($0)` on an array of lowercased keywords), not substring.
  if (r.keywordsExclude?.length && itemTmdbKeywords.length) {
    const blocked = r.keywordsExclude.some((kw) =>
      itemTmdbKeywords.includes(kw.toLowerCase()),
    );
    if (blocked) return false;
  }

  // ── Enrichment gates ──────────────────────────────────────────────────────
  // These were previously written BELOW the content-rule block, which returns
  // early — so on every channel that has a genre/title/studio/keyword rule they
  // never ran. That silently disabled ratingMin on 13 channels (ALL TIME GREATS,
  // CERTIFIED GOLD, the decade channels, …) and releasedWithinMonths on CH49
  // FRESH. They are pure gates, so running them here matches Swift, where the
  // content-match block falls through instead of returning.

  // OMDb gates — mirror AppState+Channels.swift "OMDb rating gates".
  // HARD gates: a missing OMDb value REJECTS the item, exactly as Swift's
  // `guard let r = enrichment?.imdbRating` does. Operator is >= in both.
  if (typeof r.imdbRatingMin === "number") {
    const v = enrichedValue(item, "imdbRating");
    if (typeof v !== "number" || v < r.imdbRatingMin) return false;
  }
  if (typeof r.imdbVotesMin === "number") {
    const v = enrichedValue(item, "imdbVotes");
    if (typeof v !== "number" || v < r.imdbVotesMin) return false;
  }
  if (typeof r.rtScoreMin === "number") {
    const v = enrichedValue(item, "rottenTomatoesScore") ?? enrichedValue(item, "rtScore");
    if (typeof v !== "number" || v < r.rtScoreMin) return false;
  }
  if (typeof r.metacriticMin === "number") {
    const v = enrichedValue(item, "metacriticScore") ?? enrichedValue(item, "metacritic");
    if (typeof v !== "number" || v < r.metacriticMin) return false;
  }
  if (r.wonOscar) {
    const awards = enrichedValue(item, "awards");
    if (typeof awards !== "string") return false;
    const a = awards.toLowerCase();
    if (!(a.includes("won") && a.includes("oscar"))) return false;
  }

  // addedWithinDays — Swift compares `item.addedAt < cutoff`, so an item with no
  // addedAt (0) is rejected. Mirrored, including the `days > 0` guard.
  if (typeof r.addedWithinDays === "number" && r.addedWithinDays > 0) {
    const cutoff = nowSec - r.addedWithinDays * 86400;
    if ((item.addedAt || 0) < cutoff) return false;
  }

  // releasedWithinMonths — Swift prefers Plex `originallyAvailableAt` for true
  // month precision and falls back to a year approximation of
  // `yearsBack = (months + 11) / 12 - 1` (integer division).
  if (typeof r.releasedWithinMonths === "number" && r.releasedWithinMonths > 0) {
    const months = r.releasedWithinMonths;
    const raw = item.originallyAvailableAt;
    const m = typeof raw === "string" ? raw.match(/^(\d{4})-(\d{2})-(\d{2})/) : null;
    if (m) {
      const released = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
      const cutoff = new Date();
      cutoff.setMonth(cutoff.getMonth() - months);
      if (released < cutoff) return false;
    } else {
      const year = parseYear(item);
      if (year != null) {
        const yearsBack = Math.floor((months + 11) / 12) - 1;
        if (year < currentYear - yearsBack) return false;
      }
    }
  }

  // ratingMin — Plex star rating (item.rating) OR user rating clears the bar.
  // On Emby, CommunityRating (the field item.rating is built from) came back
  // null for 100% of a 500-title sample measured against Chad's own server, so
  // treating a missing native rating as an automatic fail silently emptied the
  // 13 channels that use a plain ratingMin gate. When neither native rating
  // clears the bar, fall back to the same OMDb-enriched rating used by the
  // imdbRatingMin gate above, at the same threshold, before rejecting. OMDb
  // enrichment is tvOS-only (written to the shared cache the web reads); on
  // web/Docker or Roku with no enrichment this just falls through to the
  // native-only check, unchanged from before.
  if (typeof r.ratingMin === "number") {
    const nativeOk =
      (item.rating || 0) >= r.ratingMin || (item.userRating || 0) >= r.ratingMin;
    if (!nativeOk) {
      const omdbRating = enrichedValue(item, "imdbRating");
      const omdbOk = typeof omdbRating === "number" && omdbRating >= r.ratingMin;
      if (!omdbOk) return false;
    }
  }

  let matchesGenre = false;
  if (genreInclude.length) {
    matchesGenre = itemGenres.some((g) =>
      genreInclude.some((m) => g.includes(m.toLowerCase())),
    );
  }
  if (genreRequireAll.length) {
    const allHit = genreRequireAll.every((m) =>
      itemGenres.some((g) => g.includes(m.toLowerCase())),
    );
    if (!allHit) return false;
  }

  // Swift `matchesStudio`: Plex studio first, then falls back to TMDB
  // productionCompanies and networks.
  let matchesStudio = false;
  if (hasStudioRule) {
    const lowerStudios = r.studios.map((s) => s.toLowerCase());
    const itemStudio = item.studio ? String(item.studio).toLowerCase() : "";
    matchesStudio =
      (itemStudio && lowerStudios.some((s) => itemStudio.includes(s))) ||
      enrichedList(item, "productionCompanies").some((pc) =>
        lowerStudios.some((s) => pc.includes(s)),
      ) ||
      enrichedList(item, "networks").some((n) => lowerStudios.some((s) => n.includes(s)));
  }

  const hasProdCoRule =
    Array.isArray(r.productionCompanies) && r.productionCompanies.length > 0;
  // Swift matches against `enrichment.productionCompanies`; Plex `studio` is the
  // partial stand-in when no enrichment record exists.
  const itemCompanies = enrichedList(item, "productionCompanies");
  const prodCoHaystack = item.studio
    ? [...itemCompanies, String(item.studio).toLowerCase()]
    : itemCompanies;
  let matchesProdCo = false;
  if (hasProdCoRule && prodCoHaystack.length) {
    matchesProdCo = r.productionCompanies.some((c) =>
      prodCoHaystack.some((pc) => pc.includes(c.toLowerCase())),
    );
  }

  const hasTitleRule = Array.isArray(r.titleContains) && r.titleContains.length > 0;
  const hasKeywordRule = Array.isArray(r.keywords) && r.keywords.length > 0;
  const hasNetworkRule = Array.isArray(r.networks) && r.networks.length > 0;
  const isTitleCuratedChannel =
    hasTitleRule && !hasKeywordRule && !hasNetworkRule && !hasProdCoRule && !hasStudioRule;

  // An episode-curated channel has already passed its allowlist and every gate above.
  // Swift skips its content-matching block for these channels; so does this.
  if (isEpisodeCurated) return { pass: true, via: "episode" };

  if (isTitleCuratedChannel) {
    // Title list is the allowlist (e.g. ADULT CARTOONS). Plex often tags these as
    // Comedy only — do not also require Animation/Animated in genres.include.
    if (!titleContains) return false;
    return { pass: true, via: "rules" };
  }

  // Evaluate TMDB keywords if the channel has a keyword rule and the item has enriched data
  // Keyword matching is ADDITIVE — it broadens membership, it never gates it.
  // Swift compares keywords by EXACT equality on the lowercased keyword list.
  // keywordsRequireAnyGenre is a substring test in Swift
  // (`itemGenres.contains { $0.contains(gateGenre) }`), not exact equality.
  let matchesKeyword = false;
  if (hasKeywordRule && itemTmdbKeywords.length) {
    const kwHit = r.keywords.some((kw) => itemTmdbKeywords.includes(kw.toLowerCase()));
    if (kwHit) {
      const kwGate = r.keywordsRequireAnyGenre;
      matchesKeyword =
        !kwGate?.length ||
        kwGate.some((g) => itemGenres.some((ig) => ig.includes(g.toLowerCase())));
    }
  }

  // networks — TMDB network list, substring match (item network CONTAINS rule).
  const itemNetworks = enrichedList(item, "networks");
  let matchesNetwork = false;
  if (hasNetworkRule && itemNetworks.length) {
    matchesNetwork = r.networks.some((n) =>
      itemNetworks.some((inw) => inw.includes(n.toLowerCase())),
    );
  }

  const hasAnyContentRule =
    hasTitleRule ||
    hasStudioRule ||
    hasGenreInclude ||
    hasProdCoRule ||
    hasKeywordRule ||
    hasNetworkRule;
  if (hasAnyContentRule) {
    if (hasTitleRule && titleContains) return { pass: true, via: "title" };
    if (matchesKeyword) return { pass: true, via: "keyword" };
    if (matchesNetwork) return { pass: true, via: "network" };
    if (matchesProdCo) return { pass: true, via: "prodco" };
    if (hasStudioRule && hasGenreInclude) {
      if (!matchesStudio || !matchesGenre) return false;
    } else if (hasStudioRule) {
      if (!matchesStudio) return false;
    } else if (hasGenreInclude) {
      if (!matchesGenre) return false;
      // keywordGatedGenres: broad genres also require a keyword match to prevent unrelated
      // content (rock films on MUSICALS, adult dramas on TEEN DRAMA) from passing on genre alone.
      if (r.keywordGatedGenres?.length) {
        // Exact genre match, not substring — otherwise gating "Music" also gates
        // "Musical", wrongly excluding genre-tagged musicals that have no keywords.
        const isGated = r.keywordGatedGenres.some((g) =>
          itemGenres.some((ig) => ig.toLowerCase() === g.toLowerCase())
        );
        if (isGated && !matchesKeyword) return false;
      }
    } else {
      return false;
    }
    return { pass: true, via: "rules" };
  }

  return { pass: true, via: "rules" };
}

function normalizePassResult(result) {
  if (result === false) return null;
  if (result === true || result?.pass) return result?.via ? result : { pass: true, via: "rules" };
  return null;
}

/**
 * Filter library items for a channel (returns enriched rows).
 */
function filterPool(allItems, channel, opts = {}) {
  const manifest = opts.manifest ?? null;
  const nowSec = opts.nowSec ?? Math.floor(Date.now() / 1000);
  const exclusiveRules = opts.exclusiveRules ?? [];
  const backend = opts.backend;
  const requiresAnimation = channelRequiresAnimationGenre(channel.rules || {});
  const seenShows = new Map();
  const items = [];

  for (const it of allItems) {
    const raw = itemPasses(it, channel, { manifest, nowSec, exclusiveRules, backend });
    const hit = normalizePassResult(raw);
    if (!hit) continue;

    const itemGenres = (it.genres || []).map((g) => String(g).toLowerCase());
    const animated = itemHasAnimationGenre(itemGenres);
    const row = {
      ...it,
      poolVia: hit.via,
      hasAnimationGenre: animated,
      suspectNonAnimation: requiresAnimation && !animated,
    };
    items.push(row);

    if (!seenShows.has(it.title)) {
      seenShows.set(it.title, {
        title: it.title,
        year: parseYear(it),
        hasAnimationGenre: animated,
        suspectNonAnimation: requiresAnimation && !animated,
        episodeCount: 1,
      });
    } else {
      const slot = seenShows.get(it.title);
      slot.episodeCount++;
      if (animated) {
        slot.hasAnimationGenre = true;
        slot.suspectNonAnimation = false;
      }
    }
  }

  return {
    items,
    shows: [...seenShows.values()].sort((a, b) => String(a.title).localeCompare(String(b.title))),
    requiresAnimation,
  };
}

const api = {
  itemPasses,
  filterPool,
  isLeftOffChannels,
  onChannels,
  parseTmdbIdFromPlex,
  passesYearRange,
  releaseYear,
  usContentRating,
  ratingTables: { bands: RATING_BANDS, us: US_RATINGS, words: RATING_WORDS, bare: RATING_BARE },
  enrichedValue,
  titleContainsWord,
  exclusiveRuleMatches,
  exclusiveRuleApplies,
  hasEpisodeRules,
  episodeRulesMatch,
  inAirWindow,
  channelRequiresAnimationGenre,
  itemHasAnimationGenre,
  GENRE_LOCKS: {
    horror: HORROR,
    reality: REALITY,
    animation: ANIMATION,
    documentary: DOCUMENTARY,
    sport: SPORT,
    music: MUSIC,
    war: WAR,
    western: WESTERN,
    talkShow: TALKSHOW,
  },
};

if (typeof module !== "undefined" && typeof module.exports !== "undefined") {
  module.exports = api;
}
if (typeof globalThis !== "undefined") {
  globalThis.NostalgexChannelFilter = api;
}
