// Runs the production web tracker and migration helpers with a fake clock/transport.
// No real server, profile, credentials or browser storage is accessed.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const html = fs.readFileSync(path.join(root, 'plex-tuner.html'), 'utf8');
const helpers = fs.readFileSync(path.join(root, 'scripts/nostalgex-watch-state.js'), 'utf8');
const start = html.indexOf('  function makePlaybackTracker(');
const end = html.indexOf('  // Start playback and, if the browser refuses,', start);
assert(start >= 0 && end > start);
const production = html.slice(start, end);
let passed = 0;
const errors = [];
async function test(name, run) {
  try { await run(); passed++; }
  catch (error) { errors.push(`${name}: ${error.stack}`); }
}
function storage(values = {}) {
  const map = new Map(Object.entries(values));
  return { getItem: key => map.get(key) ?? null, setItem: (key, value) => map.set(key, value), map };
}
function fixture({ backend = 'plex', type = 'movie', unreadable = false } = {}) {
  let clock = 0, tick, counted = false, sessionCounter = 0;
  const calls = [];
  const prior = { PlaybackPositionTicks: 1230000000, PlayCount: 2, Played: false, LastPlayedDate: '2026-01-01T00:00:00Z' };
  const video = { paused: false, ended: false };
  const sandbox = {
    console: { log() {}, warn() {} }, URL, URLSearchParams, Date: { now: () => clock },
    crypto: { randomUUID: () => `fixture-session-${++sessionCounter}` },
    mediaBackend: backend, plexServerUrl: 'https://fixture.invalid', plexToken: 'fixture-token', plexLocalNoAuth: false, plexSignedIn: () => true, plexTokenParam: (t) => (t ? `X-Plex-Token=${t}` : ''), plexTokenAmp: (t) => (t ? `&X-Plex-Token=${t}` : ''),
    jellyfinUserId: 'fixture-user', jellyfinAuthHeader: () => 'fixture-header', getClientId: () => 'fixture-client',
    document: { getElementById: () => video },
    // The tracker's length is the programme's slot (#315); the minutes are all these fixtures need of it.
    NostalgexDailyManifest: { slotSeconds: (item) => (item.duration || 0) * 60 },
    setInterval: fn => { tick = fn; return 1; }, clearInterval() {},
    setTimeout: fn => { fn(); return 1; },
    fetch: async (raw, init = {}) => {
      const url = new URL(raw);
      const body = init.body ? JSON.parse(init.body) : null;
      calls.push({ path: url.pathname, query: Object.fromEntries(url.searchParams), method: init.method || 'GET', body });
      if (url.pathname === '/:/scrobble') counted = true;
      let response = {};
      if (url.pathname === '/library/metadata/42') response = { MediaContainer: { Metadata: [{ ratingKey: '42', type, grandparentRatingKey: type === 'episode' ? 'show' : undefined }] } };
      if (url.pathname === '/hubs/continueWatching/items') response = { MediaContainer: { Metadata: counted ? [{ ratingKey: 'next', grandparentRatingKey: 'show' }] : [] } };
      if (url.pathname === '/Users/fixture-user/Items/42') response = { UserData: prior };
      const status = unreadable && url.pathname === '/Users/fixture-user/Items/42' ? 500 : 200;
      return { status, ok: status === 200, json: async () => response };
    },
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(helpers + production, sandbox);
  const scope = sandbox.NostalgexWatchState.createReportingScope({ nowPlaying: false, markWatched: false });
  const tracker = options => {
    scope.update(options);
    return sandbox.makePlaybackTracker({ ratingKey: '42', duration: 1, offsetSeconds: 0, type }, options, scope);
  };
  const drain = () => sandbox.NostalgexWatchState.sharedQueue.drain();
  const play = async (t, seconds) => {
    t.onReady(); await drain();
    for (clock = 10000; clock <= seconds * 1000; clock += 10000) { tick(); await drain(); }
  };
  return { sandbox, calls, prior, tracker, drain, play, setClock: value => { clock = value; }, tick: () => tick() };
}
const WS = fixture().sandbox.NostalgexWatchState;
// Compile each complete classic inline script too: extracting functions alone can
// hide collisions between a reporting preference and an existing UI function.
await test('complete tuner inline scripts parse before any browser startup', () => {
  let compiled = 0;
  for (const [index, match] of [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)].entries()) {
    if (!match[2].trim() || /type=["'](?:module|application\/ld\+json)/i.test(match[1])) continue;
    new vm.Script(match[2], { filename: `plex-tuner-inline-${index}.js` });
    compiled++;
  }
  assert(compiled > 0, 'the production tuner has inline scripts');
});
await test('new installs default to both OFF', () => {
  const result = WS.loadReportingPreferences(storage());
  assert.equal(result.nowPlaying, false); assert.equal(result.markWatched, false);
});
await test('legacy ON/OFF migrate both choices and new explicit OFF wins', () => {
  for (const legacy of ['true', 'false']) {
    const result = WS.loadReportingPreferences(storage({ plex90_sync_activity: legacy }));
    assert.equal(result.nowPlaying, legacy === 'true'); assert.equal(result.markWatched, legacy === 'true');
  }
  const result = WS.loadReportingPreferences(storage({ plex90_sync_activity: 'true', plex90_now_playing_v1: 'false', plex90_mark_watched_v1: 'false' }));
  assert.equal(result.nowPlaying, false); assert.equal(result.markWatched, false);
});
await test('saving a choice persists the complete independent pair', () => {
  const store = storage({ plex90_sync_activity: 'true' });
  WS.saveReportingPreferences(store, { nowPlaying: true, markWatched: false });
  const result = WS.loadReportingPreferences(store);
  assert.equal(result.nowPlaying, true); assert.equal(result.markWatched, false);
  assert.equal(store.getItem('plex90_sync_activity'), 'false', 'an older client must not turn marking back on');
});
await test('unavailable storage stays private by default', () => {
  const result = WS.loadReportingPreferences({ getItem() { throw new Error('unavailable'); } });
  assert.equal(result.nowPlaying, false); assert.equal(result.markWatched, false);
});
// Emby reports through the same /Sessions/Playing and /Users/{id} routes as Jellyfin, never
// Plex's timeline. Before the Emby option it only ever arrived here labelled 'jellyfin'.
for (const backend of ['plex', 'jellyfin', 'emby']) {
  for (const nowPlaying of [false, true]) for (const markWatched of [false, true]) {
    await test(`${backend} independent modes now=${nowPlaying} watched=${markWatched}`, async () => {
      const f = fixture({ backend }); const t = f.tracker({ nowPlaying, markWatched });
      await f.play(t, 80); t.stop(); await f.drain();
      const sessions = f.calls.filter(c => c.path === '/:/timeline' || c.path.startsWith('/Sessions/Playing'));
      const marks = f.calls.filter(c => c.path === '/:/scrobble' || c.path === '/Users/fixture-user/PlayedItems/42');
      assert.equal(sessions.length > 0, nowPlaying);
      assert.equal(marks.length, markWatched ? 1 : 0);
      if (!nowPlaying && !markWatched) assert.equal(f.calls.length, 0);
      if (backend === 'plex' && nowPlaying && !markWatched) {
        assert(f.calls.every(c => c.path === '/:/timeline'));
        for (const c of sessions) { assert(!('time' in c.query)); assert(!('duration' in c.query)); }
      }
      if (backend !== 'plex') assert(!f.calls.some(c => c.path === '/:/timeline' || c.path === '/:/scrobble'));
      if (backend !== 'plex' && nowPlaying && !markWatched) {
        const restored = f.calls.findLast(c => c.path.endsWith('/UserData'));
        assert(restored); assert.equal(restored.body.PlayCount, f.prior.PlayCount);
        assert.equal(restored.body.PlaybackPositionTicks, f.prior.PlaybackPositionTicks);
      }
    });
  }
}
await test('mark-only episode retains next-up cleanup without timeline reports', async () => {
  const f = fixture({ type: 'episode' }); const t = f.tracker({ nowPlaying: false, markWatched: true });
  await f.play(t, 80); t.stop(); await f.drain();
  assert(!f.calls.some(c => c.path === '/:/timeline'));
  assert.equal(f.calls.filter(c => c.path === '/:/scrobble').length, 1);
  assert(f.calls.some(c => c.path === '/actions/removeFromContinueWatching' && c.query.ratingKey === 'next'));
});
await test('Jellyfin mark-only still marks a watch beyond ninety percent', async () => {
  const f = fixture({ backend: 'jellyfin' }); const t = f.tracker({ nowPlaying: false, markWatched: true });
  t.onReady(); await f.drain(); f.setClock(100000); f.tick(); t.stop(); await f.drain();
  assert.equal(f.calls.filter(c => c.path === '/Users/fixture-user/PlayedItems/42').length, 1);
  assert(!f.calls.some(c => c.path.startsWith('/Sessions/Playing')));
});
await test('Now Playing-only Jellyfin stop stays below server completion and restores prior state', async () => {
  const f = fixture({ backend: 'jellyfin' }); const t = f.tracker({ nowPlaying: true, markWatched: false });
  await f.play(t, 100); t.stop(); await f.drain();
  const stop = f.calls.find(c => c.path === '/Sessions/Playing/Stopped');
  assert(stop.body.PositionTicks <= Math.floor(60 * 0.89 * 10000000));
  const restored = f.calls.findLast(c => c.path.endsWith('/UserData'));
  assert.equal(restored.body.PlayCount, 2); assert.equal(restored.body.Played, false);
});
await test('Jellyfin final-stop threshold crossing cannot auto-count before the explicit mark', async () => {
  const f = fixture({ backend: 'jellyfin' }); const t = f.tracker({ nowPlaying: true, markWatched: true });
  t.onReady(); await f.drain(); f.setClock(100000); t.stop(); await f.drain();
  const stop = f.calls.find(c => c.path === '/Sessions/Playing/Stopped');
  assert(stop.body.PositionTicks <= Math.floor(60 * 0.89 * 10000000));
  assert.equal(f.calls.filter(c => c.path === '/Users/fixture-user/PlayedItems/42').length, 1);
});
for (const nowPlaying of [false, true]) for (const markWatched of [false, true]) {
  await test(`Jellyfin unreadable prior skips all writes now=${nowPlaying} watched=${markWatched}`, async () => {
    const f = fixture({ backend: 'jellyfin', unreadable: true });
    const t = f.tracker({ nowPlaying, markWatched });
    await f.play(t, 80); t.stop(); await f.drain();
    assert(f.calls.every(c => c.method === 'GET'), 'no reports, marks or zero-position cleanup');
    assert.equal(f.calls.length, nowPlaying || markWatched ? 1 : 0);
  });
}
await test('blocked OFF then ON cannot revive obsolete activity or marks', async () => {
  const f = fixture(); let release;
  f.sandbox.NostalgexWatchState.sharedQueue.enqueue(() => new Promise(resolve => { release = resolve; }));
  await Promise.resolve(); await Promise.resolve();
  const t = f.tracker({ nowPlaying: true, markWatched: true });
  t.onReady(); f.setClock(80000); f.tick();
  t.updateReporting({ nowPlaying: false, markWatched: false });
  t.updateReporting({ nowPlaying: true, markWatched: false });
  release(); await f.drain(); t.stop(); await f.drain();
  const reports = f.calls.filter(c => c.path === '/:/timeline');
  assert.deepEqual(reports.map(c => c.query.state), ['playing', 'stopped']);
  assert.equal(reports[0].query['X-Plex-Session-Identifier'], reports[1].query['X-Plex-Session-Identifier']);
  assert(!f.calls.some(c => c.path === '/:/scrobble'));
});
await test('turning off on a new channel also revokes outgoing queued watched writes', async () => {
  const f = fixture(); let release;
  f.sandbox.NostalgexWatchState.sharedQueue.enqueue(() => new Promise(resolve => { release = resolve; }));
  await Promise.resolve(); await Promise.resolve();
  const old = f.tracker({ nowPlaying: true, markWatched: true });
  old.onReady(); f.setClock(80000); f.tick(); old.stop();
  const next = f.tracker({ nowPlaying: true, markWatched: true }); next.onReady();
  next.updateReporting({ nowPlaying: false, markWatched: false });
  release(); await f.drain(); next.stop(); await f.drain();
  assert(!f.calls.some(c => c.path === '/:/scrobble' || c.path === '/:/timeline'));
});
await test('changing one toggle retains the current clock and the other control', async () => {
  const f = fixture(); const t = f.tracker({ nowPlaying: true, markWatched: false });
  await f.play(t, 30); t.updateReporting({ nowPlaying: false, markWatched: true });
  for (let n = 40; n <= 80; n += 10) { f.setClock(n * 1000); f.tick(); await f.drain(); }
  t.stop(); await f.drain();
  assert.equal(f.calls.filter(c => c.path === '/:/scrobble').length, 1);
  const reports = f.calls.filter(c => c.path === '/:/timeline');
  assert.equal(reports.findLast(c => c.query.state === 'stopped').query.state, 'stopped');
  assert.equal(reports.filter(c => c.query.state === 'stopped').length, 1);
});
if (errors.length) { console.error(errors.join('\n')); process.exit(1); }
console.log(`playback reporting controls: ${passed} checks passed (production tracker, synthetic transports)`);
