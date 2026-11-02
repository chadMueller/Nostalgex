// Server collections as channels on the web tuner, the way the Apple TV app does it
// (Nostalgex/Nostalgex/App/AppState+Channels.swift `scanCollections` and
// `materializeDynamicChannels`, Models/Channel.swift `CollectionCategory` and
// `DynamicChannelBlock`, Services/CollectionClassifier.swift).
//
// - Plex: /library/sections/{key}/collections per movie and TV section, then
//   /library/collections/{key}/children for the ratingKeys.
// - Jellyfin and Emby: BoxSet items from /Items (one global list, deduped by id),
//   then the Movie and Series children of each BoxSet. Same calls as
//   JellyfinAPIService and EmbyAPIService `loadCollections` / `loadCollectionItems`.
// - Children resolve against what the library scan already holds on that server
//   (CollectionMemberIndex.swift): a film or episode key is that item, a show key
//   (Plex grandparentRatingKey, Jellyfin SeriesId, carried as `showKey` on every
//   episode) is all of that show's episodes. Emby answers the BoxSet query with the
//   episodes themselves, which match by key.
// - A collection becomes a candidate when it resolves to 3+ playable items. A
//   films-only collection is held to the old "3+ movies" exactly.
// - Candidates are sorted by upper-cased title (Swift `<` on String, so code-unit
//   order). With `ctx.classify` each also gets a category, FRANCHISES (movie series
//   and sequels) or OTHER COLLECTIONS (everything else), by `classify` below.
//
// Numbers, as DynamicChannelBlock (Apple TV 1.0.29, Roku 1.0.8, web tuner 1.0.11):
// - the stock FRANCHISES package is CH 300-306 (channels.json);
// - found franchises and the server's franchise collections share one pool, CH 310-399
//   (90 slots), numbered A to Z by name then stable id. When more are on than fit, the
//   ones with the most films stay (`keptInDisplayOrder`). Ids stay per kind: found
//   franchises from 1,000,000, franchise collections from 1,010,000;
// - other collections take CH 400-499 (100 slots), ids from 1,020,000: the first 100
//   switched on, in list order. Anything enabled past a cap is not built;
// - HIGH ROTATION is CH 500 and up (channels.json).
//
// Duplicates of a stock channel are flagged the way the app's collections list
// does ("Exists: CH 12 ACTION", "78% already on CH 101 MARVEL"). Which collections
// fold into a franchise (FranchiseCollectionFold.swift) is decided in
// nostalgex-franchise-lineup.js and handed to `buildCandidates` as `ctx.fold`;
// without it the cheap signals of the original port decide: that name match, that
// manifest overlap, or 60%+ of its movies already in a stock franchise channel's pool.
//
// scripts/franchise-lineup-golden.json holds `classify` and the numbering to the
// Apple TV's answers; the Swift and Roku tests read the same file.
(function (global) {
  'use strict';

  // ChannelIDSpace.dynamicBase and categoryStride: one id block per kind of runtime channel.
  const DYNAMIC_BASE = 1000000;
  const CATEGORY_STRIDE = 10000;
  const FOUND_ID_BASE = DYNAMIC_BASE;
  const FRANCHISE_COLLECTION_ID_BASE = DYNAMIC_BASE + CATEGORY_STRIDE;
  const ID_BASE = DYNAMIC_BASE + 2 * CATEGORY_STRIDE;
  // Found franchises and franchise collections: one pool, CH 310-399.
  const FRANCHISE_NUMBER_BASE = 310;
  const FRANCHISE_NUMBER_END = 399;
  const FRANCHISE_CAPACITY = FRANCHISE_NUMBER_END - FRANCHISE_NUMBER_BASE + 1;
  // Other collections: CH 400-499.
  const NUMBER_BASE = 400;
  const NUMBER_END = 499;
  const CAPACITY = NUMBER_END - NUMBER_BASE + 1;
  const MIN_MOVIES = 3;
  const MIN_ITEMS = 3;
  const OVERLAP_THRESHOLD = 60;
  const COLORS = [
    '#E74C3C', '#3498DB', '#2ECC71', '#F39C12', '#9B59B6',
    '#1ABC9C', '#E67E22', '#00CED1', '#FF6B81', '#A29BFE',
  ];

  // ── Pure: duplicate detection ──────────────────────────────────────────────

  /** Swift `collectionClean`: lowercased, "collection" removed, "'s" -> "s". */
  function cleanTitle(title) {
    return String(title || '').toLowerCase()
      .split(' collection').join('')
      .split('collection').join('')
      .split("'s").join('s')
      .split('’s').join('s')
      .trim();
  }

  /** Swift `decadeNormalized`: "2000s" -> "00s", "80s" -> "80s", else null. */
  function decadeNormalized(clean) {
    const digits = clean.replace(/[^0-9]/g, '');
    if (digits.length === 4) return `${String(Number(digits) % 100).padStart(2, '0')}s`;
    if (digits.length === 2) return `${digits}s`;
    return null;
  }

  function channelLabel(ch) {
    return `CH ${ch.number ?? ch.id} ${ch.name}`;
  }

  /**
   * Name-similarity match against the stock lineup (Swift `staticChannelLookup`).
   * `staticChannels` are the stock channels the lineup actually carries.
   */
  function matchStaticChannel(title, staticChannels) {
    const clean = cleanTitle(title);
    if (!clean) return null;
    const decade = decadeNormalized(clean);
    for (const ch of staticChannels) {
      const name = String(ch.name || '').toLowerCase();
      if (name.includes(clean) || clean.includes(name)) return channelLabel(ch);
      if (decade && name.includes(decade)) return channelLabel(ch);
    }
    return null;
  }

  /**
   * Swift `computeContentOverlap`: the channel the membership manifest claims the
   * most of this collection's movies for, when that is 60%+ of them.
   */
  function contentOverlap(items, manifest, channelsByID, threshold = OVERLAP_THRESHOLD) {
    const total = items.length;
    if (!total || !manifest || !manifest.items) return null;
    const perChannel = new Map();
    for (const item of items) {
      if (item.tmdbID == null) continue;
      const mediaType = item.type === 'episode' ? 'tv' : 'movie';
      const entry = manifest.items[`${mediaType}:${item.tmdbID}`];
      for (const cid of (entry && entry.channels) || []) perChannel.set(cid, (perChannel.get(cid) || 0) + 1);
    }
    let best = null;
    for (const [channelID, count] of perChannel) {
      if (!best || count > best.count) best = { channelID, count };
    }
    if (!best) return null;
    const percent = Math.round((best.count / total) * 100);
    if (percent < threshold) return null;
    const ch = channelsByID.get(best.channelID);
    return {
      channelID: best.channelID,
      channelName: ch ? channelLabel(ch) : `CH ${best.channelID}`,
      overlapCount: best.count,
      totalCount: total,
      percent,
    };
  }

  /**
   * FranchiseCollectionFold steps 3 and 4 against the stock franchise channels:
   * the name match or manifest overlap points at one, or 60%+ of the collection's
   * movies already sit in one's pool. Returns the target label or null.
   *
   * A folded collection is hidden, so one that holds shows folds only into a channel
   * already airing an episode of each of them (Swift `carriesEveryShow`).
   */
  function foldTarget(collection, franchiseChannels, itemKey, threshold = OVERLAP_THRESHOLD) {
    if (!franchiseChannels.length) return null;
    const ch = pickFoldChannel(collection, franchiseChannels, itemKey, threshold);
    if (!ch || !carriesEveryShow(collection, ch, itemKey)) return null;
    return channelLabel(ch);
  }

  function pickFoldChannel(collection, franchiseChannels, itemKey, threshold) {
    const labels = new Map(franchiseChannels.map((ch) => [channelLabel(ch), ch]));
    if (collection.matchedChannel && labels.has(collection.matchedChannel)) return labels.get(collection.matchedChannel);
    if (collection.contentOverlap) {
      const ch = franchiseChannels.find((c) => c.id === collection.contentOverlap.channelID);
      if (ch) return ch;
    }
    const total = collection.items.length;
    if (!total) return null;
    const keys = new Set(collection.items.map(itemKey));
    let best = null;
    for (const ch of franchiseChannels) {
      let count = 0;
      for (const it of ch.itemPool || []) if (keys.has(itemKey(it))) count++;
      if (count > ((best && best.count) || 0)) best = { ch, count };
    }
    if (best && Math.round((best.count / total) * 100) >= threshold) return best.ch;
    return null;
  }

  function carriesEveryShow(collection, ch, itemKey) {
    const pool = new Set((ch.itemPool || []).map(itemKey));
    const covered = new Map();
    for (const it of collection.items) {
      if (!it || it.type !== 'episode') continue;
      const show = showIdentity(it);
      if (covered.get(show)) continue;
      covered.set(show, pool.has(itemKey(it)));
    }
    for (const ok of covered.values()) if (!ok) return false;
    return true;
  }

  // ── Pure: members (CollectionMemberIndex.swift) ────────────────────────────

  /** Which show an episode belongs to: its show key, else its show title. */
  function showIdentity(it) {
    return it.showKey != null && it.showKey !== '' ? `key:${it.showKey}` : `title:${it.title}`;
  }

  /**
   * Index the library per server: every item by ratingKey, and episodes grouped by
   * their show key. Returns Map(serverKey -> { byKey, byShow }).
   */
  function indexLibrary(items, serverKeyFor) {
    const out = new Map();
    for (const it of items || []) {
      if (!it) continue;
      const sk = serverKeyFor(it);
      if (!out.has(sk)) out.set(sk, { byKey: new Map(), byShow: new Map() });
      const idx = out.get(sk);
      const key = String(it.ratingKey);
      if (!idx.byKey.has(key)) idx.byKey.set(key, it);
      if (it.type === 'episode' && it.showKey != null && it.showKey !== '') {
        const show = String(it.showKey);
        if (!idx.byShow.has(show)) idx.byShow.set(show, []);
        idx.byShow.get(show).push(it);
      }
    }
    return out;
  }

  /**
   * Child keys -> library items, each once, in child order. `index` is { byKey, byShow }
   * from indexLibrary, or a plain Map(ratingKey -> item) (films only, the old shape).
   */
  function resolveMembers(childKeys, index) {
    const byKey = index instanceof Map ? index : ((index && index.byKey) || new Map());
    const byShow = index instanceof Map ? new Map() : ((index && index.byShow) || new Map());
    const items = [];
    const seen = new Set();
    // One index is one server, where a ratingKey is unique.
    const add = (it) => {
      const id = String(it.ratingKey);
      if (!seen.has(id)) { seen.add(id); items.push(it); }
    };
    for (const k of childKeys || []) {
      const key = String(k);
      const it = byKey.get(key);
      if (it) add(it);
      else if (byShow.has(key)) byShow.get(key).forEach(add);
    }
    return items;
  }

  function countMembers(items) {
    let movies = 0;
    const shows = new Set();
    for (const it of items) {
      if (it.type === 'episode') shows.add(showIdentity(it));
      else movies++;
    }
    return { movies, shows: shows.size, episodes: items.length - movies };
  }

  /** Films plus the first episode of each show: one entry per title. */
  function titleRepresentatives(items) {
    const seen = new Set();
    return items.filter((it) => {
      if (it.type !== 'episode') return true;
      const show = showIdentity(it);
      if (seen.has(show)) return false;
      seen.add(show);
      return true;
    });
  }

  /** Swift `DiscoveredCollection.memberSummary`. */
  function memberSummary(c) {
    const movies = c.movieCount || 0;
    const shows = c.showCount || 0;
    const episodes = c.episodeCount || 0;
    const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
    if (!shows) return `${movies} movies`;
    if (!movies) return `${plural(shows, 'show', 'shows')} · ${plural(episodes, 'episode', 'episodes')}`;
    return `${plural(movies, 'movie', 'movies')} · ${plural(shows, 'show', 'shows')}`;
  }

  // ── Pure: classification (CollectionClassifier.swift) ──────────────────────

  // Text handling at the Unicode edges, as the franchise builder does it: Swift counts
  // and compares Characters (grapheme clusters), so these do too.
  const segmenter =
    typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
      ? new Intl.Segmenter(undefined, { granularity: 'grapheme' })
      : null;

  function graphemes(s) {
    if (segmenter) return Array.from(segmenter.segment(s), (seg) => seg.segment);
    return Array.from(s);
  }

  /** `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not line breaks. */
  function trimWhitespaces(s) {
    return s.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, '');
  }

  /** `trimmingCharacters(in: .punctuationCharacters)`: Unicode category P. */
  function trimPunctuation(s) {
    return s.replace(/^\p{P}+|\p{P}+$/gu, '');
  }

  /** `trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))`. */
  function trimWhitespacesAndPunctuation(s) {
    return s.replace(/^[\t\p{Zs}\p{P}]+|[\t\p{Zs}\p{P}]+$/gu, '');
  }

  // Source names (safe as substrings) of service-generated collections, and the
  // list and quality phrases that mark one. Phrases, not bare words, so "Top Gun" stays.
  const GENERATED_SOURCES = [
    'anilist', 'myanimelist', 'mal ', 'imdb', 'tmdb', 'themoviedb',
    'letterboxd', 'trakt', 'tvdb', 'rotten tomatoes', 'metacritic',
  ];
  const GENERATED_PHRASES = [
    'popular', 'trending', 'top rated', 'highest rated', 'best rated',
    'most watched', 'most popular', 'recently added', 'recently released',
    'newly added', 'new releases', 'favorited', 'recommended', 'watchlist',
    'top 250', 'top 100', 'top 50', 'top 10',
  ];

  // Franchises that are hard to detect by name repetition.
  const KNOWN_FRANCHISES = [
    'batman', 'superman', 'spider-man', 'spiderman',
    'wolverine', 'x-men', 'deadpool', 'venom',
    'wonder woman', 'aquaman', 'the flash',
    'iron man', 'captain america', 'thor', 'ant-man',
    'black panther', 'hulk', 'avengers',
    'guardians of the galaxy',
    'fantastic four', 'blade',
    'hellboy', 'spawn', 'the crow',
    'teenage mutant ninja turtles', 'tmnt',
    'james bond', '007',
    'jack ryan', 'jack reacher',
    'the equalizer',
    'the conjuring', 'conjuring', 'annabelle',
    'final destination',
    'a nightmare on elm street', 'elm street',
    'friday the 13th',
    "child's play", 'chucky',
    'the exorcist', 'the omen',
    'evil dead',
    'national lampoon',
    'monty python',
    'ocean',
    'naked gun',
    'scary movie',
    'hot shots',
    'planet of the apes',
    'the karate kid', 'karate kid',
    'the chronicles of narnia', 'narnia',
  ];

  const FRANCHISE_KEYWORDS = ['saga', 'trilogy', 'universe', 'chronicles', 'franchise', 'cinematic'];

  const STOP_WORDS = new Set([
    'the', 'a', 'an', 'of', 'and', 'in', 'on', 'to', 'for', 'is', 'it',
    'at', 'by', 'or', 'as', 'no', 'not', 'but', 'be', 'was', 'with', 'from',
  ]);

  function defaultEnrichmentFor(item) {
    return item && item.enrichment ? item.enrichment : null;
  }

  function franchiseIDOf(enrichmentFor, item) {
    const e = enrichmentFor(item);
    if (!e) return null;
    const v = e.franchiseID;
    if (typeof v === 'number' && Number.isInteger(v)) return v;
    if (typeof v === 'string' && /^-?\d+$/.test(v.trim())) return Number(v.trim());
    return null;
  }

  function isGeneratedListCollection(lower) {
    return GENERATED_SOURCES.some((s) => lower.includes(s)) || GENERATED_PHRASES.some((p) => lower.includes(p));
  }

  /** True when 2+ items share the same TMDB collection id. One film alone is not a series. */
  function sharesFranchiseID(items, enrichmentFor) {
    const counts = new Map();
    for (const item of items) {
      const fid = franchiseIDOf(enrichmentFor, item);
      if (fid === null) continue;
      const n = (counts.get(fid) || 0) + 1;
      counts.set(fid, n);
      if (n >= 2) return true;
    }
    return false;
  }

  /** The collection's own name in 2+ of its titles ("John Wick" when a sequel is "Parabellum"). */
  function nameAppearsInTitles(lowerName, items) {
    if (graphemes(lowerName).length < 3) return false;
    return items.filter((it) => String(it.title || '').toLowerCase().includes(lowerName)).length >= 2;
  }

  /** Swift `String.hasPrefix`: Character by Character, after canonical normalization. */
  function startsWithGraphemes(chars, prefixChars) {
    if (prefixChars.length > chars.length) return false;
    for (let i = 0; i < prefixChars.length; i++) if (chars[i] !== prefixChars[i]) return false;
    return true;
  }

  /**
   * hasRepeatingNames: a meaningful word (3+ Characters, not a stop word) in
   * max(3, 60% of the titles) titles, or a title prefix of 4+ Characters that many
   * titles start with ("High School Musical" and "... Musical 2").
   */
  function hasRepeatingNames(items) {
    const titles = items.map((it) => String(it.title || '').toLowerCase().normalize('NFC'));
    const wordHits = new Map();
    for (const title of titles) {
      const unique = new Set();
      for (const part of title.split(' ')) {
        if (part === '') continue;
        const word = trimPunctuation(part);
        if (graphemes(word).length >= 3 && !STOP_WORDS.has(word)) unique.add(word);
      }
      for (const word of unique) wordHits.set(word, (wordHits.get(word) || 0) + 1);
    }
    const threshold = Math.max(3, Math.floor((items.length * 6) / 10));
    for (const n of wordHits.values()) if (n >= threshold) return true;

    const chars = titles.map(graphemes);
    if (!chars.length) return false;
    let prefix = chars[0];
    for (const other of chars.slice(1)) {
      let i = 0;
      while (i < prefix.length && i < other.length && prefix[i] === other[i]) i++;
      prefix = prefix.slice(0, i);
    }
    const trimmed = trimWhitespacesAndPunctuation(prefix.join(''));
    if (trimmed === '') return false;
    const trimmedChars = graphemes(trimmed);
    if (trimmedChars.length >= 4) {
      const matches = chars.filter((c) => startsWithGraphemes(c, trimmedChars)).length;
      if (matches >= threshold) return true;
    }
    return false;
  }

  /**
   * Which of the two categories a server collection belongs in. Mirrors
   * `CollectionClassifier.classify`: FRANCHISES ("franchises") is movie series and
   * sequels, OTHER COLLECTIONS ("custom") is actors, directors and the viewer's own sets.
   *
   * `items` are the collection's resolved library items. `enrichmentFor` defaults to
   * `item.enrichment`; a TMDB `franchiseID` shared by 2+ films is the authoritative
   * signal, the title rules below it are the fallback for films with no enrichment yet.
   */
  function classify(title, items, enrichmentFor) {
    const list = Array.isArray(items) ? items.filter(Boolean) : [];
    const lookup = typeof enrichmentFor === 'function' ? enrichmentFor : defaultEnrichmentFor;
    // Shows: every episode carries its show's title, so the word rules below would call
    // any collection of shows a franchise. FRANCHISES is movie series, so the films alone
    // decide; a collection with no films is the viewer's own set.
    const films = list.filter((it) => it.type !== 'episode');
    if (films.length < list.length) {
      if (!films.length) return 'custom';
      return classify(title, films, enrichmentFor);
    }

    const cleaned = trimWhitespaces(
      String(title == null ? '' : title)
        .replace(/ collection/gi, '')
        .replace(/collection/gi, '')
        .split("'s").join('')
        .split('’s').join(''),
    );
    const lower = cleaned.toLowerCase();

    // 0. Service-generated lists ("IMDb Popular"), before the franchise id so a popular
    //    list that holds two films of one series still lands in OTHER COLLECTIONS.
    if (isGeneratedListCollection(lower)) return 'custom';
    // 0.5 Two or more films sharing a TMDB collection.
    if (sharesFranchiseID(list, lookup)) return 'franchises';
    // 1. Known franchise names.
    if (KNOWN_FRANCHISES.some((name) => lower.includes(name))) return 'franchises';
    // 2. Franchise keywords.
    if (FRANCHISE_KEYWORDS.some((word) => lower.includes(word))) return 'franchises';
    // 3. A word or a title prefix shared by 3 or more titles.
    if (list.length >= 3 && hasRepeatingNames(list)) return 'franchises';
    // 4. The collection's own name in 2 or more of its titles.
    if (nameAppearsInTitles(lower, list)) return 'franchises';
    // 5. Everything else, actor and director sets included.
    return 'custom';
  }

  // ── Pure: the runtime blocks (DynamicChannelBlock.keptInDisplayOrder) ──────

  /** Swift String `<` for these names: NFC-normalized code points. */
  function compareStrings(a, b) {
    const x = Array.from(String(a).normalize('NFC'));
    const y = Array.from(String(b).normalize('NFC'));
    const n = Math.min(x.length, y.length);
    for (let i = 0; i < n; i++) {
      const d = x[i].codePointAt(0) - y[i].codePointAt(0);
      if (d !== 0) return d < 0 ? -1 : 1;
    }
    return x.length === y.length ? 0 : x.length < y.length ? -1 : 1;
  }

  /**
   * The switched-on entries a block keeps, in the order they are numbered.
   *
   * entries: [{ name, stableID, films, ... }]. When more are on than fit, the ones with
   * the most films stay; ties go to the name, then the stable id, so every platform
   * drops the same ones. The kept entries are then numbered A to Z (name, then stable
   * id). Returns { kept, skipped }.
   */
  function keptInDisplayOrder(entries, capacity) {
    const alphabetical = (a, b) => compareStrings(a.name, b.name) || compareStrings(a.stableID, b.stableID);
    if (entries.length <= capacity) return { kept: entries.slice().sort(alphabetical), skipped: 0 };
    const kept = entries
      .slice()
      .sort((a, b) => (a.films !== b.films ? b.films - a.films : alphabetical(a, b)))
      .slice(0, capacity);
    return { kept: kept.sort(alphabetical), skipped: entries.length - capacity };
  }

  // ── Pure: candidates and channels ──────────────────────────────────────────

  /**
   * raw: [{ id, title, childKeys, serverKey }]. indexByServer: Map(serverKey -> index),
   * the index from indexLibrary, or a plain Map(ratingKey -> item) of films (the old
   * shape, still accepted). Returns candidates sorted the way the app lists them.
   *
   * ctx.classify: true gives each candidate its `category` (see `classify`, reading
   * ctx.enrichmentFor, default `item.enrichment`). Without it no candidate has one and
   * `materialize` treats every one as OTHER COLLECTIONS.
   * ctx.fold: (candidate) => label or null, the franchise fold of
   * nostalgex-franchise-lineup.js. Without it `foldedInto` comes from the stock
   * franchise channels in ctx.franchiseChannels alone (`foldTarget`).
   */
  function buildCandidates(raw, indexByServer, ctx = {}) {
    const staticChannels = ctx.staticChannels || [];
    const channelsByID = ctx.channelsByID || new Map(staticChannels.map((c) => [c.id, c]));
    const franchiseChannels = ctx.franchiseChannels || [];
    const itemKey = ctx.itemKey || ((it) => String(it.ratingKey));
    const enabledKeys = ctx.enabledKeys || new Set();
    const out = [];
    for (const c of raw) {
      const items = resolveMembers(c.childKeys, indexByServer.get(c.serverKey));
      if (items.length < MIN_ITEMS) continue;
      const counts = countMembers(items);
      const candidate = {
        id: c.id,
        title: String(c.title || 'Untitled').toUpperCase(),
        movieCount: counts.movies,
        showCount: counts.shows,
        episodeCount: counts.episodes,
        items,
        enabled: enabledKeys.has(c.id),
        matchedChannel: matchStaticChannel(c.title, staticChannels),
        // One entry per show, so a long show does not outweigh the rest of the set.
        contentOverlap: contentOverlap(titleRepresentatives(items), ctx.manifest, channelsByID),
        foldedInto: null,
      };
      // The classifier reads the server's own title, not the upper-cased one.
      if (ctx.classify === true) candidate.category = classify(c.title, items, ctx.enrichmentFor);
      candidate.foldedInto = typeof ctx.fold === 'function'
        ? ctx.fold(candidate)
        : foldTarget(candidate, franchiseChannels, itemKey);
      out.push(candidate);
    }
    out.sort((a, b) => (a.title < b.title ? -1 : a.title > b.title ? 1 : 0));
    return out;
  }

  /** Swift `duplicateWarning`, without the warning glyph. */
  function duplicateWarning(c) {
    if (c.contentOverlap) return `${c.contentOverlap.percent}% already on ${c.contentOverlap.channelName}`;
    if (c.matchedChannel) return `Exists: ${c.matchedChannel}`;
    return null;
  }

  function runtimeChannel(fields, slot, items) {
    const color = COLORS[slot % COLORS.length];
    return {
      color,
      colorHex: color,
      rules: null,
      timeRestrictions: null,
      minItems: MIN_ITEMS,
      stock: false,
      enabled: items.length >= MIN_ITEMS,
      schedule: [],
      itemPool: items,
      ...fields,
    };
  }

  /**
   * Swift `materializeDynamicChannels`: every runtime channel, in number order.
   *
   * The franchise pool (CH 310-399): the found franchises in `opts.found` (the switched-on
   * ones no stock channel covers: { id, name, movies, tvItems }) and the enabled, unfolded
   * candidates the classifier called FRANCHISES. When more than 90 are on, the ones with
   * the most films stay, then the kept ones are numbered by name, then stable id (`f:`
   * found, `c:` collection). Ids stay per kind, in the order the kind is numbered.
   *
   * OTHER COLLECTIONS (CH 400-499): the other enabled, unfolded candidates in list order,
   * the first 100. Anything switched on past a block is not built.
   *
   * Without `opts.found` and with no candidate categorised as FRANCHISES this is the
   * original one-block behaviour.
   *
   * Returns { channels, overCap (collections past their block), overCapFranchises,
   * overCapCustom, overCapFound (found franchises past the franchise block) }.
   */
  function materialize(candidates, opts = {}) {
    const found = Array.isArray(opts.found) ? opts.found : [];
    const entries = [];
    for (const f of found) {
      entries.push({ name: f.name, stableID: `f:${f.id}`, films: (f.movies || []).length, found: f });
    }
    const others = [];
    for (const c of candidates) {
      if (!c.enabled || c.foldedInto) continue;
      if (c.category === 'franchises') {
        entries.push({ name: c.title, stableID: `c:${c.id}`, films: c.movieCount || 0, collection: c });
      } else {
        others.push(c);
      }
    }

    const channels = [];
    const pool = keptInDisplayOrder(entries, FRANCHISE_CAPACITY);
    let foundCount = 0;
    let collectionCount = 0;
    pool.kept.forEach((e, slot) => {
      const number = FRANCHISE_NUMBER_BASE + slot;
      if (e.found) {
        const f = e.found;
        const items = [...(f.movies || []), ...(f.tvItems || [])];
        channels.push(runtimeChannel({
          id: FOUND_ID_BASE + foundCount++, number, name: f.name, category: 'franchises',
          collection: false, foundFranchise: true, franchiseID: f.id,
        }, slot, items));
      } else {
        const c = e.collection;
        channels.push(runtimeChannel({
          id: FRANCHISE_COLLECTION_ID_BASE + collectionCount++, number, name: c.title, category: 'franchises',
          collection: true, collectionID: c.id,
        }, slot, c.items.slice()));
      }
    });
    const keptStable = new Set(pool.kept.map((e) => e.stableID));
    const waiting = entries.filter((e) => !keptStable.has(e.stableID));
    const overCapFound = waiting.filter((e) => e.found).length;
    const overCapFranchises = waiting.length - overCapFound;

    let overCapCustom = 0;
    let slot = 0;
    for (const c of others) {
      if (slot >= CAPACITY) { overCapCustom++; continue; }
      channels.push(runtimeChannel({
        id: ID_BASE + slot, number: NUMBER_BASE + slot, name: c.title, category: 'custom',
        collection: true, collectionID: c.id,
      }, slot, c.items.slice()));
      slot++;
    }
    return {
      channels,
      overCap: overCapFranchises + overCapCustom,
      overCapFranchises,
      overCapCustom,
      overCapFound,
    };
  }

  // ── Network ────────────────────────────────────────────────────────────────

  async function mapLimit(list, limit, fn) {
    const out = new Array(list.length);
    let next = 0;
    async function worker() {
      while (next < list.length) {
        const i = next++;
        out[i] = await fn(list[i], i);
      }
    }
    await Promise.all(Array.from({ length: Math.min(limit, list.length) }, worker));
    return out;
  }

  /**
   * Plex. `getJSON(path)` fetches one server path and returns parsed JSON.
   * Returns [{ id, title, childKeys, serverKey }].
   */
  async function fetchPlexCollections(serverKey, getJSON, onProgress) {
    const sections = ((await getJSON('/library/sections')).MediaContainer || {}).Directory || [];
    const list = [];
    const seen = new Set();
    // TV sections too: a Plex collection of shows lives in the TV library.
    for (const section of sections.filter((s) => s.type === 'movie' || s.type === 'show')) {
      try {
        const data = await getJSON(`/library/sections/${section.key}/collections`);
        for (const c of (data.MediaContainer || {}).Metadata || []) {
          if (c && c.ratingKey != null && !seen.has(String(c.ratingKey))) {
            seen.add(String(c.ratingKey));
            list.push(c);
          }
        }
      } catch (err) {
        console.warn('[Collections] Section collections failed:', err && err.message);
      }
    }
    let done = 0;
    const out = await mapLimit(list, 4, async (c) => {
      let childKeys = [];
      try {
        const data = await getJSON(`/library/collections/${c.ratingKey}/children`);
        childKeys = ((data.MediaContainer || {}).Metadata || []).map((m) => String(m.ratingKey));
      } catch (err) {
        childKeys = null;
      }
      done++;
      if (onProgress) onProgress(done, list.length);
      return childKeys ? { id: `${serverKey}:${c.ratingKey}`, title: c.title || 'Untitled', childKeys, serverKey } : null;
    });
    return out.filter(Boolean);
  }

  /** Jellyfin and Emby. `getJSON(pathAndQuery)` against the server. */
  async function fetchBoxSetCollections(serverKey, userId, getJSON, onProgress) {
    const uid = encodeURIComponent(userId);
    const listing = await getJSON(`/Items?userId=${uid}&IncludeItemTypes=BoxSet&Recursive=true&Fields=ChildCount&SortBy=SortName`);
    const seen = new Set();
    const boxSets = (listing.Items || []).filter((b) => b && b.Id && !seen.has(b.Id) && seen.add(b.Id));
    let done = 0;
    const out = await mapLimit(boxSets, 4, async (b) => {
      const childKeys = [];
      try {
        let start = 0;
        while (true) {
          // Movie,Series: Jellyfin returns the series ids, Emby the series' episodes.
          const page = await getJSON(`/Items?userId=${uid}&ParentId=${encodeURIComponent(b.Id)}&Recursive=true`
            + `&IncludeItemTypes=Movie,Series&StartIndex=${start}&Limit=200&SortBy=SortName`);
          const items = page.Items || [];
          for (const it of items) childKeys.push(String(it.Id));
          start += items.length;
          const total = page.TotalRecordCount ?? childKeys.length;
          if (!items.length || childKeys.length >= total) break;
        }
      } catch (err) {
        done++;
        if (onProgress) onProgress(done, boxSets.length);
        return null;
      }
      done++;
      if (onProgress) onProgress(done, boxSets.length);
      return { id: `${serverKey}:${b.Id}`, title: b.Name || 'Untitled', childKeys, serverKey };
    });
    return out.filter(Boolean);
  }

  const api = {
    // Runtime blocks (DynamicChannelBlock): ids from FOUND_ID_BASE, one block per kind.
    DYNAMIC_BASE,
    FOUND_ID_BASE,
    FRANCHISE_COLLECTION_ID_BASE,
    FRANCHISE_NUMBER_BASE,
    FRANCHISE_NUMBER_END,
    FRANCHISE_CAPACITY,
    ID_BASE,
    NUMBER_BASE,
    NUMBER_END,
    CAPACITY,
    MIN_MOVIES,
    classify,
    keptInDisplayOrder,
    compareStrings,
    cleanTitle,
    decadeNormalized,
    channelLabel,
    matchStaticChannel,
    contentOverlap,
    foldTarget,
    showIdentity,
    indexLibrary,
    resolveMembers,
    titleRepresentatives,
    memberSummary,
    buildCandidates,
    duplicateWarning,
    materialize,
    fetchPlexCollections,
    fetchBoxSetCollections,
  };
  global.NostalgexCollections = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
