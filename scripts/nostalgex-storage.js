// Browser storage for the web tuner and the Docker tuner: writes that cannot throw, small
// settings that outrank the caches, and the library cache in IndexedDB.
//
// WEB ONLY. Apple TV keeps its library cache on disk and Roku in its registry, so there is
// nothing here to port. Keep it out of the shared engine files the Roku app copies.
//
// Why this exists (issue #152): the library cache used to live in localStorage. A library of
// about 6,700 items serialised to nearly the whole 5 MB an origin gets, and the next write,
// the few hundred bytes of channel config, threw QuotaExceededError. That error came up
// through fetchPlexLibrary() and was shown as "your server may be unreachable", so someone
// debugging a healthy Plex server went and checked the network. Three rules came out of it:
//
//   1. A storage write never throws into the code that asked for it. set() returns false
//      and logs; the page keeps working from memory.
//   2. Small settings (channel config, sign-in, preferences) win over caches. When one of
//      them hits the quota, set() gives up regenerable data, least valuable first, and tries
//      again. A cache never evicts another cache.
//   3. The big cache is not in localStorage at all. IndexedDB has no 5 MB ceiling, and the
//      enrichment cache already uses it (scripts/nostalgex-enrichment.js).
//
// USAGE (browser: plain <script src="scripts/nostalgex-storage.js">,
// node: `import "./nostalgex-storage.js"`, then globalThis):
//
//   const S = window.NostalgexStorage;
//   S.setLocal('plex90_channel_config', json);        // true if saved
//   S.setSession('plex90_token', token);
//   await S.libraryCache.save({ v, ts, url, items }); // true if cached
//   const cached = await S.libraryCache.load();       // the payload, or null
//   S.libraryCache.clear();                           // sign-out: the marker goes at once

