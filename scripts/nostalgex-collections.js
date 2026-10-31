// Server collections as channels on the web tuner, the way the Apple TV app does it
// (Nostalgex/Nostalgex/App/AppState+Channels.swift `scanCollections` and
// `materializeDynamicChannels`, Models/Channel.swift `CollectionCategory`).
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
//   order), and the switched-on ones get CH 450 upward, capped at 50 channels
//   (CH 450-499), ids from 1,020,000. Anything enabled past the cap is not built.
//   Until 1.0.29 this block was CH 500-699 with room for 200; HIGH ROTATION took 500.
//
// Duplicates of a stock channel are flagged the way the app's collections list
// does ("Exists: CH 12 ACTION", "78% already on CH 101 MARVEL"). A collection that
// IS a stock franchise channel (ids 100-106) is folded out of the list using the
// app's cheap signals: that name match, that manifest overlap, or 60%+ of its
// movies already in the franchise channel's pool. The app's franchise-dictionary
// signals are not ported here.
//
// Not ported: the app's FRANCHISES / OTHER COLLECTIONS split (CollectionClassifier)
// and found franchises. Every web collection channel sits in the OTHER COLLECTIONS
// range, CH 450-499.
(function (global) {
  'use strict';

  const ID_BASE = 1000000 + 2 * 10000;
  const NUMBER_BASE = 450;
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

  // ── Pure: candidates and channels ──────────────────────────────────────────

  /**
   * raw: [{ id, title, childKeys, serverKey }]. indexByServer: Map(serverKey -> index),
   * the index from indexLibrary, or a plain Map(ratingKey -> item) of films (the old
   * shape, still accepted). Returns candidates sorted the way the app lists them.
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
      candidate.foldedInto = foldTarget(candidate, franchiseChannels, itemKey);
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

  /**
   * Swift `materializeDynamicChannels` for one category: enabled, unfolded
   * candidates in list order take slots 0..199. Returns { channels, overCap }.
   */
  function materialize(candidates) {
    const channels = [];
    let overCap = 0;
    let slot = 0;
    for (const c of candidates) {
      if (!c.enabled || c.foldedInto) continue;
      if (slot >= CAPACITY) { overCap++; continue; }
      const color = COLORS[slot % COLORS.length];
      channels.push({
        id: ID_BASE + slot,
        number: NUMBER_BASE + slot,
        name: c.title,
        color,
        colorHex: color,
        category: 'custom',
        rules: null,
        timeRestrictions: null,
        minItems: MIN_ITEMS,
        stock: false,
        collection: true,
        collectionID: c.id,
        enabled: c.items.length >= MIN_ITEMS,
        schedule: [],
        itemPool: c.items.slice(),
      });
      slot++;
    }
    return { channels, overCap };
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
    ID_BASE,
    NUMBER_BASE,
    NUMBER_END,
    CAPACITY,
    MIN_MOVIES,
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
