// Franchise channel grouping, the web port of the tvOS builder.
//
// PARITY CONTRACT with tvOS
//   Nostalgex/Nostalgex/Services/FranchiseChannelBuilder.swift  (grouping rules)
//   Nostalgex/Nostalgex/Services/FranchiseDictionary.swift      (loader, cleanFranchiseName)
//   franchises.json                                             (the shared dictionary)
//
// Both engines read the same franchises.json and are checked against the same
// golden vectors, scripts/franchise-golden.json: FranchiseGoldenTests on the Swift
// side, `npm run test:franchises` here. Change a rule in one engine without the
// other and one of those two tests fails.
//
// USAGE (browser: plain <script src="/scripts/nostalgex-franchise-builder.js">,
// node: `import "./nostalgex-franchise-builder.js"`, then globalThis):
//
//   const FB = window.NostalgexFranchiseBuilder;
//   const dict = await (await fetch('/franchises.json')).json();
//   const groupings = FB.build({
//     movies,                       // items with type movie; item.enrichment carries
//                                   //   { franchiseID, franchiseName } from TMDB
//     tvItems,                      // shows or episodes; `title` is the SHOW title
//     definitions: dict,            // the franchises.json document or its array
//     availableStockChannelIDs: [100, 101, 102],   // stock channels in the lineup
//     minimumFilms: 3,              // optional, the dynamic-channel gate
//     enrichmentFor: item => ...,   // optional, defaults to item.enrichment
//   });
//   // -> [{ name, stableID, placement: { type: 'stock', channelID } | { type: 'dynamic' },
//   //       movies, tvItems, mergedFranchiseIDs, fromDictionary }]
//
// The returned movies/tvItems are the caller's own item objects, in input order.
//
// KNOWN REMAINING DIFFERENCES (text handling at the Unicode edges only):
//  1. Swift Character.isLetter / isNumber are approximated with \p{Alphabetic} and
//     \p{N} on the first code point of each grapheme. Identical for Latin, Greek,
//     Cyrillic and CJK titles; could differ on rare numeric symbols.
//  2. Swift lowercased() maps scalar by scalar; JS toLowerCase() applies the Greek
//     final-sigma rule. Only a title ending in a capital sigma can differ.
//  3. Name sort compares NFC-normalized code points, which is Swift's String order
//     for everything in the golden file. Swift's full collation is not reproduced.
(function (global) {
  'use strict';

  const DEFAULT_MINIMUM_FILMS = 3;

  // MARK: - Unicode helpers

  const LETTER_OR_NUMBER = /^[\p{Alphabetic}\p{N}]/u;

  const segmenter =
    typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
      ? new Intl.Segmenter(undefined, { granularity: 'grapheme' })
      : null;

  /** Grapheme clusters, the JS stand-in for Swift's Character iteration. */
  function graphemes(s) {
    if (segmenter) return Array.from(segmenter.segment(s), (seg) => seg.segment);
    return Array.from(s);
  }

  /** Swift `Character.isLetter || Character.isNumber`, judged on the first scalar. */
  function isLetterOrNumber(ch) {
    return LETTER_OR_NUMBER.test(ch);
  }

  /** Code-point comparison after NFC, Swift's String `<` for these names. */
  function compareStrings(a, b) {
    const x = Array.from(a.normalize('NFC'));
    const y = Array.from(b.normalize('NFC'));
    const n = Math.min(x.length, y.length);
    for (let i = 0; i < n; i++) {
      const d = x[i].codePointAt(0) - y[i].codePointAt(0);
      if (d !== 0) return d < 0 ? -1 : 1;
    }
    return x.length === y.length ? 0 : x.length < y.length ? -1 : 1;
  }

  // MARK: - Title normalization (mirrors FranchiseChannelBuilder helpers)

  const YEAR_SUFFIX = / \(\p{N}\p{N}\p{N}\p{N}\)$/u;

  /** Lowercased, with any trailing " (YYYY)" dropped. Mirrors `normalizedTitle`. */
  function normalizedTitle(raw) {
    const s = String(raw == null ? '' : raw).toLowerCase();
    const m = YEAR_SUFFIX.exec(s);
    return m ? s.slice(0, s.length - m[0].length) : s;
  }

  /**
   * Key for EXACT title lists. Mirrors `explicitTitleKey`: normalizedTitle, then every
   * run of punctuation and whitespace collapsed to one space; apostrophes (straight or
   * curly) never split a word. "What If...?" and "What If" are one key.
   */
  function explicitTitleKey(raw) {
    let out = '';
    let pendingSpace = false;
    for (const ch of graphemes(normalizedTitle(raw))) {
      if (isLetterOrNumber(ch)) {
        if (pendingSpace && out.length > 0) out += ' ';
        pendingSpace = false;
        out += ch;
      } else if (ch === "'" || ch === '’') {
        continue;
      } else {
        pendingSpace = true;
      }
    }
    return out;
  }

  /**
   * Word-boundary containment, both inputs already lowercased. Mirrors
   * `titleContainsToken`: "star wars" matches "Star Wars Rebels", "men" does not
   * match "Mentalist".
   */
  function titleContainsToken(titleLower, tokenLower) {
    if (!tokenLower) return false;
    let from = 0;
    for (;;) {
      const at = titleLower.indexOf(tokenLower, from);
      if (at < 0) return false;
      const end = at + tokenLower.length;
      const prev = at === 0 ? null : lastGrapheme(titleLower.slice(0, at));
      const next = end >= titleLower.length ? null : graphemes(titleLower.slice(end))[0];
      const leftOK = prev === null || !isLetterOrNumber(prev);
      const rightOK = next === null || next === undefined || !isLetterOrNumber(next);
      if (leftOK && rightOK) return true;
      from = at + 1;
    }
  }

  function lastGrapheme(s) {
    const g = graphemes(s);
    return g.length ? g[g.length - 1] : null;
  }

  /** "John Wick Collection" -> "John Wick". Mirrors `FranchiseDictionary.cleanFranchiseName`. */
  function cleanFranchiseName(raw) {
    let name = String(raw == null ? '' : raw);
    const suffix = ' collection';
    if (name.toLowerCase().endsWith(suffix)) name = name.slice(0, name.length - suffix.length);
    return name.trim();
  }

  /**
   * "Spider-Man (MCU)" -> "Spider-Man". Drops trailing parenthetical suffixes, one or
   * more, never the whole name. Mirrors `FranchiseChannelBuilder.stripParentheticalSuffix`.
   */
  function stripParentheticalSuffix(raw) {
    let s = String(raw == null ? '' : raw).trim();
    while (s.endsWith(')')) {
      const open = s.lastIndexOf('(');
      if (open <= 0) break;
      s = s.slice(0, open).trim();
    }
    return s;
  }

  /**
   * Found franchises with the same merge key are one channel. Mirrors
   * `FranchiseChannelBuilder.franchiseMergeKey`: drop " Collection" and any trailing
   * parenthetical ("(MCU)", "(Spin-off)", "(Reboot)"), compare by `explicitTitleKey`
   * (case and punctuation ignored), and ignore a leading "The".
   */
  function franchiseMergeKey(raw) {
    let key = explicitTitleKey(cleanFranchiseName(stripParentheticalSuffix(cleanFranchiseName(raw))));
    if (key.startsWith('the ')) key = key.slice(4);
    return key;
  }

  // MARK: - Dictionary

  function intOrNull(v) {
    if (typeof v === 'number' && Number.isInteger(v)) return v;
    if (typeof v === 'string' && /^-?\d+$/.test(v.trim())) return Number(v.trim());
    return null;
  }

  function stringList(v) {
    return Array.isArray(v) ? v.filter((s) => typeof s === 'string') : [];
  }

  /**
   * Accepts the franchises.json document or its `franchises` array and fills the same
   * defaults as the Swift decoder: lists empty, flags false, stockChannelID null.
   */
  function normalizeDefinitions(input) {
    const list = Array.isArray(input) ? input : input && Array.isArray(input.franchises) ? input.franchises : [];
    return list
      .filter((d) => d && typeof d.canonicalName === 'string')
      .map((d) => ({
        canonicalName: d.canonicalName,
        stockChannelID: intOrNull(d.stockChannelID),
        tmdbCollectionIDs: Array.isArray(d.tmdbCollectionIDs)
          ? d.tmdbCollectionIDs.map(intOrNull).filter((n) => n !== null)
          : [],
        nameMatchTokens: stringList(d.nameMatchTokens),
        tvShowTitles: stringList(d.tvShowTitles),
        filmTitles: stringList(d.filmTitles),
        studioRuled: d.studioRuled === true,
        defaultOn: d.defaultOn === true,
      }));
  }

  function definitionStableID(def) {
    return 'dict:' + def.canonicalName;
  }

  /** Stable ids of the franchises that start switched on. Mirrors `defaultOnIDs`. */
  function defaultOnIDs(definitions) {
    return new Set(normalizeDefinitions(definitions).filter((d) => d.defaultOn).map(definitionStableID));
  }

  /** Mirrors `FranchiseDictionary.isOn`: an explicit choice wins, else the default. */
  function isOn(id, enabledIDs, disabledIDs, definitions) {
    if (enabledIDs && enabledIDs.has(id)) return true;
    if (disabledIDs && disabledIDs.has(id)) return false;
    return defaultOnIDs(definitions).has(id);
  }

  // The explicit lists as keys, worked out once per definition. A 40,000-episode library
  // asks the same question of every episode of a show, so this and the per-title memo in
  // `build` are what keep a rebuild off the main thread's critical path (measured 7.6 s
  // without them, 42,000 episodes). They only skip repeats; the answers are unchanged.
  const explicitKeyCache = new WeakMap();
  function explicitKeys(def, field) {
    let byField = explicitKeyCache.get(def);
    if (!byField) {
      byField = {};
      explicitKeyCache.set(def, byField);
    }
    if (!byField[field]) byField[field] = new Set(def[field].map(explicitTitleKey));
    return byField[field];
  }

  function collectionMap(definitions) {
    const map = new Map();
    for (const def of definitions) {
      if (def.studioRuled) continue;
      for (const id of def.tmdbCollectionIDs) map.set(id, def);
    }
    return map;
  }

  /**
   * Shared matcher for films and TV. Mirrors the private Swift `dictionaryMatch`: an
   * exact hit on the explicit list wins across every definition before any token is
   * tried. `includeStudioRuled` lets a studio-ruled franchise answer the exact pass
   * only (TV); its tokens are never tried.
   */
  function dictionaryMatchTitle(title, explicitField, definitions, includeStudioRuled) {
    const key = explicitTitleKey(title);
    for (const def of definitions) {
      if (!includeStudioRuled && def.studioRuled) continue;
      if (explicitKeys(def, explicitField).has(key)) return def;
    }
    const titleLower = normalizedTitle(title);
    for (const def of definitions) {
      if (def.studioRuled) continue;
      if (def.nameMatchTokens.some((tok) => titleContainsToken(titleLower, tok))) return def;
    }
    return null;
  }

  /** The dictionary franchise a film title belongs to, or null. Mirrors `dictionaryMatch(forFilmTitle:)`. */
  function dictionaryMatchForFilmTitle(title, definitions) {
    return dictionaryMatchTitle(title, 'filmTitles', normalizeDefinitions(definitions), false);
  }

  // MARK: - Enrichment

  /** Default lookup: `item.enrichment`, the shape the tuner's TMDB layer attaches. */
  function defaultEnrichmentFor(item) {
    return item && item.enrichment ? item.enrichment : null;
  }

  function readEnrichment(enrichmentFor, item) {
    const e = enrichmentFor(item);
    if (!e) return { fid: null, name: null };
    const name = typeof e.franchiseName === 'string' ? e.franchiseName : null;
    return { fid: intOrNull(e.franchiseID), name };
  }

  // MARK: - Build (mirrors FranchiseChannelBuilder.build)

  function build(opts) {
    const o = opts || {};
    const movies = Array.isArray(o.movies) ? o.movies : [];
    const tvItems = Array.isArray(o.tvItems) ? o.tvItems : [];
    const definitions = normalizeDefinitions(o.definitions);
    const enrichmentFor = typeof o.enrichmentFor === 'function' ? o.enrichmentFor : defaultEnrichmentFor;
    const available = new Set((o.availableStockChannelIDs || []).map(intOrNull).filter((n) => n !== null));
    const minimumFilms = Number.isInteger(o.minimumFilms) ? o.minimumFilms : DEFAULT_MINIMUM_FILMS;

    const byCollectionID = collectionMap(definitions);
    const buckets = new Map();
    const keyForDefinition = (def) => 'dict:' + def.canonicalName;
    const bucketFor = (key, name, def) => {
      let b = buckets.get(key);
      if (!b) {
        b = { name, definition: def, movies: [], tvItems: [], franchiseIDs: new Set() };
        buckets.set(key, b);
      }
      return b;
    };

    // 1. Movies, placed once each: dictionary by collection id, dictionary by title
    //    (explicit beats token), auto-found by collection id, otherwise skipped.
    //    Auto-found films are held back until every collection has a name, then go
    //    into one bucket per merge key (see franchiseMergeKey), in input order.
    const autoFoundNames = new Map();
    const autoFoundFilms = [];
    for (const movie of movies) {
      const { fid, name: rawName } = readEnrichment(enrichmentFor, movie);

      if (fid !== null && byCollectionID.has(fid)) {
        const def = byCollectionID.get(fid);
        const b = bucketFor(keyForDefinition(def), def.canonicalName, def);
        b.movies.push(movie);
        b.franchiseIDs.add(fid);
        continue;
      }

      const titleDef = dictionaryMatchTitle(movie.title, 'filmTitles', definitions, false);
      if (titleDef) {
        bucketFor(keyForDefinition(titleDef), titleDef.canonicalName, titleDef).movies.push(movie);
        continue;
      }

      if (fid !== null) {
        if (!autoFoundNames.has(fid) && rawName !== null) {
          autoFoundNames.set(fid, cleanFranchiseName(rawName).toUpperCase());
        }
        autoFoundFilms.push([movie, fid]);
      }
    }
    // A collection whose films never carried a franchiseName cannot be named, so it is
    // dropped. Named ones whose names match after franchiseMergeKey share one bucket:
    // "Spider-Man" + "Spider-Man (MCU)", "American Pie" + "American Pie (Spin-off)".
    const foundKeyFor = (fid) => {
      const name = autoFoundNames.get(fid);
      if (!name) return null;
      const mk = franchiseMergeKey(name);
      return mk ? 'found:' + mk : 'found:#' + fid;
    };
    for (const [movie, fid] of autoFoundFilms) {
      const key = foundKeyFor(fid);
      if (key === null) continue;
      const b = bucketFor(key, '', null);
      b.movies.push(movie);
      b.franchiseIDs.add(fid);
    }
    // Named after the lowest collection id; a merged bucket drops its "(MCU)" suffix.
    for (const b of buckets.values()) {
      if (b.definition !== null) continue;
      const ids = Array.from(b.franchiseIDs);
      const name = autoFoundNames.get(Math.min(...ids));
      b.name = ids.length > 1 ? stripParentheticalSuffix(name) : name;
    }

    // Found buckets in ascending collection id, the fixed order TV tries them in.
    const foundKeys = Array.from(buckets)
      .filter(([, b]) => b.definition === null)
      .map(([key, b]) => [key, Math.min(...b.franchiseIDs)])
      .sort((a, b) => a[1] - b[1])
      .map(([key]) => key);

    // 2. TV: dictionary (explicit titles, studio-ruled included, then tokens), else
    //    a found franchise whose name the show title contains.
    //    The answer depends on the title alone, so an episode takes the answer its show's
    //    first episode got (a Map by title) and goes into the same bucket, in input order.
    const placeTV = new Map();
    const placeFor = (title) => {
      const def = dictionaryMatchTitle(title, 'tvShowTitles', definitions, true);
      if (def) return { def };
      const titleLower = normalizedTitle(title);
      for (const key of foundKeys) {
        const b = buckets.get(key);
        if (b && titleContainsToken(titleLower, b.name.toLowerCase())) return { found: b };
      }
      return null;
    };
    for (const tv of tvItems) {
      let place = placeTV.get(tv.title);
      if (place === undefined) {
        place = placeFor(tv.title);
        placeTV.set(tv.title, place);
      }
      if (!place) continue;
      if (place.def) bucketFor(keyForDefinition(place.def), place.def.canonicalName, place.def).tvItems.push(tv);
      else place.found.tvItems.push(tv);
    }

    // 3. Resolve: stock fold (needs one item, not gated on films) or dynamic (gated).
    const groupings = [];
    for (const b of buckets.values()) {
      const mergedFranchiseIDs = Array.from(b.franchiseIDs).sort((x, y) => x - y);
      const fromDictionary = b.definition !== null;
      const def = b.definition;
      if (def && def.stockChannelID !== null && available.has(def.stockChannelID)) {
        if (b.movies.length + b.tvItems.length < 1) continue;
        groupings.push(grouping(def.canonicalName, { type: 'stock', channelID: def.stockChannelID }, b, mergedFranchiseIDs, fromDictionary));
      } else {
        if (b.movies.length < minimumFilms) continue;
        groupings.push(grouping(b.name, { type: 'dynamic' }, b, mergedFranchiseIDs, fromDictionary));
      }
    }

    // Stock folds by channel, then dynamic by name, then stableID.
    return groupings.sort((a, b) => {
      const as = a.placement.type === 'stock';
      const bs = b.placement.type === 'stock';
      if (as && bs) return a.placement.channelID - b.placement.channelID;
      if (as !== bs) return as ? -1 : 1;
      return compareStrings(a.name, b.name) || compareStrings(a.stableID, b.stableID);
    });
  }

  function grouping(name, placement, bucket, mergedFranchiseIDs, fromDictionary) {
    return {
      name,
      // Mirrors FranchiseGrouping.stableID.
      stableID: fromDictionary ? 'dict:' + name : 'tmdb:' + (mergedFranchiseIDs.length ? mergedFranchiseIDs[0] : 0),
      placement,
      movies: bucket.movies.slice(),
      tvItems: bucket.tvItems.slice(),
      mergedFranchiseIDs,
      fromDictionary,
    };
  }

  /**
   * The stock channel a server collection maps to: the lowest stock channel id that
   * 2+ members reach through a dictionary collection id, or null. Mirrors
   * `FranchiseChannelBuilder.stockChannel(forCollectionItems:)`.
   */
  function stockChannelForCollectionItems(opts) {
    const o = opts || {};
    const items = Array.isArray(o.items) ? o.items : [];
    const definitions = normalizeDefinitions(o.definitions);
    const enrichmentFor = typeof o.enrichmentFor === 'function' ? o.enrichmentFor : defaultEnrichmentFor;
    const available = new Set((o.availableStockChannelIDs || []).map(intOrNull).filter((n) => n !== null));
    const byCollectionID = collectionMap(definitions);
    const hits = new Map();
    for (const item of items) {
      const { fid } = readEnrichment(enrichmentFor, item);
      if (fid === null) continue;
      const def = byCollectionID.get(fid);
      if (!def || def.stockChannelID === null || !available.has(def.stockChannelID)) continue;
      hits.set(def.stockChannelID, (hits.get(def.stockChannelID) || 0) + 1);
    }
    const qualifying = Array.from(hits).filter(([, n]) => n >= 2).map(([id]) => id);
    return qualifying.length ? Math.min(...qualifying) : null;
  }

  const api = {
    build,
    stockChannelForCollectionItems,
    normalizeDefinitions,
    dictionaryMatchForFilmTitle,
    defaultOnIDs,
    isOn,
    cleanFranchiseName,
    stripParentheticalSuffix,
    franchiseMergeKey,
    explicitTitleKey,
    normalizedTitle,
    titleContainsToken,
    DEFAULT_MINIMUM_FILMS,
  };

  global.NostalgexFranchiseBuilder = api;
  // Node (tests/devtools). The browser keeps loading this as a plain script.
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
