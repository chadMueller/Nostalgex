// One lineup for the whole Docker tuner (Trello I-080, decided by Chad 2026-11-10: option 1).
//
// WEB ONLY, and only in the Docker (selfhost) build. Apple TV and Roku have nothing like it; the
// hosted nostalgex.app does not run it and stays per-browser. Keep it out of the engine files the
// Roku app copies.
//
// Today every setting lives in the browser, so each new browser or device starts from the
// defaults (a Raspberry Pi user: "I keep having to go into settings and turn stuff on and off").
// In the Docker tuner the container holds ONE lineup that every browser reads on load and writes
// on change, last write wins. It is one small file, nostalgex-settings.json, that nginx serves and
// accepts a PUT for in a mounted volume (docker/nginx.conf, docker/40-config.sh).
//
// WHAT IS SHARED: exactly the keys in KEYS, nothing else. The packages that are on, the channel
// settings, the collections and the franchises that are on or off. Display preferences (guide
// layout, retro mode, subtitle and audio language, guide text size, sound, last channel, watch
// reporting) stay per browser.
//
// WHAT IS NEVER IN IT: a login, a token, a password, a server address of the viewer's own.
//   - It is built from KEYS only, and `plex90_saved_auth` and the session keys are not in KEYS.
//   - A value that contains this browser's own token (session or saved login) is left out.
//   - A blob read from the server is applied key by key through KEYS; anything else in it is
//     ignored, so a hand-edited file cannot write a login into the browser.
//
// IT CAN ONLY MAKE THINGS THE SAME AS TODAY, NEVER WORSE:
//   - Off (no selfhost marker, so on nostalgex.app): nothing runs, no request is made.
//   - No server file, no mounted volume, an old image, a proxy in the way: the answer is read as
//     "not here" and the page behaves exactly as before, from localStorage.
//   - A read that FAILED (server error, newer file format) turns the writing off for that visit,
//     so a browser that could not see the shared lineup never overwrites it with its own.
//   - Three failed writes in a row turn the writing off for that visit. Nothing throws.
//   - Writes wait for the first tap, click or key press of the visit and for a settled second,
//     so opening the page never rewrites the shared lineup with whatever that browser holds.
//
// The read is a synchronous request, once, before the page's own script runs, because the page
// reads its settings from localStorage in its first lines and there is no way to wait for an
// asynchronous answer there. It is a tiny file from the same nginx that just served the page.
//
// USAGE (browser: plain <script src="scripts/nostalgex-server-settings.js"> after
// nostalgex-storage.js, it starts itself; node: import it, then globalThis):
//
//   NostalgexServerSettings.KEYS                        the shared keys
//   NostalgexServerSettings.buildBlob(storage, secrets) the text to PUT, or null
//   NostalgexServerSettings.parseBlob(text)             { ok, blob } or { ok:false, reason }
//   NostalgexServerSettings.applyBlob(blob, storage)    storage now holds the shared lineup
//   NostalgexServerSettings.hydrate(opts) / start(opts) what the page runs, see below

