#!/usr/bin/env node
/**
 * START OVER on the loading screen: a library load that never finishes always has a way
 * back to sign-in, as on the Apple TV.
 *
 *   1. plex-tuner.html: the button sits inside #loading-library (so it shows for the whole
 *      load), is a real <button> (TV browsers get no keys, only clicks) and calls
 *      startOverFromLoading().
 *   2. The page's own startOverFromLoading and signOut, run with the page's globals stubbed:
 *      the saved login, the session and the library cache go, then the page leaves for
 *      web-tuner.html (leaving also drops the stuck requests). It still leaves if signOut throws.
 *   3. Negative controls: no button, and a start over that doesn't clear the saved login,
 *      each fail.
 *
 * The real page against a server whose scan never answers: `npm run test:start-over:browser`.
 * No network. Run: `npm run test:start-over`.
 */
import { readFileSync } from "node:fs";
import vm from "node:vm";

const page = readFileSync(new URL("../plex-tuner.html", import.meta.url), "utf8");
let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

function lift(src, name) {
  const at = src.indexOf(`  function ${name}() {`);
  if (at < 0) return null;
  let depth = 0;
  for (let i = src.indexOf("{", at); i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) return src.slice(at, i + 1);
  }
  return null;
}

function markupOk(src) {
  const a = src.indexOf('<div class="loading-library" id="loading-library"');
  const b = src.indexOf("<!-- Static overlay -->", a);
  const block = a >= 0 && b > a ? src.slice(a, b) : "";
  return /<button[^>]*id="loading-library-start-over"[^>]*onclick="startOverFromLoading\(\)"[^>]*>START OVER<\/button>/.test(block);
}

/** Runs the page's start over; returns what it did. */
function startOver(src, { signOutThrows = false } = {}) {
  const startFn = lift(src, "startOverFromLoading");
  const signFn = lift(src, "signOut");
  if (!startFn || !signFn) return null;
  const store = (init) => { const m = new Map(Object.entries(init)); return { m, getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }; };
  const local = store({ plex90_saved_auth: '{"token":"t","serverUrl":"http://x","backend":"jellyfin"}', plex90_library_cache: "x", other: "kept" });
  const session = store({ plex90_token: "t", plex90_server_url: "http://x", plex90_backend: "jellyfin", plex90_jellyfin_user_id: "u" });
  const calls = [];
  const el = () => ({ classList: { add() {}, remove() {} }, style: {} });
  const ctx = {
    console: { warn() {}, log() {} }, localStorage: local, sessionStorage: session,
    document: { getElementById: el },
    location: { replace: (u) => calls.push(`replace ${u}`) },
    sleepTimer: { cancel() {} }, closePlaybackInfo() {}, stopVideo() {}, resetConnectScreen() {}, endScanWatch() {},
    updateConfigPlexStatus() {}, hideGuide() {},
    clearLibraryCache() { calls.push("clearLibraryCache"); local.removeItem("plex90_library_cache"); },
    COLLECTION_SCAN_KEY: "plex90_collections", CHANNELS: [{ itemPool: [1], schedule: [1] }],
    libraryExtrasGeneration: 0,
  };
  vm.createContext(ctx);
  vm.runInContext(`var configVisible, plexToken, plexServerUrl, plexServerName, plexConnected, isDemoMode, selectedServers,
    selectedServerIndices, discoveredServers, rawCollections, collectionCandidates, mediaBackend, jellyfinUserId,
    currentChannel, appState;\n${signFn}\n${startFn}`, ctx);
  if (signOutThrows) ctx.signOut = () => { calls.push("signOut threw"); throw new Error("boom"); };
  ctx.startOverFromLoading();
  return { calls, local: [...local.m.keys()], session: [...session.m.keys()] };
}

// 1. Markup.
check("the button is inside #loading-library, a <button> calling startOverFromLoading()", markupOk(page));

// 2. Behaviour.
const r = startOver(page);
check("plex-tuner.html has startOverFromLoading and signOut", r !== null);
if (r) {
  check("the saved login is gone", !r.local.includes("plex90_saved_auth"), r.local.join(","));
  check("the library cache is gone", r.calls.includes("clearLibraryCache") && !r.local.includes("plex90_library_cache"));
  check("unrelated storage stays", r.local.includes("other"));
  check("the session's login is gone", r.session.length === 0, r.session.join(","));
  check("then it leaves for web-tuner.html, last", r.calls.at(-1) === "replace web-tuner.html", r.calls.join(" > "));
}
const r2 = startOver(page, { signOutThrows: true });
check("it still leaves for web-tuner.html when signOut throws", r2 && r2.calls.at(-1) === "replace web-tuner.html");

// 3. Negative controls.
const noButton = page.replace(/\s*<button[^>]*id="loading-library-start-over"[\s\S]*?<\/button>/, "");
check("negative control patched: no button", noButton !== page);
check("negative control fails: no button", !markupOk(noButton));
const noSignOut = page.replace("    try { signOut(); } catch (e) { console.warn('signOut error:', e); }\n", "");
check("negative control patched: start over without signing out", noSignOut !== page);
const r3 = startOver(noSignOut);
check("negative control fails: start over without signing out keeps the saved login", r3 && r3.local.includes("plex90_saved_auth"));

if (failures.length) {
  console.error(`start over smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`start over smoke: ${passed} passed (2 negative controls fail)`);
