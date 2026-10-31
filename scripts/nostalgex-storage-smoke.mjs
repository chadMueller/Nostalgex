#!/usr/bin/env node
/**
 * scripts/nostalgex-storage.js: storage writes that cannot throw, small settings that outrank
 * the caches, and the library cache (issue #152).
 *
 *   1. isQuotaError knows what Chrome, Firefox and old Safari throw, and nothing else.
 *   2. set() against a fake Storage with a real quota: a write that fits, a write that does
 *      not (false, one warning, no throw), a write that makes room by giving up caches in
 *      order and stops as soon as it fits, a cache write that never evicts another cache,
 *      and a storage that throws something else.
 *   3. The keys it is willing to evict are the keys the rest of the tuner really writes.
 *   4. The library cache against a small fake IndexedDB: save and load, the id that makes
 *      sign-out immediate, a failed write that takes its id back, a database that never
 *      answers, and no IndexedDB at all. The real thing runs in the browser: see
 *      scripts/storage-quota-browser-smoke.mjs.
 *
 * Run: `npm run test:storage`
 */
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import "./nostalgex-storage.js";

const S = globalThis.NostalgexStorage;
let passed = 0;
const failures = [];
async function check(label, fn) {
  try { await fn(); passed += 1; } catch (e) { failures.push(`${label}: ${e.stack || e.message}`); }
}

const quotaError = () => Object.assign(new Error("The quota has been exceeded."), { name: "QuotaExceededError", code: 22 });

/** A Storage with the browser's accounting: the quota counts keys and values. */
class FakeStorage {
  constructor(quota = Infinity, seed = {}) { this.quota = quota; this.map = new Map(Object.entries(seed)); this.writes = []; }
  get length() { return this.map.size; }
  key(i) { return [...this.map.keys()][i] ?? null; }
  getItem(k) { return this.map.has(k) ? this.map.get(k) : null; }
  removeItem(k) { this.map.delete(k); }
  used() { let n = 0; for (const [k, v] of this.map) n += k.length + v.length; return n; }
  setItem(k, v) {
    const before = this.map.has(k) ? k.length + this.map.get(k).length : 0;
    if (this.used() - before + k.length + String(v).length > this.quota) throw quotaError();
    this.writes.push(k);
    this.map.set(k, String(v));
  }
}

// Warnings are expected below; keep them out of the test output and count them.
const realWarn = console.warn;
let warnings = [];
console.warn = (...args) => { warnings.push(args.map(String).join(" ")); };

// ── 1. isQuotaError ────────────────────────────────────────────────────────

await check("Chrome and Safari: QuotaExceededError", () => assert.equal(S.isQuotaError(quotaError()), true));
await check("Firefox: NS_ERROR_DOM_QUOTA_REACHED", () => assert.equal(S.isQuotaError({ name: "NS_ERROR_DOM_QUOTA_REACHED", code: 1014 }), true));
await check("legacy Safari: code 22", () => assert.equal(S.isQuotaError({ name: "Error", code: 22 }), true));
await check("a plain error, a network error and nothing are not quota errors", () => {
  assert.equal(S.isQuotaError(new Error("boom")), false);
  assert.equal(S.isQuotaError(new TypeError("Failed to fetch")), false);
  assert.equal(S.isQuotaError(new Error("Section TV returned HTTP 500")), false);
  assert.equal(S.isQuotaError(null), false);
  assert.equal(S.isQuotaError(undefined), false);
});

// ── 2. set() ───────────────────────────────────────────────────────────────

await check("a write that fits is saved", () => {
  const st = new FakeStorage(1000);
  assert.equal(S.set(st, "a", "1"), true);
  assert.equal(st.getItem("a"), "1");
});

await check("a write that cannot fit returns false, warns once, and never throws", () => {
  warnings = [];
  const st = new FakeStorage(100, { other: "x".repeat(95) });
  assert.equal(S.set(st, "plex90_channel_config", "y".repeat(50)), false);
  assert.equal(S.set(st, "plex90_channel_config", "y".repeat(50)), false);
  assert.equal(st.getItem("other").length, 95, "nothing else is touched");
  assert.equal(warnings.filter((w) => w.includes("plex90_channel_config")).length, 1, "one warning per key, not one per write");
});