(function (global) {
  'use strict';

  const FILE = 'nostalgex-settings.json';
  const FORMAT = 1;
  // The container answers with this header from its settings location, on every status. Without
  // it the answer is not from our endpoint (a proxy, an older image) and nothing is read or written.
  const MARK_HEADER = 'X-Nostalgex-Settings';
  const MAX_BLOB_CHARS = 200000;
  const DEBOUNCE_MS = 1500;
  const MAX_FAILURES = 3;

  const isStringArray = (v) => Array.isArray(v) && v.every((x) => typeof x === 'string');
  const isJSON = (check) => (text) => { try { return check(JSON.parse(text)); } catch (e) { return false; } };
  // Key -> is this text a value the page would have written.
  const KEY_RULES = {
    nostalgex_enabled_bundles: isJSON(isStringArray),
    plex90_channel_config: isJSON((v) => Array.isArray(v) && v.every((c) => c && typeof c === 'object')),
    plex90_config_version: (text) => /^\d{1,4}$/.test(text),
    nostalgex_enabled_collections: isJSON(isStringArray),
    nostalgex_enabled_franchises: isJSON(isStringArray),
    nostalgex_disabled_franchises: isJSON(isStringArray),
  };
  const KEYS = Object.keys(KEY_RULES);

  /** This browser's own secrets, as strings long enough to look for. */
  function secretsOf(local, session) {
    const out = [];
    const add = (v) => { if (typeof v === 'string' && v.length >= 8) out.push(v); };
    try { add(session && session.getItem('plex90_token')); add(session && session.getItem('plex90_user_token')); } catch (e) { /* none */ }
    try {
      const saved = JSON.parse((local && local.getItem('plex90_saved_auth')) || 'null');
      if (saved) { add(saved.token); add(saved.userToken); }
    } catch (e) { /* none */ }
    return out;
  }

  /** The shared lineup as the text to send, or null when there is nothing to share or it is too big. */
  function buildBlob(storage, secrets) {
    const keys = {};
    for (const key of KEYS) {
      let value;
      try { value = storage.getItem(key); } catch (e) { value = null; }
      if (typeof value !== 'string' || !KEY_RULES[key](value)) continue;
      if ((secrets || []).some((s) => value.includes(s))) continue;
      keys[key] = value;
    }
    if (!Object.keys(keys).length) return null;
    const text = JSON.stringify({ v: FORMAT, updatedAt: new Date().toISOString(), keys });
    return text.length > MAX_BLOB_CHARS ? null : text;
  }

  /** The keys of a blob text, in a fixed order: what "the same lineup" means. */
  function sameness(text) {
    try { const k = JSON.parse(text).keys || {}; return JSON.stringify(KEYS.map((key) => [key, (k[key] === undefined ? null : k[key])])); } catch (e) { return null; }
  }

  function parseBlob(text) {
    let blob;
    try { blob = JSON.parse(text); } catch (e) { return { ok: false, reason: 'corrupt' }; }
    if (!blob || typeof blob !== 'object' || typeof blob.v !== 'number') return { ok: false, reason: 'corrupt' };
    // A file written by a newer tuner is not ours to read, and not ours to overwrite.
    if (blob.v > FORMAT) return { ok: false, reason: 'newer' };
    if (!blob.keys || typeof blob.keys !== 'object' || Array.isArray(blob.keys)) return { ok: false, reason: 'corrupt' };
    return { ok: true, blob };
  }

  /**
   * Makes `storage` hold the shared lineup: every shared key the blob has, valid, is set; every
   * shared key it lacks is removed, so browsers end up the same. Nothing outside KEYS is touched.
   * `set` is how a value is saved (it gives up caches on a full quota); default storage.setItem.
   */
  function applyBlob(blob, storage, set) {
    const save = set || ((k, v) => { storage.setItem(k, v); return true; });
    let applied = 0;
    for (const key of KEYS) {
      const value = blob.keys[key];
      try {
        if (typeof value === 'string' && value.length <= MAX_BLOB_CHARS && KEY_RULES[key](value)) {
          if (storage.getItem(key) !== value && save(key, value) !== false) applied += 1;
        } else if (storage.getItem(key) !== null) {
          storage.removeItem(key);
          applied += 1;
        }
      } catch (e) { /* a full or locked storage: that key stays as it was */ }
    }
    return applied;
  }

  function isSelfhost(doc) {
    try {
      const el = doc && doc.querySelector('meta[name="nostalgex-build"]');
      return !!el && el.getAttribute('content') === 'selfhost';
    } catch (e) {
      return false;
    }
  }

  const state = {
    // 'off' | 'applied' | 'absent' | 'corrupt' (a file nobody can read, writing replaces it)
    //   | 'failed' (could not read it: do not write) | 'newer'
    status: 'off',
    canWrite: false,
    lastSame: null,   // sameness() of what the server holds, as far as this page knows
    failures: 0,
    armed: false,
    sent: 0,
  };

  /**
   * The one read, before the page's script. opts (all optional, for tests): url, storage, session,
   * xhr (a factory), set. Returns the status. Never throws.
   */
  function hydrate(opts) {
    const o = opts || {};
    const storage = o.storage || global.localStorage;
    try {
      const url = o.url || new global.URL(FILE, global.location.href).href;
      const x = o.xhr ? o.xhr() : new global.XMLHttpRequest();
      x.open('GET', url, false);
      x.send();
      const marked = String(x.getResponseHeader(MARK_HEADER) || '').toLowerCase() === 'on';
      if (!marked) return finish('off', false);               // not our endpoint: today's behaviour
      if (x.status === 404) return finish('absent', true);    // ours, nothing saved yet
      if (x.status === 200) {
        const parsed = parseBlob(x.responseText);
        if (!parsed.ok) return finish(parsed.reason === 'newer' ? 'newer' : 'corrupt', parsed.reason === 'corrupt');
        applyBlob(parsed.blob, storage, o.set || (global.NostalgexStorage ? (k, v) => global.NostalgexStorage.set(storage, k, v) : undefined));
        state.lastSame = sameness(x.responseText);
        return finish('applied', true);
      }
      return finish('failed', false);                         // 403, 405, 5xx, a proxy page
    } catch (e) {
      return finish('failed', false);                         // a network error, a blocked request
    }
    function finish(status, canWrite) {
      state.status = status;
      state.canWrite = canWrite;
      return status;
    }
  }

  /**
   * Starts the writing: listens for the page saving a shared key, then sends the whole lineup a
   * moment after the last change. opts (for tests): storage, session, put (async (url, text) =>
   * status number), now/setTimeout/clearTimeout, url.
   */
  function start(opts) {
    const o = opts || {};
    const storage = o.storage || global.localStorage;
    const session = o.session || global.sessionStorage;
    const url = o.url || new global.URL(FILE, global.location.href).href;
    const timers = {
      set: o.setTimeout || global.setTimeout.bind(global),
      clear: o.clearTimeout || global.clearTimeout.bind(global),
    };
    let timer = null;
    state.armed = false;
    state.failures = 0;
    state.sent = 0;

    const put = o.put || (async (target, text, keepalive) => {
      const res = await global.fetch(target, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: text, cache: 'no-store',
        keepalive: !!keepalive && text.length < 60000,
      });
      return res.status;
    });

    async function send(keepalive) {
      timer = null;
      if (!state.canWrite || !state.armed || state.failures >= MAX_FAILURES) return false;
      const text = buildBlob(storage, secretsOf(storage, session));
      if (text === null) return false;
      if (sameness(text) === state.lastSame) return false;   // the server already has this
      try {
        const status = await put(url, text, keepalive);
        if (status >= 200 && status < 300) {
          state.lastSame = sameness(text);
          state.failures = 0;
          state.sent += 1;
          return true;
        }
        fail(`the server answered ${status}`);
      } catch (e) {
        fail(String(e && e.message || e));
      }
      return false;
    }
    function fail(why) {
      state.failures += 1;
      if (state.failures === MAX_FAILURES && global.console) {
        global.console.warn(`[Nostalgex] The shared lineup could not be saved (${why}). Settings stay in this browser.`);
      }
    }
    function changed(key) {
      if (!state.canWrite || !state.armed || KEYS.indexOf(key) < 0) return;
      if (timer !== null) timers.clear(timer);
      timer = timers.set(() => { send(false); }, DEBOUNCE_MS);
    }

    if (global.NostalgexStorage && typeof global.NostalgexStorage.onLocalWrite === 'function') {
      global.NostalgexStorage.onLocalWrite(changed);
    }
    // The first tap, click or key press of the visit. Until then the page is only loading.
    const arm = () => { state.armed = true; };
    if (global.document && global.document.addEventListener) {
      for (const type of ['pointerdown', 'keydown', 'touchstart', 'click']) {
        global.document.addEventListener(type, arm, { capture: true, once: true, passive: true });
      }
    }
    // Leaving the page with a change still waiting: send it now.
    if (global.addEventListener) {
      global.addEventListener('pagehide', () => { if (timer !== null) { timers.clear(timer); send(true); } });
    }
    return { arm, changed, send, state };
  }

  const api = { FILE, FORMAT, MARK_HEADER, KEYS, buildBlob, parseBlob, applyBlob, secretsOf, sameness, isSelfhost, hydrate, start, state };
  global.NostalgexServerSettings = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;

  // The Docker build runs itself: the read before the page's script, then the listening.
  if (global.document && isSelfhost(global.document)) {
    try {
      hydrate();
      start();
    } catch (e) { /* the page carries on from localStorage, as it always did */ }
  }
})(typeof window !== 'undefined' ? window : globalThis);
