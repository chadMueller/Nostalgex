// The FRANCHISES package in a lineup: what the franchise builder found, which of it
// airs, how it joins the stock classics, which server collections are the same
// franchise and fold away, and where every franchise channel is numbered. The web port
// of the Apple TV's AppState+Franchises.swift (rebuildFoundFranchises, franchiseListRows,
// stockPools, applyFranchiseFolds), FranchiseCollectionFold.swift and the franchise half
// of AppState+Channels.swift (materializeDynamicChannels, applyBundleFilter).
//
// PARITY CONTRACT with tvOS and Roku
//   scripts/franchise-lineup-golden.json is read by FranchiseLineupGoldenTests (Swift),
//   `npm run test:franchise-lineup` (this engine) and the Roku vectors (a byte copy,
//   roku/tests/CollectionTests.brs). Each builds the same library, the same franchise
//   choices and the same server collections and must give the same rows, folds,
//   channels and numbers. Change a rule in one without the others and one fails.
//
// What this module does not do: grouping (nostalgex-franchise-builder.js), classifying a
// collection and numbering the channels (nostalgex-collections.js `classify`,
// `materialize`). It puts them together in the order the Apple TV does:
//   1. the builder groups the library into franchises (found);
//   2. while the package is on, what a classic covers joins that classic's pool;
//   3. the server's collections are classified and folded against the classics and the
//      found franchises that are left;
//   4. the found franchises and the franchise collections that are on share CH 310-399.
//
// USAGE (browser: plain <script> after nostalgex-franchise-builder.js, nostalgex-collections.js
// and nostalgex-channel-filter.cjs; node: import them first, then this):
//
//   const FL = globalThis.NostalgexFranchiseLineup;
//   const result = FL.build({ ... });   // see `build`
(function (global) {
  'use strict';

  const FB = () => global.NostalgexFranchiseBuilder;
  const CL = () => global.NostalgexCollections;
  const CF = () => global.NostalgexChannelFilter;

  // ── Choices ────────────────────────────────────────────────────────────────

  /** `FranchiseDictionary.isOn(defaultOn:)`: an explicit choice wins, else the default. */
  function isOn(id, enabledIDs, disabledIDs, defaultOn) {
    if (enabledIDs && enabledIDs.has(id)) return true;
    if (disabledIDs && disabledIDs.has(id)) return false;
    return defaultOn === true;
  }

  /** A stock classic (ids 100-106, CH 300-306) is on unless the viewer switched it off. */
  function stockFranchiseOn(id, enabledIDs, disabledIDs) {
    return isOn(id, enabledIDs, disabledIDs, true);
  }

  function stockDefinitions(definitions) {
    const out = new Map();
    for (const def of FB().normalizeDefinitions(definitions)) {
      if (def.stockChannelID !== null) out.set(def.stockChannelID, def);
    }
    return out;
  }

  /** `switchedOffStockFranchiseChannelIDs`: the classics the viewer took out of the guide. */
  function switchedOffStockChannelIDs(definitions, enabledIDs, disabledIDs) {
    const out = new Set();
    for (const [channelID, def] of stockDefinitions(definitions)) {
      if (!stockFranchiseOn('dict:' + def.canonicalName, enabledIDs, disabledIDs)) out.add(channelID);
    }
    return out;
  }

  // ── Found franchises ───────────────────────────────────────────────────────

  function isCovered(f) {
    return f.coveredByChannelID !== null && f.coveredByChannelID !== undefined;
  }

  /**
   * `rebuildFoundFranchises`, after the builder: each grouping with the stock channel it
   * folds into (or null) and, for a dynamic one, whether it is on. A franchise a classic
   * covers has no switch of its own, so it is never "enabled".
   */
  function foundFromGroupings(groupings, enabledIDs, disabledIDs, definitions) {
    const fb = FB();
    return groupings.map((g) => {
      const covered = g.placement.type === 'stock' ? g.placement.channelID : null;
      return {
        id: g.stableID,
        name: g.name,
        movies: g.movies,
        tvItems: g.tvItems,
        coveredByChannelID: covered,
        fromDictionary: g.fromDictionary,
        enabled: covered === null && fb.isOn(g.stableID, enabledIDs, disabledIDs, definitions),
      };
    });
  }

  function showCount(items) {
    return new Set(items.map((it) => String(it.title))).size;
  }

  function plural(n, one, many) {
    return `${n} ${n === 1 ? one : many}`;
  }

  /** `FoundFranchise.countLabel` and `FranchiseListRow.countLabel(movies:shows:)`. */
  function countLabel(movies, shows, emptyLabel) {
    const parts = [];
    if (movies > 0) parts.push(plural(movies, 'movie', 'movies'));
    if (shows > 0) parts.push(plural(shows, 'show', 'shows'));
    return parts.length ? parts.join(', ') : emptyLabel;
  }

  // ── Settings rows ──────────────────────────────────────────────────────────

  /** Case-insensitive, digit runs compared as numbers: Swift's localizedStandardCompare for these names. */
  function naturalCompare(a, b) {
    const x = String(a).toLowerCase();
    const y = String(b).toLowerCase();
    const isDigit = (ch) => ch >= '0' && ch <= '9';
    let i = 0;
    let j = 0;
    while (i < x.length && j < y.length) {
      if (isDigit(x[i]) && isDigit(y[j])) {
        const si = i;
        while (i < x.length && isDigit(x[i])) i++;
        const sj = j;
        while (j < y.length && isDigit(y[j])) j++;
        const nx = Number(x.slice(si, i));
        const ny = Number(y.slice(sj, j));
        if (nx !== ny) return nx < ny ? -1 : 1;
      } else {
        if (x[i] !== y[j]) return x[i] < y[j] ? -1 : 1;
        i++;
        j++;
      }
    }
    const left = x.length - i;
    const right = y.length - j;
    return left === right ? 0 : left < right ? -1 : 1;
  }

  /**
   * `franchiseListRows`: every classic in the package and every found franchise no
   * classic covers, alphabetical, each with its own switch. A classic counts its
   * channel's pool, less the films a non-stock dictionary franchise owns (Spider-Man's
   * MCU films also pass MARVEL's studio rule): they are counted once, on their own row.
   *
   * stockChannels: [{ id, number, itemPool }] the classics in the lineup.
   * Rows: { id, name, countLabel, stockChannelID, channelNumber, enabled }.
   */
  function listRows({ definitions, bundleChannelIDs, stockChannels, found, enabledIDs, disabledIDs, itemKey }) {
    const claimed = new Set();
    for (const f of found) {
      if (f.fromDictionary && !isCovered(f)) {
        for (const it of f.movies) claimed.add(itemKey(it));
        for (const it of f.tvItems) claimed.add(itemKey(it));
      }
    }
    const byStock = stockDefinitions(definitions);
    const rows = [];
    const seen = new Set();
    for (const channelID of bundleChannelIDs) {
      const def = byStock.get(channelID);
      if (!def) continue;
      const channel = stockChannels.find((c) => c.id === channelID);
      const pool = ((channel && channel.itemPool) || []).filter((it) => !claimed.has(itemKey(it)));
      const movies = pool.filter((it) => it.type === 'movie').length;
      const shows = showCount(pool.filter((it) => it.type === 'episode'));
      const id = 'dict:' + def.canonicalName;
      rows.push({
        id,
        name: def.canonicalName,
        countLabel: countLabel(movies, shows, 'None in your library yet'),
        stockChannelID: channelID,
        channelNumber: channel && channel.number != null ? channel.number : channelID,
        enabled: stockFranchiseOn(id, enabledIDs, disabledIDs),
      });
      seen.add(id);
    }
    for (const f of found) {
      if (isCovered(f) || seen.has(f.id)) continue;
      rows.push({
        id: f.id,
        name: f.name,
        countLabel: countLabel(f.movies.length, showCount(f.tvItems), ''),
        stockChannelID: null,
        channelNumber: null,
        enabled: f.enabled,
      });
    }
    return rows.sort((a, b) => naturalCompare(a.name, b.name) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  }

  // ── Stock pools ────────────────────────────────────────────────────────────

  function plexGenres(item) {
    return (item.genres || []).map((g) => String(g).toLowerCase());
  }

  /**
   * `isLockedElsewhere`: true when `item` belongs to a channel other than `channelID` by a
   * manifest lock or an exclusive rule. The same two locks the channel filter honours.
   */
  function isLockedElsewhere(item, channelID, manifest, exclusiveRules) {
    const filter = CF();
    const mediaType = item.type === 'episode' ? 'tv' : 'movie';
    const entry = item.tmdbID && manifest && manifest.items ? manifest.items[`${mediaType}:${item.tmdbID}`] : null;
    if (entry && entry.exclusive != null && entry.exclusive !== channelID) return true;
    for (const rule of exclusiveRules || []) {
      const ids = rule.channelIDs || (rule.channelID != null ? [rule.channelID] : []);
      if (ids.includes(channelID)) continue;
      if (!filter.exclusiveRuleApplies(item, rule)) continue;
      if (filter.exclusiveRuleMatches(item, plexGenres(item), rule)) return true;
      if (rule.manifestExclusive && entry && (entry.channels || []).some((c) => ids.includes(c))) return true;
    }
    return false;
  }

  /**
   * `stockPools`: what each covered franchise adds to its classic's pool. A classic's pool
   * is what its channels.json rule passes UNION the items the builder placed on it:
   * six of the seven rules say `type: movie`, so without this The Mandalorian would be
   * labelled "on CH 300" in Settings and never air there. Items already in the pool are
   * skipped, and so is anything another channel owns (a manifest lock or an exclusive
   * rule that does not list this channel), the same two locks the filter honours.
   *
   * Returns Map(channelID -> items to append, in order). Only classics in `stockChannels`.
   */
  function stockPoolAdditions(found, stockChannels, { itemKey, manifest, exclusiveRules }) {
    const extras = new Map();
    for (const f of found) {
      if (!isCovered(f)) continue;
      if (!extras.has(f.coveredByChannelID)) extras.set(f.coveredByChannelID, []);
      extras.get(f.coveredByChannelID).push(...f.movies, ...f.tvItems);
    }
    const out = new Map();
    for (const channel of stockChannels) {
      const additions = extras.get(channel.id);
      if (!additions) continue;
      const seen = new Set((channel.itemPool || []).map(itemKey));
      const add = [];
      for (const item of additions) {
        const key = itemKey(item);
        if (seen.has(key)) continue;
        if (isLockedElsewhere(item, channel.id, manifest, exclusiveRules)) continue;
        add.push(item);
        seen.add(key);
      }
      if (add.length) out.set(channel.id, add);
    }
    return out;
  }

  // ── The fold (FranchiseCollectionFold.swift) ───────────────────────────────

  /**
   * The franchises a server collection can fold into: each classic in the lineup
   * (label "CH 300 STAR WARS", the pool it airs) and each found franchise no classic
   * covers (label its name, the items it holds). Classics first, in number order.
   */
  function foldTargets({ definitions, stockChannels, found, itemKey }) {
    const defs = FB().normalizeDefinitions(definitions);
    const targets = [];
    const ordered = stockChannels.slice().sort((a, b) => a.number - b.number);
    for (const ch of ordered) {
      const def = defs.find((d) => d.stockChannelID === ch.id);
      targets.push({
        label: `CH ${ch.number} ${ch.name}`,
        itemKeys: new Set((ch.itemPool || []).map(itemKey)),
        dictionaryName: def ? def.canonicalName : null,
        stockChannelID: ch.id,
      });
    }
    for (const f of found) {
      if (isCovered(f)) continue;
      targets.push({
        label: f.name,
        itemKeys: new Set([...f.movies, ...f.tvItems].map(itemKey)),
        dictionaryName: f.fromDictionary ? f.name : null,
        stockChannelID: null,
      });
    }
    return targets;
  }

  /**
   * A folded collection is hidden and never built, so folding is only safe when the
   * franchise already airs everything in it. A collection that holds shows folds only
   * into a franchise whose pool has at least one episode of each of them; a "Star Trek"
   * set of films and series must not vanish into a films-only STAR TREK.
   */
  function carriesEveryShow(collection, target, itemKey) {
    const covered = new Map();
    for (const it of collection.items) {
      if (!it || it.type !== 'episode') continue;
      const show = CL().showIdentity(it);
      if (covered.get(show) === true) continue;
      covered.set(show, target.itemKeys.has(itemKey(it)));
    }
    for (const ok of covered.values()) if (!ok) return false;
    return true;
  }

  function pickTarget(collection, targets, { definitions, enrichmentFor, itemKey, threshold }) {
    const stockByID = new Map();
    for (const t of targets) if (t.stockChannelID !== null) stockByID.set(t.stockChannelID, t);

    // 1. Dictionary truth from enrichment: 2+ members share a franchiseID that the
    //    dictionary maps to a stock channel present in the lineup.
    const sid = FB().stockChannelForCollectionItems({
      items: collection.items,
      definitions,
      enrichmentFor,
      availableStockChannelIDs: [...stockByID.keys()],
    });
    if (sid !== null && stockByID.has(sid)) return stockByID.get(sid);

    // 2. Dictionary by title: "Star Wars Collection" carries the "star wars" token.
    //    Folds into the stock channel when it exists, else into the found franchise
    //    the same dictionary entry produced.
    const def = FB().dictionaryMatchForFilmTitle(collection.title, definitions);
    if (def) {
      if (def.stockChannelID !== null && stockByID.has(def.stockChannelID)) return stockByID.get(def.stockChannelID);
      const named = targets.find((t) => t.dictionaryName === def.canonicalName);
      if (named) return named;
    }

    // 3. The scan's own duplicate signals, when they point at a stock franchise channel:
    //    a name match ("CH 301 MARVEL") or a manifest overlap on that channel.
    if (collection.matchedChannel) {
      const t = targets.find((x) => x.stockChannelID !== null && x.label === collection.matchedChannel);
      if (t) return t;
    }
    if (collection.contentOverlap && stockByID.has(collection.contentOverlap.channelID)) {
      return stockByID.get(collection.contentOverlap.channelID);
    }

    // 4. Plain item overlap: most of this collection is already in one franchise's pool.
    //    Catches an auto-found franchise whose server collection has a name TMDB would
    //    never guess.
    const total = collection.items.length;
    if (total === 0) return null;
    const keys = new Set(collection.items.map(itemKey));
    let best = null;
    for (const t of targets) {
      let count = 0;
      for (const k of keys) if (t.itemKeys.has(k)) count++;
      if (count > (best ? best.count : 0)) best = { target: t, count };
    }
    if (best && Math.round((best.count / total) * 100) >= threshold) return best.target;
    return null;
  }

  /**
   * `FranchiseCollectionFold.folds`, one collection at a time: the label of the
   * franchise a candidate is the same as, or null, for `buildCandidates` (ctx.fold).
   */
  function foldFor({ targets, definitions, enrichmentFor, itemKey, threshold = 60 }) {
    return (candidate) => {
      if (!targets.length) return null;
      const target = pickTarget(candidate, targets, { definitions, enrichmentFor, itemKey, threshold });
      return target && carriesEveryShow(candidate, target, itemKey) ? target.label : null;
    };
  }

  // ── The guide ──────────────────────────────────────────────────────────────

  /**
   * Whether a channel is in the guide, as far as the FRANCHISES package decides it.
   * `applyBundleFilter`: found franchises and the server's franchise collections are
   * runtime channels that belong to the stock package, so they show while it is on and all
   * go with it when it is off, and a classic switched off in the franchise list leaves
   * the guide on its own. Anything else is not this package's to decide.
   */
  function franchiseChannelVisible(channel, { packageOn, bundleChannelIDs, switchedOffStock }) {
    if (channel.stock) {
      if (!bundleChannelIDs.includes(channel.id)) return true;
      return packageOn && !switchedOffStock.has(channel.id);
    }
    if (channel.category === 'franchises') return packageOn;
    return true;
  }

  // ── Everything together ────────────────────────────────────────────────────

  /**
   * What the FRANCHISES package and the server collections add to a lineup.
   *
   * opts:
   *   definitions       franchises.json (document or array)
   *   packageOn         the FRANCHISES package switch
   *   enabledIDs, disabledIDs   Sets of the viewer's franchise choices (stable ids)
   *   items             the library's channel-eligible items, enrichment attached
   *   stockChannels     the classics in the lineup: [{ id, number, name, itemPool }]
   *   bundleChannelIDs  the package's channel ids (channels.json: 100-106)
   *   itemKey           an item's identity across the pools (default ratingKey)
   *   manifest, exclusiveRules   for the locks a classic's pool honours
   *   collections       { raw, indexByServer, staticChannels, channelsByID, enabledKeys }
   *                     as nostalgex-collections.js `buildCandidates`; optional
   *   enrichmentFor     default `item.enrichment`
   *
   * Returns { found, stockAdditions (Map), switchedOffStock (Set), rows, candidates,
   * channels, overCap, overCapFranchises, overCapCustom, overCapFound }. `rows` are the
   * Settings franchise list; `channels` every runtime channel in number order. The
   * caller appends `stockAdditions` to the classics' pools when `packageOn`.
   */
  function build(opts) {
    const fb = FB();
    const cl = CL();
    const itemKey = opts.itemKey || ((it) => String(it.ratingKey));
    const enrichmentFor = typeof opts.enrichmentFor === 'function' ? opts.enrichmentFor : undefined;
    const enabledIDs = opts.enabledIDs || new Set();
    const disabledIDs = opts.disabledIDs || new Set();
    const stockChannels = opts.stockChannels || [];
    const bundleChannelIDs = opts.bundleChannelIDs || [];
    const definitions = opts.definitions;
    const items = opts.items || [];

    // Music videos live in a movie-typed library and are never franchise films.
    const movies = items.filter((it) => it.type === 'movie' && (it.librarySource || 'movie') === 'movie');
    const tvItems = items.filter((it) => it.type === 'episode');
    const groupings = fb.build({
      movies,
      tvItems,
      definitions,
      enrichmentFor,
      availableStockChannelIDs: stockChannels.filter((c) => bundleChannelIDs.includes(c.id)).map((c) => c.id),
    });
    const found = foundFromGroupings(groupings, enabledIDs, disabledIDs, definitions);

    // The union is only made while the package is on. The fold then reads the pools as
    // they air, films and the shows the dictionary put on them.
    const stockAdditions = opts.packageOn
      ? stockPoolAdditions(found, stockChannels, { itemKey, manifest: opts.manifest, exclusiveRules: opts.exclusiveRules })
      : new Map();
    const unioned = stockChannels.map((c) => ({
      ...c,
      itemPool: stockAdditions.has(c.id) ? [...(c.itemPool || []), ...stockAdditions.get(c.id)] : c.itemPool || [],
    }));
    const franchiseStock = unioned.filter((c) => bundleChannelIDs.includes(c.id));

    const rows = listRows({
      definitions, bundleChannelIDs, stockChannels: unioned, found, enabledIDs, disabledIDs, itemKey,
    });
    const switchedOffStock = switchedOffStockChannelIDs(definitions, enabledIDs, disabledIDs);

    let candidates = [];
    const col = opts.collections;
    if (col) {
      const targets = foldTargets({ definitions, stockChannels: franchiseStock, found, itemKey });
      candidates = cl.buildCandidates(col.raw || [], col.indexByServer, {
        staticChannels: col.staticChannels,
        channelsByID: col.channelsByID,
        manifest: col.manifest !== undefined ? col.manifest : opts.manifest,
        enabledKeys: col.enabledKeys,
        itemKey,
        classify: true,
        enrichmentFor,
        fold: foldFor({ targets, definitions, enrichmentFor, itemKey }),
      });
    }

    const materialized = cl.materialize(candidates, {
      found: opts.packageOn ? found.filter((f) => !isCovered(f) && f.enabled) : [],
    });
    return {
      found,
      stockAdditions,
      switchedOffStock,
      rows,
      candidates,
      channels: materialized.channels,
      overCap: materialized.overCap,
      overCapFranchises: materialized.overCapFranchises,
      overCapCustom: materialized.overCapCustom,
      overCapFound: materialized.overCapFound,
    };
  }

  const api = {
    build,
    isOn,
    stockFranchiseOn,
    switchedOffStockChannelIDs,
    foundFromGroupings,
    listRows,
    countLabel,
    naturalCompare,
    isLockedElsewhere,
    stockPoolAdditions,
    foldTargets,
    foldFor,
    franchiseChannelVisible,
  };

  global.NostalgexFranchiseLineup = api;
  // Node (tests/devtools). The browser keeps loading this as a plain script.
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