await check("a full quota gives up the rebuildable data, least valuable first, and stops once it fits", () => {
  // quota 1000; 960 used by three caches. The setting needs 100, so the first cache (300) is enough.
  const st = new FakeStorage(1000, {
    plex90_library_cache: "L".repeat(300 - 20),
    nostalgex_collection_scan: "C".repeat(300 - 25),
    nostalgex_music_video_enrichments_v1: "M".repeat(300 - 36),
    plex90_manifest_a_1_1: "D".repeat(60 - 21),
    plex90_saved_auth: "A".repeat(40 - 17),
  });
  assert.equal(S.set(st, "plex90_channel_config", "c".repeat(100 - 21)), true);
  assert.equal(st.getItem("plex90_library_cache"), null, "the old library cache goes first");
  assert.notEqual(st.getItem("nostalgex_collection_scan"), null, "and the rest stays once there is room");
  assert.notEqual(st.getItem("nostalgex_music_video_enrichments_v1"), null);
  assert.notEqual(st.getItem("plex90_manifest_a_1_1"), null);
  assert.notEqual(st.getItem("plex90_saved_auth"), null, "sign-in is never evicted");
});

await check("eviction walks the whole list when it has to, and manifests go last", () => {
  const st = new FakeStorage(1000, {
    nostalgex_collection_scan: "C".repeat(250),
    nostalgex_music_video_enrichments_v1: "M".repeat(250),
    plex90_manifest_a_1_1: "D".repeat(250),
    plex90_manifest_a_2_1: "D".repeat(150),
    plex90_saved_auth: "A".repeat(50),
  });
  assert.equal(S.set(st, "plex90_channel_config", "c".repeat(600)), true);
  assert.equal(st.getItem("nostalgex_collection_scan"), null);
  assert.equal(st.getItem("nostalgex_music_video_enrichments_v1"), null);
  assert.equal(st.getItem("plex90_manifest_a_1_1"), null, "every manifest is one rule");
  assert.equal(st.getItem("plex90_manifest_a_2_1"), null);
  assert.notEqual(st.getItem("plex90_saved_auth"), null);
});

await check("when giving up every cache is still not enough, it returns false and the rest is untouched", () => {
  const st = new FakeStorage(500, { nostalgex_collection_scan: "C".repeat(100), somebody_elses_data: "z".repeat(380) });
  assert.equal(S.set(st, "plex90_channel_config", "c".repeat(200)), false);
  assert.equal(st.getItem("somebody_elses_data").length, 380);
});

await check("a cache write does not evict another cache", () => {
  const st = new FakeStorage(500, { plex90_manifest_a_1_1: "D".repeat(450) });
  assert.equal(S.set(st, "nostalgex_collection_scan", "c".repeat(200)), false);
  assert.notEqual(st.getItem("plex90_manifest_a_1_1"), null);
});

await check("a replacement only counts the difference", () => {
  const st = new FakeStorage(100, { plex90_channel_config: "a".repeat(70) });
  assert.equal(S.set(st, "plex90_channel_config", "b".repeat(75)), true);
});

await check("a storage that throws something else is not mistaken for a full one", () => {
  const evicted = [];
  const st = { length: 1, key: () => "nostalgex_collection_scan", removeItem: (k) => evicted.push(k), setItem() { throw new Error("SecurityError"); } };
  assert.equal(S.set(st, "x", "1"), false);
  assert.deepEqual(evicted, []);
});

/** Swaps globalThis storages for the length of `fn`; newer Node versions have their own. */
function withStorages(defs, fn) {
  const saved = {};
  for (const name of Object.keys(defs)) saved[name] = Object.getOwnPropertyDescriptor(globalThis, name);
  try {
    for (const [name, def] of Object.entries(defs)) Object.defineProperty(globalThis, name, def);
    fn();
  } finally {
    for (const name of Object.keys(defs)) {
      if (saved[name]) Object.defineProperty(globalThis, name, saved[name]); else delete globalThis[name];
    }
  }
}
const blocked = { configurable: true, get() { throw new Error("SecurityError: cookies are blocked"); } };

await check("setLocal and setSession never throw, even when the storage object itself throws", () => {
  withStorages({ localStorage: blocked, sessionStorage: blocked }, () => {
    assert.equal(S.setLocal("k", "v"), false);
    assert.equal(S.setSession("k", "v"), false);
  });
});

await check("setLocal and setSession write to the page's storages", () => {
  const local = new FakeStorage();
  const session = new FakeStorage();
  withStorages({ localStorage: { configurable: true, value: local }, sessionStorage: { configurable: true, value: session } }, () => {
    assert.equal(S.setLocal("a", "1"), true);
    assert.equal(S.setSession("b", "2"), true);
    assert.equal(local.getItem("a"), "1");
    assert.equal(session.getItem("b"), "2");
    local.setItem(S.LEGACY_LIBRARY_KEY, "old");
    S.purgeLegacy();
    assert.equal(local.getItem(S.LEGACY_LIBRARY_KEY), null);
    assert.equal(local.getItem("a"), "1");
  });
});

