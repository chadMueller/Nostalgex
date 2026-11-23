// TMDB and OMDb enrichment for the web tuner: the same keywords, networks,
// production companies, franchise and IMDb rating/votes the Apple TV app reads, so
// enrichment-gated channels (TEEN MOVIES, MUSICALS, TRUE CRIME, SPY GAMES, BIOPICS,
// MIDNIGHT, TOON TOWN, FOREIGN FILMS, CULT CLASSICS, ...) fill on the web the way
// they do on tvOS.
//
// Mirrors Nostalgex/Nostalgex/Services/EnrichmentService.swift:
//   1. dedupe the library to one work item per TMDB id (first item's media type wins)
//   2. read the shared Supabase cache (`media_enrichments`) for those ids
//   3. fetch the misses from TMDB through the site relay (api/tmdb.js)
//   4. ask OMDb, through the same relay (`path=omdb/{imdbID}`), about the titles
//      that could land on an IMDb-gated channel: same media type plus one of that
//      channel's keywords or genres, at most 50 per load in random order, and none
//      at all until the next UTC midnight after OMDb says the day's quota is gone
//      (OMDBQuota.swift / OMDBGate)
//   5. upsert what was fetched back to Supabase with resolution=merge-duplicates
// and TMDBService.parseResponse / OMDBService.parseResponse for turning documents
// into a row.
//
// Two web-only additions:
//   - A per-browser cache in IndexedDB with a TTL, so a reload does not repeat the
//     Supabase read or the relay fetches.
//   - Only TMDB and IMDb ids leave the browser. No titles or server details. The
//     IMDb id comes from the shared row or the TMDB document, not the server. The
//     TMDB upsert carries the TMDB columns only, so it never touches OMDb columns
//     an Apple TV wrote; the OMDb upsert carries the OMDb columns only.
//
// Self-hosted (the Docker image, `<meta name="nostalgex-build" content="selfhost">`):
//   - the relay is https://www.nostalgex.app/api/tmdb, asked as
//     `X-Nostalgex-Client: selfhost`, which the relay accepts from any origin
//   - config.json, written by the container from NOSTALGEX_ENRICHMENT, decides
//     whether any of this runs. It has to say `"enrichment": true`; anything else,
//     including a missing or unreadable file, means no Supabase or relay request.
//
// A record is looked up by number AND type: `movie:603` and `tv:603` are two rows, because TMDB numbers
// films and shows separately and the shared table's key is (tmdb_id, media_type). The library item's own
// type picks the row (an episode is `tv`, anything else `movie`), and "cached" means a row of THAT type
// exists, so a show is never skipped because a film with the same number is stored.
//
// The attached record lives at `item.enrichment`, in the shape
// scripts/nostalgex-channel-filter.cjs `enrichedValue()` reads (camelCase, the
// Swift MediaEnrichment property names).
(function (global) {
  'use strict';

  const SUPABASE_CHUNK = 200;
  const RELAY_CONCURRENCY = 6;
  const CACHE_TTL_MS = 7 * 86400000;
  const MISS_TTL_MS = 86400000;
  const CLIENT_HEADER = 'X-Nostalgex-Client';
  const CLIENT_VALUE = 'web';
  const TMDB_COLUMNS = [
    'tmdb_id', 'media_type', 'keywords', 'networks', 'production_companies',
    'tmdb_genres', 'franchise_id', 'franchise_name', 'fetched_at',
  ];
  const DEFAULT_RELAY = 'https://nostalgex.app/api/tmdb';
  // The apex answers with a redirect, and a CORS preflight cannot follow one.
  const SELFHOST_RELAY = 'https://www.nostalgex.app/api/tmdb';
  const SELFHOST_CLIENT_VALUE = 'selfhost';
  const OMDB_PER_LOAD = 50;
  const OMDB_CONCURRENCY = 4;
  const OMDB_COLUMNS = [
    'tmdb_id', 'media_type', 'imdb_id', 'imdb_rating', 'imdb_votes', 'rt_score',
    'metacritic_score', 'awards',
  ];
  const OMDB_BLOCK_KEY = 'nostalgex_omdb_blocked_until';
  const IMDB_ID = /^tt\d{7,9}$/;

  /** The key of a record, a cache row and a lookup: `${media_type}:${tmdb_id}`. */
  function recordKey(mediaType, tmdbID) { return `${mediaType === 'tv' ? 'tv' : 'movie'}:${tmdbID}`; }
  /** The type a library item asks for: an episode is a show, anything else a film. */
  function itemMediaType(item) { return item && item.type === 'episode' ? 'tv' : 'movie'; }

  // ── Pure: shapes ───────────────────────────────────────────────────────────

  function names(list) {
    if (!Array.isArray(list)) return [];
    return list.map((x) => (x && typeof x.name === 'string' ? x.name : null)).filter((x) => x != null);
  }

  /**
   * TMDBService.parseResponse. Movies carry keywords under `keywords.keywords`,
   * TV under `keywords.results`. Franchise comes from `belongs_to_collection`
   * (movies only). A movie document's `imdb_id` stands in when no IMDb id was
   * passed. OMDb fields stay null; OMDb is asked separately.
   */
  function parseTMDBResponse(json, tmdbID, imdbID, mediaType, now = new Date()) {
    const doc = json && typeof json === 'object' ? json : {};
    const kwObj = doc.keywords && typeof doc.keywords === 'object' ? doc.keywords : null;
    const kwKey = mediaType === 'tv' ? 'results' : 'keywords';
    const collection = doc.belongs_to_collection && typeof doc.belongs_to_collection === 'object'
      ? doc.belongs_to_collection : null;
    const franchiseID = collection && Number.isInteger(collection.id) ? collection.id : null;
    const franchiseName = collection && typeof collection.name === 'string' ? collection.name : null;
    return {
      tmdbID: String(tmdbID),
      imdbID: imdbID ?? (typeof doc.imdb_id === 'string' && IMDB_ID.test(doc.imdb_id) ? doc.imdb_id : null),
      mediaType,
      keywords: kwObj ? names(kwObj[kwKey]) : [],
      networks: names(doc.networks),
      productionCompanies: names(doc.production_companies),
      tmdbGenres: names(doc.genres),
      imdbRating: null,
      imdbVotes: null,
      rottenTomatoesScore: null,
      metacriticScore: null,
      awards: null,
      franchiseID,
      franchiseName,
      fetchedAt: now.toISOString(),
    };
  }

  function stringList(v) {
    return Array.isArray(v) ? v.filter((x) => typeof x === 'string') : [];
  }
  function numOrNull(v) {
    return typeof v === 'number' && Number.isFinite(v) ? v : null;
  }

  /** A Supabase row -> the attached record. Mirrors MediaEnrichment's resilient decoder. */
  function fromSupabaseRow(row) {
    if (!row || row.tmdb_id == null || typeof row.media_type !== 'string') return null;
    return {
      tmdbID: String(row.tmdb_id),
      imdbID: typeof row.imdb_id === 'string' ? row.imdb_id : null,
      mediaType: row.media_type,
      keywords: stringList(row.keywords),
      networks: stringList(row.networks),
      productionCompanies: stringList(row.production_companies),
      tmdbGenres: stringList(row.tmdb_genres),
      imdbRating: numOrNull(row.imdb_rating),
      imdbVotes: numOrNull(row.imdb_votes),
      rottenTomatoesScore: numOrNull(row.rt_score),
      metacriticScore: numOrNull(row.metacritic_score),
      awards: typeof row.awards === 'string' ? row.awards : null,
      franchiseID: numOrNull(row.franchise_id),
      franchiseName: typeof row.franchise_name === 'string' ? row.franchise_name : null,
      fetchedAt: typeof row.fetched_at === 'string' ? row.fetched_at : new Date().toISOString(),
    };
  }

  /** The upsert body for one record: TMDB columns only (see TMDB_COLUMNS). */
  function toSupabaseRow(e) {
    return {
      tmdb_id: e.tmdbID,
      media_type: e.mediaType,
      keywords: e.keywords,
      networks: e.networks,
      production_companies: e.productionCompanies,
      tmdb_genres: e.tmdbGenres,
      franchise_id: e.franchiseID,
      franchise_name: e.franchiseName,
      fetched_at: e.fetchedAt,
    };
  }

  /** The OMDb upsert body: OMDb columns plus the key (see OMDB_COLUMNS). */
  function toOMDbRow(e) {
    return {
      tmdb_id: e.tmdbID,
      media_type: e.mediaType,
      imdb_id: e.imdbID,
      imdb_rating: e.imdbRating,
      imdb_votes: e.imdbVotes,
      rt_score: e.rottenTomatoesScore,
      metacritic_score: e.metacriticScore,
      awards: e.awards,
    };
  }

  // ── Pure: OMDb ─────────────────────────────────────────────────────────────

  function omdbValue(v) {
    return typeof v === 'string' && v !== 'N/A' ? v : null;
  }

  /**
   * OMDBService.parseResponse. Null for `{"Response":"False"}` (unknown id, or the
   * daily-limit error when it arrives without the relay's 429).
   */
  function parseOMDbResponse(json) {
    if (!json || typeof json !== 'object' || json.Response === 'False') return null;
    const rating = omdbValue(json.imdbRating);
    const votes = omdbValue(json.imdbVotes);
    const meta = omdbValue(json.Metascore);
    let rt = null;
    for (const r of Array.isArray(json.Ratings) ? json.Ratings : []) {
      if (r && r.Source === 'Rotten Tomatoes' && typeof r.Value === 'string') {
        const n = parseInt(r.Value.replace('%', ''), 10);
        rt = Number.isFinite(n) ? n : null;
        break;
      }
    }
    const num = (s, f) => { if (s == null) return null; const n = f(s); return Number.isFinite(n) ? n : null; };
    return {
      imdbRating: num(rating, Number),
      imdbVotes: num(votes, (x) => Number(x.replace(/,/g, ''))),
      rottenTomatoesScore: rt,
      metacriticScore: num(meta, Number),
      awards: omdbValue(json.Awards),
    };
  }

  function isOMDbLimit(json) {
    return Boolean(json && typeof json.Error === 'string' && json.Error.toLowerCase().includes('limit reached'));
  }

  /** MediaEnrichment.merging(omdb:). */
  function mergeOMDb(record, omdb, imdbID) {
    return { ...record, imdbID: record.imdbID ?? imdbID, ...omdb };
  }

  function needsOMDb(rules) {
    if (!rules) return false;
    return typeof rules.imdbRatingMin === 'number' || typeof rules.imdbVotesMin === 'number'
      || typeof rules.rtScoreMin === 'number' || typeof rules.metacriticMin === 'number'
      || rules.wonOscar === true;
  }

  /** OMDBGate.gates(from:): one gate per channel with an OMDb rule. */
  function omdbGates(channels) {
    const out = [];
    for (const ch of channels || []) {
      const r = ch && ch.rules;
      if (!needsOMDb(r)) continue;
      const lower = (list) => (Array.isArray(list) ? list : []).filter((x) => typeof x === 'string').map((x) => x.toLowerCase());
      out.push({
        mediaType: r.type === 'movie' ? 'movie' : r.type === 'episode' ? 'tv' : null,
        keywords: new Set([...lower(r.keywords), ...lower(r.keywordsRequireAll)]),
        genres: lower(r.genres && r.genres.include),
      });
    }
    return out;
  }

  /** OMDBQuota.isCandidate: any gate admits the media type plus a keyword or genre. */
  function isOMDbCandidate(mediaType, keywords, genres, gates) {
    const kw = (keywords || []).map((k) => String(k).toLowerCase());
    const gs = (genres || []).map((g) => String(g).toLowerCase());
    return (gates || []).some((gate) => {
      if (gate.mediaType && gate.mediaType !== mediaType) return false;
      if (!gate.keywords.size && !gate.genres.length) return true;
      if (kw.some((k) => gate.keywords.has(k))) return true;
      return gate.genres.some((g) => gs.some((x) => x.includes(g)));
    });
  }

  /** Server genres per record key (type and TMDB id), merged across the key's items. */
  function genresByTMDB(items) {
    const out = new Map();
    for (const item of items || []) {
      if (!item || item.tmdbID == null) continue;
      const id = recordKey(itemMediaType(item), item.tmdbID);
      const set = out.get(id) || new Set();
      for (const g of Array.isArray(item.genres) ? item.genres : []) set.add(g);
      out.set(id, set);
    }
    return out;
  }

  /** EnrichmentService.omdbCandidates: unrated row, valid IMDb id, admitted by a gate. */
  function omdbCandidates(work, records, genresByID, gates) {
    if (!gates || !gates.length) return [];
    const out = [];
    for (const w of work) {
      const key = recordKey(w.mediaType, w.tmdbID);
      const e = records.get(key);
      if (!e || e.imdbRating != null) continue;
      if (typeof e.imdbID !== 'string' || !IMDB_ID.test(e.imdbID)) continue;
      const genres = [...(e.tmdbGenres || []), ...((genresByID && genresByID.get(key)) || [])];
      if (!isOMDbCandidate(e.mediaType, e.keywords, genres, gates)) continue;
      out.push({ tmdbID: w.tmdbID, imdbID: e.imdbID, record: e });
    }
    return out;
  }

  /** OMDBQuota.pick: at most `limit`, in random order (Fisher-Yates on a copy). */
  function pickOMDbLookups(list, limit = OMDB_PER_LOAD, random = Math.random) {
    const a = list.slice();
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(random() * (i + 1));
      [a[i], a[j]] = [a[j], a[i]];
    }
    return a.slice(0, Math.max(0, limit));
  }

  /** OMDb's daily quota resets at midnight UTC. */
  function nextUTCMidnight(ms) {
    const d = new Date(ms);
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
  }

  /**
   * OMDBBackoff: after a daily-limit answer this browser stops asking OMDb until the
   * next UTC midnight. `storage` is localStorage-shaped; it falls back to memory when
   * storage is missing or throws.
   */
  function omdbBackoff(storage) {
    let memory = 0;
    const read = () => {
      try {
        const v = storage ? Number(storage.getItem(OMDB_BLOCK_KEY)) : memory;
        return Number.isFinite(v) ? v : 0;
      } catch (err) { return memory; }
    };
    return {
      blockedUntil: read,
      isBlocked(nowMs) { return nowMs < read(); },
      mark(nowMs) {
        memory = nextUTCMidnight(nowMs);
        try { if (storage) storage.setItem(OMDB_BLOCK_KEY, String(memory)); } catch (err) { /* memory only */ }
      },
    };
  }

  function defaultStorage() {
    try { return global.localStorage || null; } catch (err) { return null; }
  }

  /** One work item per TMDB number and type. Episodes are tv, everything else movie. A film and a show that
   *  share a number are two items: each is looked up, cached and fetched under its own type. */
  function workItems(items) {
    const byKey = new Map();
    for (const item of items || []) {
      if (!item || item.tmdbID == null || item.tmdbID === '') continue;
      const id = String(item.tmdbID);
      if (!/^\d{1,10}$/.test(id)) continue;
      const mediaType = itemMediaType(item);
      const key = recordKey(mediaType, id);
      if (!byKey.has(key)) byKey.set(key, { tmdbID: id, mediaType });
    }
    return [...byKey.values()];
  }

  function chunk(list, size) {
    const out = [];
    for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
    return out;
  }

  /** Sets `item.enrichment` on every item whose TMDB id has a record. Returns how many. */
  function attach(items, records) {
    let n = 0;
    for (const item of items || []) {
      if (!item || item.tmdbID == null) continue;
      const e = records.get(recordKey(itemMediaType(item), item.tmdbID));
      if (e) { item.enrichment = e; n++; }
    }
    return n;
  }

  async function mapWithConcurrency(list, limit, fn) {
    let next = 0;
    let active = 0;
    let peak = 0;
    async function worker() {
      while (next < list.length) {
        const i = next++;
        active++;
        if (active > peak) peak = active;
        try { await fn(list[i], i); } finally { active--; }
      }
    }
    const workers = [];
    for (let w = 0; w < Math.min(limit, list.length); w++) workers.push(worker());
    await Promise.all(workers);
    return peak;
  }

  // ── Network ────────────────────────────────────────────────────────────────

  function supabaseHeaders(anonKey) {
    return { apikey: anonKey, Authorization: `Bearer ${anonKey}`, 'Content-Type': 'application/json' };
  }

  /** SupabaseService.fetchEnrichments, in chunks of 200. A failed chunk is skipped, not fatal. `ids` are
   *  TMDB numbers; the table can answer two rows for one number (a film and a show), so the caller keeps
   *  the row whose type it asked for (`recordKey`). */
  async function readSupabase(ids, cfg, fetchImpl, onChunk) {
    const out = [];
    const chunks = chunk([...new Set(ids)], cfg.chunkSize || SUPABASE_CHUNK);
    for (let i = 0; i < chunks.length; i++) {
      const url = `${cfg.supabaseURL}/rest/v1/media_enrichments?tmdb_id=in.(${chunks[i].join(',')})&select=*`;
      try {
        const res = await fetchImpl(url, { headers: supabaseHeaders(cfg.anonKey) });
        if (res.status !== 200) {
          console.warn(`[Enrichment] Supabase read failed: HTTP ${res.status}`);
        } else {
          const rows = await res.json();
          for (const row of Array.isArray(rows) ? rows : []) {
            const e = fromSupabaseRow(row);
            if (e) out.push(e);
          }
        }
      } catch (err) {
        console.warn('[Enrichment] Supabase read failed:', err && err.message);
      }
      if (onChunk) onChunk(i + 1, chunks.length);
    }
    return out;
  }

  /**
   * SupabaseService.upsertEnrichments: chunks of 200, Prefer: resolution=merge-duplicates.
   * `columns` pins what the write may touch: the TMDB set by default, the OMDb set for
   * the OMDb pass.
   */
  async function upsertSupabase(records, cfg, fetchImpl, columns = TMDB_COLUMNS, toRow = toSupabaseRow) {
    let written = 0;
    const url = `${cfg.supabaseURL}/rest/v1/media_enrichments?columns=${columns.join(',')}`;
    for (const part of chunk(records, cfg.chunkSize || SUPABASE_CHUNK)) {
      try {
        const res = await fetchImpl(url, {
          method: 'POST',
          headers: { ...supabaseHeaders(cfg.anonKey), Prefer: 'resolution=merge-duplicates,return=minimal' },
          body: JSON.stringify(part.map(toRow)),
        });
        if (res.status >= 300) console.warn(`[Enrichment] Supabase upsert failed: HTTP ${res.status}`);
        else written += part.length;
      } catch (err) {
        console.warn('[Enrichment] Supabase upsert failed:', err && err.message);
      }
    }
    return written;
  }

  /** One TMDB document through the relay. Returns { status, json }; network errors are status 0. */
  async function fetchRelay(work, cfg, fetchImpl) {
    const kind = work.mediaType === 'tv' ? 'tv' : 'movie';
    const url = `${cfg.relayURL}?path=${kind}/${work.tmdbID}`;
    try {
      const res = await fetchImpl(url, { headers: { Accept: 'application/json', [CLIENT_HEADER]: cfg.clientValue || CLIENT_VALUE } });
      if (res.status !== 200) return { status: res.status, json: null };
      return { status: 200, json: await res.json() };
    } catch (err) {
      return { status: 0, json: null };
    }
  }

  /** One OMDb answer through the relay. Returns { status, json }; network errors are status 0. */
  async function fetchOMDb(imdbID, cfg, fetchImpl) {
    if (!IMDB_ID.test(String(imdbID))) return { status: 400, json: null };
    const url = `${cfg.relayURL}?path=omdb/${imdbID}`;
    try {
      const res = await fetchImpl(url, { headers: { Accept: 'application/json', [CLIENT_HEADER]: cfg.clientValue || CLIENT_VALUE } });
      let json = null;
      try { json = await res.json(); } catch (err) { json = null; }
      return { status: res.status, json };
    } catch (err) {
      return { status: 0, json: null };
    }
  }

  // ── Local cache (IndexedDB) ────────────────────────────────────────────────
  // Rows: { key (`movie:603`), tmdbID, savedAt, record | null }. A null record is a TMDB 404, kept for
  // MISS_TTL_MS so a title TMDB does not know is not asked for on every reload.

  function indexedDBCache(dbName = 'nostalgex-enrichment', storeName = 'rows') {
    let dbPromise = null;
    function open() {
      if (dbPromise) return dbPromise;
      dbPromise = new Promise((resolve, reject) => {
        try {
          // Version 2: rows are keyed by type and number. The first version keyed them by number alone, so a
          // film's row could stand in for a show's; those rows are dropped and read again from the shared cache.
          const req = global.indexedDB.open(dbName, 2);
          req.onupgradeneeded = () => {
            const db = req.result;
            if (db.objectStoreNames.contains(storeName)) db.deleteObjectStore(storeName);
            db.createObjectStore(storeName, { keyPath: 'key' });
          };
          req.onsuccess = () => resolve(req.result);
          req.onerror = () => reject(req.error);
        } catch (err) { reject(err); }
      });
      return dbPromise;
    }
    return {
      async getMany(ids) {
        const out = new Map();
        try {
          const db = await open();
          await new Promise((resolve, reject) => {
            const tx = db.transaction(storeName, 'readonly');
            const store = tx.objectStore(storeName);
            for (const id of ids) {
              const r = store.get(id);
              r.onsuccess = () => { if (r.result) out.set(id, r.result); };
            }
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error);
          });
        } catch (err) {
          console.warn('[Enrichment] Local cache unavailable:', err && err.message);
        }
        return out;
      },
      async putMany(rows) {
        try {
          const db = await open();
          await new Promise((resolve, reject) => {
            const tx = db.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            for (const row of rows) store.put(row);
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error);
          });
        } catch (err) {
          console.warn('[Enrichment] Local cache write failed:', err && err.message);
        }
      },
    };
  }

  function memoryCache() {
    const m = new Map();
    return {
      rows: m,
      async getMany(ids) { const out = new Map(); for (const id of ids) if (m.has(id)) out.set(id, m.get(id)); return out; },
      async putMany(rows) { for (const r of rows) m.set(r.key, r); },
    };
  }

  // ── Config ─────────────────────────────────────────────────────────────────

  function metaContent(doc, name) {
    try {
      const el = doc && doc.querySelector(`meta[name="${name}"]`);
      const v = el ? String(el.getAttribute('content') || '').trim() : '';
      // An unset Vite env var leaves the %VITE_...% placeholder in the HTML.
      return v && !v.startsWith('%') ? v : '';
    } catch (err) {
      return '';
    }
  }

  /**
   * Supabase settings come from the build (Vite replaces %VITE_SUPABASE_URL% and
   * %VITE_SUPABASE_ANON_KEY% in plex-tuner.html). The relay is same-origin on the
   * site and its previews; on a local dev server it is nostalgex.app, unless
   * VITE_TMDB_RELAY_URL points somewhere else (a local relay harness).
   */
  function configFromPage(doc, loc) {
    const supabaseURL = metaContent(doc, 'nostalgex-supabase-url').replace(/\/+$/, '');
    const anonKey = metaContent(doc, 'nostalgex-supabase-anon-key');
    const relayOverride = metaContent(doc, 'nostalgex-tmdb-relay');
    if (metaContent(doc, 'nostalgex-build') === 'selfhost') {
      return {
        supabaseURL, anonKey,
        relayURL: relayOverride || SELFHOST_RELAY,
        clientValue: SELFHOST_CLIENT_VALUE,
        selfhost: true,
      };
    }
    const host = (loc && loc.hostname) || '';
    const isLocal = host === 'localhost' || host === '127.0.0.1' || host === '';
    const relayURL = relayOverride || (isLocal ? DEFAULT_RELAY : '/api/tmdb');
    return { supabaseURL, anonKey, relayURL };
  }

  /**
   * Self-host only: true when the container's config.json turns enrichment on.
   * Fails closed, so `NOSTALGEX_ENRICHMENT=off` holds even if the file cannot be read.
   */
  async function selfhostEnrichmentOn(fetchImpl) {
    try {
      const res = await fetchImpl('config.json', { cache: 'no-store' });
      if (!res || res.status !== 200) return false;
      const conf = await res.json();
      return !!conf && conf.enrichment === true;
    } catch (err) {
      return false;
    }
  }

  function missingConfiguration(cfg) {
    const missing = [];
    if (!cfg.relayURL) missing.push('tmdb relay');
    if (!cfg.supabaseURL) missing.push('supabase url');
    if (!cfg.anonKey) missing.push('anon key');
    return missing;
  }

  // ── Orchestration ──────────────────────────────────────────────────────────

  let loggedSkip = false;

  /**
   * Enrich `items` in place. Never throws. Calls `onCacheReady(records)` once the
   * local and Supabase caches have been read (before any relay fetch) when that
   * found anything, so the host can rebuild channels early, and resolves with the
   * full map when the relay fetches and the upsert are done.
   *
   * opts: { config, fetch, cache, now, concurrency, onProgress(done, total, phase),
   *         onCacheReady(records), isCancelled(),
   *         channels (for the OMDb gates; none means no OMDb lookups),
   *         omdbBackoff, omdbLimit, random }
   */
  async function enrichLibrary(items, opts = {}) {
    const cfg = opts.config || {};
    const stats = { ids: 0, local: 0, supabase: 0, fetched: 0, misses: 0, failed: 0, upserted: 0, peak: 0 };
    const omdb = { gates: 0, candidates: 0, asked: 0, fetched: 0, misses: 0, failed: 0, limited: false, paused: false, upserted: 0 };
    const records = new Map();
    const missing = missingConfiguration(cfg);
    if (missing.length) {
      if (!loggedSkip) {
        console.log(`[Enrichment] Off: missing ${missing.join(', ')}`);
        loggedSkip = true;
      }
      return { records, stats, omdb, skipped: true };
    }
    const fetchImpl = opts.fetch || global.fetch.bind(global);
    if (cfg.selfhost && !(await selfhostEnrichmentOn(fetchImpl))) {
      if (!loggedSkip) {
        console.log('[Enrichment] Off: config.json does not turn it on (NOSTALGEX_ENRICHMENT=off)');
        loggedSkip = true;
      }
      return { records, stats, omdb, skipped: true };
    }
    const cache = opts.cache || memoryCache();
    const nowMs = opts.now ? opts.now() : Date.now();
    const cancelled = opts.isCancelled || (() => false);
    const progress = opts.onProgress || (() => {});

    const work = workItems(items);
    stats.ids = work.length;
    if (!work.length) return { records, stats, omdb };

    // 1. Local cache.
    const keyOf = (w) => recordKey(w.mediaType, w.tmdbID);
    const local = await cache.getMany(work.map(keyOf));
    const needRemote = [];
    for (const w of work) {
      const row = local.get(keyOf(w));
      const ttl = row && row.record ? CACHE_TTL_MS : MISS_TTL_MS;
      if (row && nowMs - row.savedAt < ttl) {
        if (row.record) { records.set(keyOf(w), row.record); stats.local++; }
        else stats.misses++;
      } else {
        needRemote.push(w);
      }
    }

    // 2. Shared Supabase cache.
    const toStore = [];
    if (needRemote.length) {
      progress(0, needRemote.length, 'cache');
      const rows = await readSupabase(needRemote.map((w) => w.tmdbID), cfg, fetchImpl, (d, t) => {
        progress(d, t, 'cache');
      });
      const wanted = new Set(needRemote.map(keyOf));
      for (const e of rows) {
        const key = recordKey(e.mediaType, e.tmdbID);
        // The row of the type the library asked for. A film's row for a number a show asked for is not it.
        if (!wanted.has(key) || records.has(key)) continue;
        records.set(key, e);
        toStore.push({ key, tmdbID: e.tmdbID, savedAt: nowMs, record: e });
        stats.supabase++;
      }
    }
    if (toStore.length) await cache.putMany(toStore);
    attach(items, records);
    if (records.size && opts.onCacheReady && !cancelled()) opts.onCacheReady(records);

    // 3. Relay for whatever neither cache had.
    const toFetch = needRemote.filter((w) => !records.has(keyOf(w)));
    const fresh = [];
    const freshStore = [];
    if (toFetch.length && !cancelled()) {
      let done = 0;
      progress(0, toFetch.length, 'fetch');
      stats.peak = await mapWithConcurrency(toFetch, opts.concurrency || RELAY_CONCURRENCY, async (w) => {
        if (cancelled()) return;
        const { status, json } = await fetchRelay(w, cfg, fetchImpl);
        if (status === 200) {
          const e = parseTMDBResponse(json, w.tmdbID, null, w.mediaType, new Date(nowMs));
          records.set(keyOf(w), e);
          fresh.push(e);
          freshStore.push({ key: keyOf(w), tmdbID: w.tmdbID, savedAt: nowMs, record: e });
          stats.fetched++;
        } else if (status === 404) {
          freshStore.push({ key: keyOf(w), tmdbID: w.tmdbID, savedAt: nowMs, record: null });
          stats.misses++;
        } else {
          stats.failed++;
        }
        done++;
        if (done % 10 === 0 || done === toFetch.length) progress(done, toFetch.length, 'fetch');
      });
    }

    // 4. OMDb for the titles that could land on an IMDb-gated channel.
    const omdbFresh = [];
    const gates = omdbGates(opts.channels);
    omdb.gates = gates.length;
    if (gates.length && !cancelled()) {
      const backoff = opts.omdbBackoff || omdbBackoff(defaultStorage());
      if (backoff.isBlocked(nowMs)) {
        omdb.paused = true;
      } else {
        const candidates = omdbCandidates(work, records, genresByTMDB(items), gates);
        omdb.candidates = candidates.length;
        const picked = pickOMDbLookups(candidates, opts.omdbLimit ?? OMDB_PER_LOAD, opts.random || Math.random);
        let stop = false;
        await mapWithConcurrency(picked, OMDB_CONCURRENCY, async (c) => {
          if (stop || cancelled()) return;
          omdb.asked++;
          const { status, json } = await fetchOMDb(c.imdbID, cfg, fetchImpl);
          if (status === 429 || isOMDbLimit(json)) {
            stop = true;
            omdb.limited = true;
            backoff.mark(nowMs);
            return;
          }
          if (status !== 200) {
            omdb.failed++;
            // Bad key or relay down: stop for this load, as the app does.
            if (status === 401 || status === 403 || status >= 500) stop = true;
            return;
          }
          const parsed = parseOMDbResponse(json);
          if (!parsed) { omdb.misses++; return; }
          const merged = mergeOMDb(c.record, parsed, c.imdbID);
          records.set(recordKey(merged.mediaType, c.tmdbID), merged);
          omdbFresh.push(merged);
          freshStore.push({ key: recordKey(merged.mediaType, c.tmdbID), tmdbID: c.tmdbID, savedAt: nowMs, record: merged });
          omdb.fetched++;
        });
      }
    }

    // 5. Save what this browser fetched, locally and to the shared cache.
    if (freshStore.length) await cache.putMany(freshStore);
    if (fresh.length) stats.upserted = await upsertSupabase(fresh, cfg, fetchImpl);
    if (omdbFresh.length) omdb.upserted = await upsertSupabase(omdbFresh, cfg, fetchImpl, OMDB_COLUMNS, toOMDbRow);
    attach(items, records);
    console.log(`[Enrichment] ${stats.ids} TMDB ids: ${stats.local} local, ${stats.supabase} Supabase, `
      + `${stats.fetched} fetched, ${stats.misses} not on TMDB, ${stats.failed} failed, ${stats.upserted} saved`);
    if (omdb.gates) {
      console.log(omdb.paused
        ? '[Enrichment] OMDb paused until UTC midnight (daily limit)'
        : `[Enrichment] OMDb: ${omdb.gates} gated channels, ${omdb.candidates} candidates, ${omdb.asked} asked, `
          + `${omdb.fetched} found, ${omdb.misses} unknown, ${omdb.failed} failed, ${omdb.upserted} saved`
          + (omdb.limited ? ', daily limit hit' : ''));
    }
    return { records, stats, omdb };
  }

  const api = {
    recordKey,
    itemMediaType,
    SUPABASE_CHUNK,
    RELAY_CONCURRENCY,
    CACHE_TTL_MS,
    MISS_TTL_MS,
    TMDB_COLUMNS,
    OMDB_COLUMNS,
    OMDB_PER_LOAD,
    OMDB_CONCURRENCY,
    OMDB_BLOCK_KEY,
    parseTMDBResponse,
    parseOMDbResponse,
    isOMDbLimit,
    mergeOMDb,
    omdbGates,
    isOMDbCandidate,
    genresByTMDB,
    omdbCandidates,
    pickOMDbLookups,
    nextUTCMidnight,
    omdbBackoff,
    toOMDbRow,
    fetchOMDb,
    fromSupabaseRow,
    toSupabaseRow,
    workItems,
    chunk,
    attach,
    mapWithConcurrency,
    readSupabase,
    upsertSupabase,
    fetchRelay,
    indexedDBCache,
    memoryCache,
    configFromPage,
    selfhostEnrichmentOn,
    missingConfiguration,
    enrichLibrary,
  };
  global.NostalgexEnrichment = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