(function (global) {
  'use strict';

  const LEGACY_LIBRARY_KEY = 'plex90_library_cache';
  const LIBRARY_MARKER_KEY = 'plex90_library_cache_id';
  const LIBRARY_DB = 'nostalgex-library';
  const LIBRARY_STORE = 'cache';
  const LIBRARY_RECORD = 'library';
  // A cache that cannot be read quickly is not worth waiting for: the page rescans instead.
  const LOAD_TIMEOUT_MS = 5000;

  // Data the page can rebuild, in the order it is given up when a small setting has no room.
  // The library cache is not here as a live key: it moved to IndexedDB, and the old
  // localStorage copy is only ever removed (purgeLegacy). The other three are written by
  // plex-tuner.html (collection scan), nostalgex-music-brainz.js and nostalgex-daily-manifest.js.
  // scripts/nostalgex-storage-smoke.mjs checks that these still match what those files write.
  const EVICTABLE = [
    { key: LEGACY_LIBRARY_KEY },
    { key: 'nostalgex_collection_scan' },
    { key: 'nostalgex_music_video_enrichments_v1' },
    { prefix: 'plex90_manifest_' },
  ];

  function isEvictableKey(key) {
    return EVICTABLE.some((rule) => (rule.key ? rule.key === key : String(key).startsWith(rule.prefix)));
  }

  /** True for the error a full Storage throws, in Chrome, Firefox and old Safari. */
  function isQuotaError(err) {
    if (!err) return false;
    return err.name === 'QuotaExceededError'
      || err.name === 'NS_ERROR_DOM_QUOTA_REACHED'
      || err.code === 22
      || err.code === 1014;
  }

  const warned = new Set();
  function warnOnce(key, err) {
    if (warned.has(key)) return;
    warned.add(key);
    try {
      console.warn(`[Nostalgex] Could not save ${key} (${isQuotaError(err) ? 'browser storage is full' : 'browser storage is unavailable'}). `
        + 'It stays in memory for this visit.', err);
    } catch (_) { /* no console */ }
  }

  /** Removes every key a rule names. Returns how many it removed. */
  function evict(storage, rule, except) {
    const doomed = [];
    try {
      for (let i = 0; i < storage.length; i++) {
        const k = storage.key(i);
        if (k == null || k === except) continue;
        if (rule.key ? k === rule.key : k.startsWith(rule.prefix)) doomed.push(k);
      }
      doomed.forEach((k) => storage.removeItem(k));
    } catch (_) { /* nothing more to give up here */ }
    return doomed.length;
  }

  /**
   * Writes `value` under `key` and never throws. Returns true if it was saved.
   *
   * When the quota is hit, the data the page can rebuild is given up one kind at a time
   * (see EVICTABLE) and the write is tried again after each, so a small setting costs a
   * cache and not the other way round. A write to one of those caches never evicts another.
   */
  function set(storage, key, value) {
    const text = typeof value === 'string' ? value : String(value);
    let failure;
    try {
      storage.setItem(key, text);
      return true;
    } catch (err) {
      failure = err;
    }
    if (isQuotaError(failure) && !isEvictableKey(key)) {
      for (const rule of EVICTABLE) {
        if (!evict(storage, rule, key)) continue;
        try {
          storage.setItem(key, text);
          return true;
        } catch (err) {
          failure = err;
          if (!isQuotaError(err)) break;
        }
      }
    }
    warnOnce(key, failure);
    return false;
  }

  // `localStorage` itself throws in some browsers (cookies blocked), so it is read inside
  // the try, never passed in as an argument.
  function setLocal(key, value) {
    try { return set(global.localStorage, key, value); } catch (err) { warnOnce(key, err); return false; }
  }
  function setSession(key, value) {
    try { return set(global.sessionStorage, key, value); } catch (err) { warnOnce(key, err); return false; }
  }

  /** Drops the pre-IndexedDB library cache. Run once at start-up: it can hold the whole quota. */
  function purgeLegacy() {
    try { global.localStorage.removeItem(LEGACY_LIBRARY_KEY); } catch (_) { /* nothing to purge */ }
  }

  function newId() {
    return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  }

  /**
   * The library cache. The payload goes to IndexedDB as JSON text, serialised when save() is
   * called so the page can keep changing its items; a short id goes to localStorage next to
   * it. The record only counts while the id in localStorage matches the one inside it, so
   * clearing (sign-out) is one synchronous removeItem. A page that navigates away
   * before IndexedDB finishes its delete cannot leave a cache that loads: the Plex token
   * and the whole library of whoever signed out would otherwise be readable by the next
   * sign-in on the same server.
   */
  function createLibraryCache(env) {
    const idb = () => env.indexedDB;
    const local = () => env.localStorage;
    let dbPromise = null;

    function openDb() {
      if (dbPromise) return dbPromise;
      dbPromise = new Promise((resolve, reject) => {
        const factory = idb();
        if (!factory) { reject(new Error('IndexedDB is not available')); return; }
        let req;
        try { req = factory.open(LIBRARY_DB, 1); } catch (err) { reject(err); return; }
        req.onupgradeneeded = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains(LIBRARY_STORE)) db.createObjectStore(LIBRARY_STORE);
        };
        req.onsuccess = () => {
          const db = req.result;
          // Another tab upgrading, or the browser closing the connection: open again next time.
          db.onversionchange = () => { db.close(); dbPromise = null; };
          db.onclose = () => { dbPromise = null; };
          resolve(db);
        };
        req.onerror = () => reject(req.error || new Error('IndexedDB open failed'));
        req.onblocked = () => reject(new Error('IndexedDB open blocked'));
      });
      dbPromise.catch(() => { dbPromise = null; });
      return dbPromise;
    }

    function transact(mode, work) {
      return openDb().then((db) => new Promise((resolve, reject) => {
        const tx = db.transaction(LIBRARY_STORE, mode);
        let result;
        try { result = work(tx.objectStore(LIBRARY_STORE)); } catch (err) { reject(err); return; }
        tx.oncomplete = () => resolve(result && 'result' in result ? result.result : undefined);
        tx.onerror = () => reject(tx.error || new Error('IndexedDB transaction failed'));
        tx.onabort = () => reject(tx.error || new Error('IndexedDB transaction aborted'));
      }));
    }

    function readMarker() {
      try { return local().getItem(LIBRARY_MARKER_KEY); } catch (_) { return null; }
    }

    return {
      /** Caches `payload` ({ v, ts, url, items }). True if it is in IndexedDB, false if not. Never throws. */
      async save(payload) {
        // Everything up to the first await runs before save() returns: the items are
        // serialised now, as the localStorage cache did, so whatever the page does to them
        // while the database opens is not in what gets cached.
        let json;
        try {
          json = JSON.stringify(payload);
        } catch (err) {
          try { console.warn('[Nostalgex] Could not cache the library.', err); } catch (_) { /* no console */ }
          return false;
        }
        const id = newId();
        // The id first. A sign-out that lands while the items are still being written then
        // removes it, and the finished write is never read.
        let marked = false;
        try { marked = set(local(), LIBRARY_MARKER_KEY, id); } catch (_) { /* localStorage itself is blocked */ }
        if (!marked) return false;
        try {
          await transact('readwrite', (store) => store.put({ id, json }, LIBRARY_RECORD));
          return true;
        } catch (err) {
          // Nothing was written (the transaction aborts whole), and the old record no longer
          // matches the new id. Take the id back unless a newer save has already replaced it.
          try { if (readMarker() === id) local().removeItem(LIBRARY_MARKER_KEY); } catch (_) { /* already gone */ }
          try {
            console.warn('[Nostalgex] Could not cache the library; it will be read from the server next time.', err);
          } catch (_) { /* no console */ }
          return false;
        }
      },

      /** The cached payload, or null: none saved, signed out, unreadable, or too slow. Never throws. */
      async load() {
        const marker = readMarker();
        if (!marker) return null;
        let timer;
        const slow = new Promise((resolve) => { timer = setTimeout(() => resolve(null), env.loadTimeoutMs || LOAD_TIMEOUT_MS); });
        const read = transact('readonly', (store) => store.get(LIBRARY_RECORD))
          .then((record) => (record && record.id === marker && typeof record.json === 'string' ? JSON.parse(record.json) : null))
          .catch(() => null);
        const payload = await Promise.race([read, slow]);
        clearTimeout(timer);
        return payload;
      },

      /** Forgets the cache. The id goes before this returns; IndexedDB catches up after. Never throws. */
      async clear() {
        try { local().removeItem(LIBRARY_MARKER_KEY); } catch (_) { /* nothing saved */ }
        try { local().removeItem(LEGACY_LIBRARY_KEY); } catch (_) { /* nothing saved */ }
        try { await transact('readwrite', (store) => store.delete(LIBRARY_RECORD)); } catch (_) { /* the id is gone either way */ }
      },
    };
  }

  const api = {
    EVICTABLE, LEGACY_LIBRARY_KEY, LIBRARY_MARKER_KEY, LIBRARY_DB,
    isQuotaError, isEvictableKey, set, setLocal, setSession, purgeLegacy, createLibraryCache,
    libraryCache: createLibraryCache({
      get indexedDB() { return global.indexedDB; },
      get localStorage() { return global.localStorage; },
    }),
  };

  global.NostalgexStorage = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