// ── 3. The evictable keys are the keys the tuner really writes ─────────────

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const grab = (src, re, what) => { const m = src.match(re); assert.ok(m, `${what} not found: the name moved, update EVICTABLE`); return m[1]; };

await check("EVICTABLE names the collection scan key plex-tuner.html writes", () => {
  const key = grab(read("../plex-tuner.html"), /const COLLECTION_SCAN_KEY = '([^']+)'/, "COLLECTION_SCAN_KEY");
  assert.ok(S.EVICTABLE.some((r) => r.key === key), key);
});
await check("EVICTABLE names the MusicBrainz cache key", () => {
  const key = grab(read("./nostalgex-music-brainz.js"), /const CACHE_KEY = '([^']+)'/, "CACHE_KEY");
  assert.ok(S.EVICTABLE.some((r) => r.key === key), key);
});
await check("EVICTABLE names the daily manifest prefix", () => {
  const prefix = grab(read("./nostalgex-daily-manifest.js"), /const MANIFEST_PREFIX = '([^']+)'/, "MANIFEST_PREFIX");
  assert.ok(S.EVICTABLE.some((r) => r.prefix === prefix), prefix);
});
await check("the sign-in, config, preferences and the cache id are not evictable", () => {
  for (const k of ["plex90_saved_auth", "plex90_channel_config", "plex90_config_version", "plex90_client_id", "nostalgex_enabled_bundles",
    "nostalgex_enabled_collections", "nostalgex_completed_initial_load", "nostalgex_stream_quality", S.LIBRARY_MARKER_KEY]) {
    assert.equal(S.isEvictableKey(k), false, k);
  }
});
await check("the page and the engine write nothing to storage except through the helpers or in a try", () => {
  // The audit behind #152, kept: every setItem in plex-tuner.html is lsSet/ssSet.
  const page = read("../plex-tuner.html");
  const raw = page.split("\n").map((l, i) => [l, i + 1]).filter(([l]) => /(localStorage|sessionStorage)\.setItem\(/.test(l));
  assert.deepEqual(raw.map(([l, n]) => `${n}: ${l.trim()}`), [], "a raw setItem in plex-tuner.html; use lsSet/ssSet");
});

// ── 4. The library cache ───────────────────────────────────────────────────

/** Just enough IndexedDB for one database, one store, put/get/delete. */
function fakeIndexedDB({ hang = false, failPut = false } = {}) {
  const records = new Map();
  let created = false;
  const db = {
    objectStoreNames: { contains: () => created },
    createObjectStore() { created = true; },
    close() {},
    transaction() {
      const tx = {};
      const finish = (req, fn) => setTimeout(() => {
        try { req.result = fn(); } catch (e) { tx.error = e; tx.onabort && tx.onabort(); return; }
        setTimeout(() => tx.oncomplete && tx.oncomplete(), 0);
      }, 0);
      tx.objectStore = () => ({
        put(value, key) { const req = {}; finish(req, () => { if (failPut) throw quotaError(); records.set(key, structuredClone(value)); return key; }); return req; },
        get(key) { const req = {}; finish(req, () => (records.has(key) ? structuredClone(records.get(key)) : undefined)); return req; },
        delete(key) { const req = {}; finish(req, () => { records.delete(key); }); return req; },
      });
      return tx;
    },
  };
  return {
    records,
    open() {
      const req = {};
      if (!hang) setTimeout(() => { req.result = db; if (!created) req.onupgradeneeded && req.onupgradeneeded(); req.onsuccess && req.onsuccess(); }, 0);
      return req;
    },
  };
}
const payload = (n = 3) => ({ v: 3, ts: 1700000000000, url: "http://lab:32400", items: Array.from({ length: n }, (_, i) => ({ ratingKey: String(i), title: `T${i}`, summary: "s".repeat(40) })) });

await check("save then load returns the payload, whole", async () => {
  const local = new FakeStorage();
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB(), localStorage: local });
  assert.equal(await c.save(payload(500)), true);
  assert.deepEqual(await c.load(), payload(500));
});

await check("nothing saved loads as null", async () => {
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB(), localStorage: new FakeStorage() });
  assert.equal(await c.load(), null);
});

await check("the payload is fixed when save() is called, not when the database opens", async () => {
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB(), localStorage: new FakeStorage() });
  const p = payload(2);
  const saved = c.save(p);
  p.items[0].enrichment = { added: "after the call" };
  await saved;
  assert.equal((await c.load()).items[0].enrichment, undefined);
});

await check("clear() takes the id away before it returns, so a delete that never ran cannot be read", async () => {
  const idb = fakeIndexedDB();
  const local = new FakeStorage();
  const c = S.createLibraryCache({ indexedDB: idb, localStorage: local });
  await c.save(payload());
  assert.ok(local.getItem(S.LIBRARY_MARKER_KEY));
  const clearing = c.clear();
  assert.equal(local.getItem(S.LIBRARY_MARKER_KEY), null, "gone synchronously");
  assert.equal(idb.records.size, 1, "IndexedDB has not caught up yet");
  assert.equal(await c.load(), null, "and the cache cannot be read");
  await clearing;
  assert.equal(idb.records.size, 0, "then the record is deleted too");
});

await check("clear() also removes an old-style localStorage cache", async () => {
  const local = new FakeStorage(Infinity, { [S.LEGACY_LIBRARY_KEY]: "old" });
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB(), localStorage: local });
  await c.clear();
  assert.equal(local.getItem(S.LEGACY_LIBRARY_KEY), null);
});

await check("a clear that lands while a save is writing leaves nothing readable", async () => {
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB(), localStorage: new FakeStorage() });
  const saving = c.save(payload());
  const clearing = c.clear();
  await Promise.all([saving, clearing]);
  assert.equal(await c.load(), null);
});

await check("a record whose id is not the current one is ignored", async () => {
  const idb = fakeIndexedDB();
  const local = new FakeStorage();
  const c = S.createLibraryCache({ indexedDB: idb, localStorage: local });
  await c.save(payload());
  local.setItem(S.LIBRARY_MARKER_KEY, "a-newer-save-that-never-finished");
  assert.equal(await c.load(), null);
});

await check("a failed write returns false and takes its id back", async () => {
  warnings = [];
  const local = new FakeStorage();
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB({ failPut: true }), localStorage: local });
  assert.equal(await c.save(payload()), false);
  assert.equal(local.getItem(S.LIBRARY_MARKER_KEY), null);
  assert.equal(await c.load(), null);
});

await check("a failed write does not leave the old cache readable under the new id", async () => {
  const idb = fakeIndexedDB();
  const local = new FakeStorage();
  const good = S.createLibraryCache({ indexedDB: idb, localStorage: local });
  await good.save(payload(1));
  const failing = S.createLibraryCache({ indexedDB: { ...idb, open: fakeIndexedDB({ failPut: true }).open }, localStorage: local });
  assert.equal(await failing.save(payload(2)), false);
  assert.equal(await good.load(), null, "no marker, no cache: a rescan, never a stale mix");
});

await check("no room for the id means nothing is cached, and nothing throws", async () => {
  warnings = [];
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB(), localStorage: new FakeStorage(10) });
  assert.equal(await c.save(payload()), false);
});

await check("the id makes room by giving up caches, like any other small setting", async () => {
  const local = new FakeStorage(600, { nostalgex_collection_scan: "c".repeat(540) });
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB(), localStorage: local });
  assert.equal(await c.save(payload()), true);
  assert.equal(local.getItem("nostalgex_collection_scan"), null);
});

await check("a database that never answers: load gives up after the timeout, save never throws", async () => {
  const local = new FakeStorage();
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB({ hang: true }), localStorage: local, loadTimeoutMs: 60 });
  c.save(payload());   // pending forever, as in the browser; not awaited
  const t0 = Date.now();
  assert.equal(await c.load(), null);
  assert.ok(Date.now() - t0 < 1000);
});

await check("no IndexedDB at all: save is false, load is null, clear is quiet", async () => {
  warnings = [];
  const local = new FakeStorage();
  const c = S.createLibraryCache({ indexedDB: undefined, localStorage: local });
  assert.equal(await c.save(payload()), false);
  assert.equal(local.getItem(S.LIBRARY_MARKER_KEY), null);
  assert.equal(await c.load(), null);
  await c.clear();
});

await check("a payload that cannot be serialised is not cached and does not throw", async () => {
  warnings = [];
  const loop = payload(); loop.self = loop;
  const c = S.createLibraryCache({ indexedDB: fakeIndexedDB(), localStorage: new FakeStorage() });
  assert.equal(await c.save(loop), false);
});

console.warn = realWarn;
if (failures.length) {
  console.error(`storage smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`storage smoke: ${passed} checks passed`);
