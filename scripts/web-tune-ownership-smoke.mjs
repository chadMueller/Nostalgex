// Offline race tests execute the production resolver/player/subtitle functions.
// All network, media, timers and DOM operations are fixtures. Aborts are deliberately
// ignored by deferred fetches to prove ownership checks, not just cancellation.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const root = new URL('../', import.meta.url);
const tuner = readFileSync(new URL('plex-tuner.html', root), 'utf8');
const urls = readFileSync(new URL('scripts/nostalgex-jellyfin-urls.js', root), 'utf8');
const playbackInfoModule = readFileSync(new URL('scripts/nostalgex-playback-info.js', root), 'utf8');
const streamQualityModule = readFileSync(new URL('scripts/nostalgex-stream-quality.js', root), 'utf8');
const htmlIds = new Set([...tuner.matchAll(/\bid=["']([^"']+)["']/g)].map(match => match[1]));
function between(start, end) {
  const a = tuner.indexOf(start), b = tuner.indexOf(end, a);
  assert(a >= 0 && b > a, `production source anchors: ${start}`);
  return tuner.slice(a, b);
}
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function fixture({ hls = false, backend = 'jellyfin', subtitles = false, reporting = false,
  fullscreen = true, realAdvancement = false, transformProduction = source => source } = {}) {
  const requests = [], cleanups = [], failures = [], trackers = [], hlsInstances = [], sources = [], attached = [], revoked = [];
  const timers = new Map(), listeners = new Map(), gestureListeners = new Map();
  const elements = new Map(), scheduleBuilds = [], nextSchedules = new Map(), playSources = [];
  let seq = 0, timerSeq = 0, playCount = 0;
  function eventTarget(registry) {
    const once = new Map();
    return {
      addEventListener(name, fn, options = {}) {
        if (!registry.has(name)) registry.set(name, new Set());
        registry.get(name).add(fn);
        if (options.once) {
          if (!once.has(name)) once.set(name, new Set());
          once.get(name).add(fn);
        }
      },
      removeEventListener(name, fn) { registry.get(name)?.delete(fn); once.get(name)?.delete(fn); },
      emit(name) {
        const event = { type: name, target: this };
        if (typeof this[`on${name}`] === 'function') this[`on${name}`](event);
        for (const fn of [...(registry.get(name) || [])]) {
          if (once.get(name)?.has(fn)) this.removeEventListener(name, fn);
          fn(event);
        }
      },
    };
  }
  const video = {
    paused: true, ended: false, currentTime: 0, style: {}, textTracks: [], error: null,
    readyState: 0, videoWidth: 0, videoHeight: 0,
    webkitDisplayingFullscreen: fullscreen, fullscreenEntries: 0, fullscreenExits: 0,
    _src: '', get src() { return this._src; }, set src(value) { this._src = value; sources.push(value); },
    get currentSrc() { return this._src; },
    // A blocked play stays paused. A rejected promise must not pretend playback began.
    playResult: null, play() {
      playCount++; playSources.push(this.src);
      if (this.playResult) return this.playResult.then(() => { this.paused = false; });
      this.paused = false;
      return Promise.resolve();
    },
    pause() { this.paused = true; }, removeAttribute() { this._src = ''; }, load() {}, canPlayType() { return true; },
    ...eventTarget(listeners),
    webkitEnterFullscreen() { this.fullscreenEntries++; this.webkitDisplayingFullscreen = true; this.emit('webkitbeginfullscreen'); },
    webkitExitFullscreen() { this.fullscreenExits++; this.webkitDisplayingFullscreen = false; this.pause(); this.emit('webkitendfullscreen'); },
    appendChild(track) { attached.push(track); this.textTracks.push(track.track); },
  };
  class Hls {
    static Events = { MANIFEST_PARSED: 'manifest', ERROR: 'error' };
    static ErrorTypes = { NETWORK_ERROR: 'network', MEDIA_ERROR: 'media' };
    static isSupported() { return hls; }
    constructor() { this.events = {}; this.destroyed = false; this.startLoads = 0; this.recoveries = 0; hlsInstances.push(this); }
    on(name, fn) { this.events[name] = fn; }
    loadSource(url) { this.src = url; sources.push(url); }
    attachMedia() {}
    destroy() { this.destroyed = true; }
    startLoad() { this.startLoads++; }
    recoverMediaError() { this.recoveries++; }
  }
  class FixtureURL extends URL {}
  FixtureURL.createObjectURL = blob => `blob:${blob.parts[0]}`;
  FixtureURL.revokeObjectURL = url => revoked.push(url);
  function element(id) {
    assert(htmlIds.has(id), `fixture element exists in production HTML: ${id}`);
    if (!elements.has(id)) {
      const classes = new Set();
      elements.set(id, { classList: { remove: name => classes.delete(name), add: name => classes.add(name), contains: name => classes.has(name) }, style: {}, textContent: '', innerHTML: '' });
    }
    return elements.get(id);
  }
  const context = {
    console: { log() {}, warn() {}, error() {} }, URL: FixtureURL, URLSearchParams, AbortController,
    Blob: class { constructor(parts) { this.parts = parts; } }, crypto: { randomUUID: () => `generated-${++seq}` },
    currentChannel: null, isDemoMode: false, mediaBackend: backend, plexServerUrl: 'https://fixture.invalid', plexToken: 'fixture-token', jellyfinUserId: 'fixture-user',
    jellyfinAuthHeader: () => `fixture-auth-${context.plexToken}`, getClientId: () => 'fixture-device',
    playbackTracker: null, currentPlayingItem: null, hlsInstance: null, syncPlexActivity: reporting,
    videoMuted: false, consecutivePlaybackFailures: 0,
    activeSubtitleTracks: [], activeSubtitleBlobUrls: [], subtitleRequestGeneration: 0, subtitleRequestController: null,
    subtitlesEnabled: subtitles, shouldAutoEnableSubs: () => false, pickSubtitle: subs => subs[0],
    pickAudioStream: () => null,
    CHANNELS: [], plexConnected: true, appState: 'connect', retroMode: false,
    fsOverlayVisible: false, fsOverlayTimer: null,
    chNum: channel => channel.id, escapeHtml: value => value, itemGuideTitle: item => item.title,
    // The schedule clock and cosmetic renderers are fixtures; switching and advancing
    // into playCurrentItem, including their real metadata updates, remain production.
    buildChannelSchedule(channel) {
      scheduleBuilds.push(channel.id);
      if (nextSchedules.has(channel.id)) { channel.schedule = nextSchedules.get(channel.id); nextSchedules.delete(channel.id); }
    },
    // What plays after a programme ends is the engine's pick, checked against the Apple TV by
    // npm run test:schedule-parity. Here it is the fixture's next schedule row.
    nextAfterEnd: channel => (channel.schedule && channel.schedule[0]) || null,
    showNowPlaying() {}, updateInfoPanel() {}, showGuide() {}, renderActiveGuide() {}, updateFsOverlay() {},
    // Watershed's card and hold test: no channel here is held (scripts/watershed-browser-smoke.mjs drives the real ones).
    hideWatershedCard() {}, holdForWatershed() {}, isWatershedHold: () => false,
    // Open on last channel: remembering the tuned channel is storage, driven for real by scripts/open-last-channel-browser-smoke.mjs.
    rememberLastChannel() {},
    buildSubtitleUrl: item => `https://fixture.invalid/subtitles/${item.ratingKey}`,
    clearVideoError() {}, showVideoError: error => failures.push(error), showPlaybackFailure: error => failures.push(error), classifyPlaybackFailure: details => details,
    document: {
      fullscreenElement: null,
      getElementById: id => id === 'plex-video' ? video : element(id),
      createElement() { return { track: {}, events: {}, removed: false, remove() { this.removed = true; }, addEventListener(name, fn) { this.events[name] = fn; } }; },
      ...eventTarget(gestureListeners),
    }, Hls,
    setTimeout(fn, delay) { const id = ++timerSeq; timers.set(id, { fn, delay }); return id; }, clearTimeout(id) { timers.delete(id); },
    makePlaybackTracker(item) { const tracker = { item, stops: 0, ready: 0, resumes: 0, pauses: 0, stop() { this.stops++; }, onReady() { this.ready++; }, onResume() { this.resumes++; }, onPause() { this.pauses++; } }; trackers.push(tracker); return tracker; },
    fetch(url, options = {}) {
      const parsed = new URL(url);
      if (parsed.pathname.endsWith('/ActiveEncodings') || parsed.pathname.endsWith('/universal/stop')) {
        cleanups.push({ url: parsed, options }); return Promise.resolve({ ok: true });
      }
      assert(parsed.pathname.includes('/PlaybackInfo') || parsed.pathname.startsWith('/subtitles/'), `unexpected fixture fetch: ${url}`);
      const wait = deferred(); requests.push({ url: parsed, options, ...wait }); return wait.promise;
    },
  };
  context.window = context;
  vm.createContext(context);
  const production = urls + streamQualityModule + playbackInfoModule
    + between('  let activeTranscodeSession = null;', "  let appState = 'connect'")
    + between('  function switchChannel(', '  async function getJellyfinTranscodeUrl(')
    + between('  async function getJellyfinTranscodeUrl(', '  // ── Playback tracking')
    + between('  let pendingPlayRetry = null;', '  function showNowPlaying(')
    + between('  function clearSubtitleTracks(', '  function setAudioLanguage(')
    + between('  function isVideoFullscreen(', '  // Pause the watch clock when the tab is hidden')
    + `\nfunction inspectOwnership() { return { activePlaybackRequest, activeTranscodeSession, pendingPlayRetry }; }`;
  vm.runInContext(transformProduction(production), context);
  let ended = 0;
  // Observe advancement without synthesizing another schedule; failure/timer handlers remain production.
  if (!realAdvancement) context.onItemEnded = () => { ended++; };
  function tune(item, channelId = 1) { context.currentChannel = channelId; return context.playCurrentItem(item, { id: channelId }); }
  function select(item, channelId = 1) {
    let channel = context.CHANNELS.find(ch => ch.id === channelId);
    if (!channel) {
      channel = { id: channelId, enabled: true, name: `Fixture ${channelId}`, color: '#abc', itemPool: [] };
      context.CHANNELS.push(channel);
    }
    channel.schedule = item ? [item] : [];
    context.switchChannel(channelId);
    return flush();
  }
  function info(index, id, { body = null, ok = true } = {}) {
    requests[index].resolve({ ok, json: () => body ? body.promise : Promise.resolve({ PlaySessionId: `session-${id}`, MediaSources: [{ Id: id, TranscodingUrl: `/Videos/${id}/master.m3u8?PlaySessionId=session-${id}` }] }) });
  }
  return { context, video, requests, cleanups, failures, trackers, timers, listeners, hlsInstances, sources, attached, revoked, tune, select, info,
    element, scheduleBuilds, nextSchedules, playSources, gestureListeners,
    setFullscreen(value) { context.document.fullscreenElement = null; video.webkitDisplayingFullscreen = value; },
    get playCount() { return playCount; }, get ended() { return ended; } };
}
const transcode = id => ({ ratingKey: id, partKey: id, _forceTranscode: true, title: id });
const direct = (id, offset = 0) => ({ ratingKey: id, partKey: id, container: 'mp4', videoCodec: 'h264', audioCodec: 'aac', title: id, offsetSeconds: offset });
let count = 0;
async function test(name, run) { await run(); count++; console.log(`  ok ${name}`); }

await test('A -> B resolving B -> A cannot replace B, including loader/tracker/session', async () => {
  const f = fixture({ reporting: true });
  const a = f.tune(transcode('A'), 1), b = f.tune(transcode('B'), 2);
  assert.equal(f.requests[0].options.signal.aborted, true);
  f.info(1, 'B'); await b;
  f.info(0, 'A'); await a;
  assert.equal(f.context.currentPlayingItem.ratingKey, 'B');
  assert.match(f.video.src, /\/B\/master/);
  assert.deepEqual(f.trackers.map(t => t.item.ratingKey), ['B']);
  assert.equal(f.context.inspectOwnership().activeTranscodeSession.id, 'session-B');
  assert.deepEqual(f.cleanups.map(c => c.url.searchParams.get('playSessionId')), ['session-A']);
  assert.equal(f.cleanups[0].options.method, 'DELETE');
  f.context.stopVideo();
  assert.deepEqual(f.cleanups.map(c => c.url.searchParams.get('playSessionId')), ['session-A', 'session-B']);
});
await test('A -> B -> A rejects first A even when channel and item object match again', async () => {
  const f = fixture(); const sameA = transcode('A');
  const a1 = f.tune(sameA, 1), b = f.tune(transcode('B'), 2), a2 = f.tune(sameA, 1);
  f.info(2, 'A-new'); await a2;
  f.info(0, 'A-old'); await a1;
  f.info(1, 'B'); await b;
  assert.match(f.video.src, /A-new/);
  assert.equal(f.context.inspectOwnership().activeTranscodeSession.id, 'session-A-new');
  assert.deepEqual(f.cleanups.map(c => c.url.searchParams.get('playSessionId')), ['session-A-old', 'session-B']);
});
await test('response body delayed beyond disconnect is discarded and its exact old session released', async () => {
  const f = fixture(); const body = deferred(); const pending = f.tune(transcode('A'));
  f.info(0, 'A', { body }); await flush();
  f.context.stopVideo();
  f.context.mediaBackend = 'plex'; f.context.plexServerUrl = 'https://new.invalid'; f.context.plexToken = 'new-fixture-token';
  body.resolve({ PlaySessionId: 'old-session', MediaSources: [{ Id: 'A', TranscodingUrl: '/A.m3u8?PlaySessionId=old-session' }] });
  await pending;
  assert.equal(f.context.currentPlayingItem, null); assert.equal(f.video.src, '');
  assert.equal(f.cleanups[0].url.host, 'fixture.invalid');
  assert.equal(f.cleanups[0].url.searchParams.get('playSessionId'), 'old-session');
  assert.equal(f.cleanups[0].options.headers.Authorization, 'fixture-auth-fixture-token');
});
await test('aborted resolver rejection does not start a fallback or display a failure', async () => {
  const f = fixture(); const a = f.tune(transcode('A')); await f.tune(direct('B'), 2);
  const error = new Error('aborted'); error.name = 'AbortError'; f.requests[0].reject(error); await a;
  assert.equal(f.context.currentPlayingItem.ratingKey, 'B'); assert.equal(f.sources.length, 1);
  assert.equal(f.failures.length, 0); assert.equal(f.cleanups.length, 0);
});
await test('current resolver failure still uses its owned fallback and cleans it up', async () => {
  const f = fixture(); const a = f.tune(transcode('A')); f.requests[0].reject(new Error('fixture outage')); await a;
  assert.match(f.video.src, /master.m3u8/);
  const session = f.context.inspectOwnership().activeTranscodeSession;
  assert(session.id); f.context.stopVideo();
  assert.equal(f.cleanups[0].url.searchParams.get('playSessionId'), session.id);
});
await test('Plex cleanup is scoped to the outgoing item server and does not stop replacement session', async () => {
  const f = fixture({ backend: 'plex' });
  await f.tune({ ...transcode('A'), serverUrl: 'https://a.invalid', serverToken: 'a-fixture' });
  const old = f.context.inspectOwnership().activeTranscodeSession;
  await f.tune({ ...transcode('B'), serverUrl: 'https://b.invalid', serverToken: 'b-fixture' }, 2);
  const current = f.context.inspectOwnership().activeTranscodeSession;
  assert.notEqual(old.id, current.id); assert.equal(f.cleanups.length, 1);
  assert.equal(f.cleanups[0].url.host, 'a.invalid'); assert.equal(f.cleanups[0].url.searchParams.get('session'), old.id);
  assert.equal(current.stopped, undefined);
});
await test('queued native metadata and media callbacks cannot seek, play, report or skip the new item', async () => {
  const f = fixture({ reporting: true }); await f.tune(direct('A', 120));
  const oldMetadata = [...f.listeners.get('loadedmetadata')][0];
  const oldEvents = [f.video.onplaying, f.video.onpause, f.video.onended, f.video.onerror, f.video.onwaiting];
  f.video.onplaying(); const oldStall = [...f.timers.values()].find(t => t.delay === 8000).fn;
  await f.tune(direct('B', 30), 2);
  oldMetadata(); oldEvents.forEach(fn => fn()); oldStall();
  assert.equal(f.video.currentTime, 0); assert.equal(f.playCount, 0); assert.equal(f.ended, 0);
  assert.equal(f.trackers[1].ready, 0); assert.equal(f.trackers[1].pauses, 0);
  assert.equal(f.listeners.get('loadedmetadata').size, 1);
  [...f.listeners.get('loadedmetadata')][0](); assert.equal(f.video.currentTime, 30); assert.equal(f.playCount, 1);
});
await test('queued HLS errors and manifest events from destroyed loader cannot affect new loader', async () => {
  const f = fixture({ backend: 'plex', hls: true }); await f.tune(transcode('A'));
  const old = f.hlsInstances[0]; await f.tune(transcode('B'), 2);
  old.events.manifest();
  old.events.error(null, { fatal: true, details: 'manifestLoadError', type: 'network', response: { code: 404 } });
  old.events.error(null, { fatal: true, details: 'fragment', type: 'network' });
  assert.equal(old.destroyed, true); assert.equal(old.startLoads, 0); assert.equal(f.hlsInstances[1].destroyed, false);
  assert.equal(f.context.consecutivePlaybackFailures, 0); assert.equal(f.playCount, 0); assert.equal(f.failures.length, 0);
});
await test('old failure skip remains inert after returning to same channel and exact item', async () => {
  const f = fixture({ backend: 'plex' }); const item = transcode('A'); await f.tune(item);
  f.video.onerror(); const skip = [...f.timers.values()].find(t => t.delay === 5000).fn;
  await f.tune(transcode('B'), 2); await f.tune(item, 1); skip();
  assert.equal(f.ended, 0); assert.equal(f.context.currentPlayingItem, item);
});
await test('late autoplay rejection cannot arm a gesture retry for the next program', async () => {
  const f = fixture(); await f.tune(direct('A')); const rejectedPlay = deferred(); f.video.playResult = rejectedPlay.promise;
  [...f.listeners.get('loadedmetadata')][0](); await f.tune(direct('B'), 2);
  rejectedPlay.reject(new Error('fixture autoplay blocked')); await flush();
  assert.equal(f.context.inspectOwnership().pendingPlayRetry, null);
});
await test('subtitle A response ignored after B, including body await and stale track callbacks', async () => {
  const f = fixture({ subtitles: true });
  const a = { ...direct('A'), subtitles: [{ lang: 'en', index: 1 }] }, b = { ...direct('B'), subtitles: [{ lang: 'en', index: 1 }] };
  await f.tune(a); const body = deferred(); f.requests[0].resolve({ ok: true, text: () => body.promise }); await flush();
  await f.tune(b, 2); assert.equal(f.requests[0].options.signal.aborted, true);
  f.requests[1].resolve({ ok: true, text: async () => 'B-vtt' }); await flush();
  body.resolve('A-vtt'); await flush();
  assert.deepEqual(f.attached.map(t => t.src), ['blob:B-vtt']);
  const track = f.attached[0], delayedShow = [...f.timers.values()].find(t => t.delay === 300).fn;
  f.setFullscreen(false); f.context.clearSubtitleTracks(); track.events.load(); delayedShow();
  assert.notEqual(track.track.mode, 'showing'); assert.equal(track.removed, true);
  assert.deepEqual(f.revoked, ['blob:B-vtt']);
});
await test('same-item subtitle reload keeps only the latest preference request', async () => {
  const f = fixture({ subtitles: true }); const a = { ...direct('A'), subtitles: [{ lang: 'en', index: 1 }] };
  await f.tune(a); const newSub = f.context.loadSubtitleForCurrentItem(a);
  f.requests[1].resolve({ ok: true, text: async () => 'new-language' }); await newSub;
  f.requests[0].resolve({ ok: true, text: async () => 'old-language' }); await flush();
  assert.deepEqual(f.attached.map(t => t.src), ['blob:new-language']);
});
await test('connection token replacement without completed tune also invalidates late resolver', async () => {
  const f = fixture(); const a = f.tune(transcode('A')); f.context.plexToken = 'new-token'; f.info(0, 'A'); await a;
  assert.equal(f.context.currentPlayingItem, null); assert.equal(f.sources.length, 0);
  assert.equal(f.cleanups[0].url.searchParams.get('ApiKey'), 'fixture-token');
});
await test('late result sharing the active server session id cannot stop the current owner', async () => {
  const f = fixture(); const a = f.tune(transcode('A')), b = f.tune(transcode('B'), 2);
  f.info(1, 'shared'); await b; f.info(0, 'shared'); await a;
  assert.equal(f.cleanups.length, 0); assert.match(f.video.src, /shared/);
  f.context.stopVideo(); assert.equal(f.cleanups.length, 1);
});
await test('stale PlaybackInfo with no URL still releases its returned server session', async () => {
  const f = fixture(); const a = f.tune(transcode('A')); await f.tune(direct('B'), 2);
  f.requests[0].resolve({ ok: true, json: async () => ({ PlaySessionId: 'unused-session', MediaSources: [] }) }); await a;
  assert.equal(f.context.currentPlayingItem.ratingKey, 'B');
  assert.equal(f.cleanups[0].url.searchParams.get('playSessionId'), 'unused-session');
});
await test('selecting an empty channel retires outgoing playback and pending resolution', async () => {
  const f = fixture(); const a = f.tune(transcode('A'));
  f.context.CHANNELS = [{ id: 2, enabled: true, schedule: [] }];
  f.context.switchChannel(2); assert.equal(f.requests[0].options.signal.aborted, true);
  f.info(0, 'A'); await a;
  assert.equal(f.context.currentPlayingItem, null); assert.equal(f.video.src, '');
});
await test('Jellyfin user replacement invalidates a pending request even with the same token', async () => {
  const f = fixture(); const a = f.tune(transcode('A')); f.context.jellyfinUserId = 'next-user';
  f.info(0, 'A'); await a;
  assert.equal(f.context.currentPlayingItem, null); assert.equal(f.cleanups.length, 1);
});
// These paths enter through the production UI functions and registered callbacks.
// Fixtures still do not establish browser layout, codec support or WebKit policy.
async function assertSwitchRace(transformProduction) {
  const f = fixture({ reporting: true, transformProduction });
  await f.select(transcode('A'), 1);
  await f.select(transcode('B'), 2);
  f.info(1, 'B'); await flush();
  f.info(0, 'A'); await flush();
  assert.equal(f.context.currentPlayingItem.ratingKey, 'B');
  assert.equal(f.context.currentChannel, 2);
  assert.equal(f.element('np-title').textContent, 'B');
  assert.match(f.element('np-channel-tag').textContent, /CH 02/);
  assert.match(f.video.src, /\/B\/master/);
  assert.deepEqual(f.trackers.map(t => t.item.ratingKey), ['B']);
  assert.equal(f.context.inspectOwnership().activeTranscodeSession.id, 'session-B');
  assert.deepEqual(f.cleanups.map(c => c.url.searchParams.get('playSessionId')), ['session-A']);
}
await test('populated switchChannel keeps UI, player, tracker and session on B after late A', () => assertSwitchRace());

await test('populated switchChannel A -> B -> A rejects the first A request', async () => {
  const f = fixture(); const a = transcode('A');
  await f.select(a, 1); await f.select(transcode('B'), 2); await f.select(a, 1);
  f.info(2, 'A-new'); await flush();
  f.info(0, 'A-old'); f.info(1, 'B'); await flush();
  assert.equal(f.element('np-title').textContent, 'A');
  assert.equal(f.context.currentChannel, 1);
  assert.match(f.video.src, /A-new/);
  assert.equal(f.context.inspectOwnership().activeTranscodeSession.id, 'session-A-new');
  assert.deepEqual(f.cleanups.map(c => c.url.searchParams.get('playSessionId')), ['session-A-old', 'session-B']);
});

await test('production onItemEnded advances the current schedule and ignores an outgoing ended callback', async () => {
  const f = fixture({ realAdvancement: true, reporting: true, fullscreen: false });
  await f.select(direct('A'), 1);
  f.video.emit('loadedmetadata'); f.video.emit('playing');
  const oldEnded = f.video.onended;
  f.nextSchedules.set(1, [direct('B')]); f.video.emit('ended'); await flush();
  assert.equal(f.context.currentPlayingItem.ratingKey, 'B');
  assert.equal(f.element('np-title').textContent, 'B');
  assert.equal(f.trackers[0].stops, 1);
  assert.deepEqual(f.scheduleBuilds, [1]);
  oldEnded(); assert.deepEqual(f.scheduleBuilds, [1]);
  f.nextSchedules.set(1, [direct('C')]); f.video.emit('ended'); await flush();
  assert.equal(f.context.currentPlayingItem.ratingKey, 'C');
  assert.equal(f.element('np-title').textContent, 'C');
  assert.deepEqual(f.scheduleBuilds, [1, 1]);
});

await test('a rejected play stays paused and retries once on each supported viewer gesture', async () => {
  for (const event of ['pointerdown', 'touchend', 'keydown']) {
    const f = fixture({ fullscreen: false }); await f.select(direct('A'));
    const blocked = deferred(); f.video.playResult = blocked.promise;
    f.video.emit('loadedmetadata'); assert.equal(f.video.paused, true);
    blocked.reject(new Error('fixture NotAllowedError')); await flush();
    assert.equal(f.video.paused, true);
    assert.equal(typeof f.context.inspectOwnership().pendingPlayRetry, 'function');
    f.video.playResult = null; f.context.document.emit(event); await flush();
    assert.equal(f.playCount, 2); assert.equal(f.video.paused, false);
    assert.equal(f.context.inspectOwnership().pendingPlayRetry, null);
    for (const name of ['pointerdown', 'touchend', 'keydown']) {
      assert.equal(f.gestureListeners.get(name).size, 0);
      f.context.document.emit(name);
    }
    assert.equal(f.playCount, 2);
  }
});

async function assertQueuedGestureGuard(transformProduction) {
  const f = fixture({ transformProduction }); await f.select(direct('A'), 1);
  const a = deferred(); f.video.playResult = a.promise; f.video.emit('loadedmetadata');
  a.reject(new Error('fixture A blocked')); await flush();
  const oldRetry = f.context.inspectOwnership().pendingPlayRetry;
  assert.equal(typeof oldRetry, 'function');
  await f.select(direct('B'), 2);
  const b = deferred(); f.video.playResult = b.promise; f.video.emit('loadedmetadata');
  b.reject(new Error('fixture B blocked')); await flush();
  const currentRetry = f.context.inspectOwnership().pendingPlayRetry;
  const before = f.playCount;
  // Removal cannot recall an already queued event, so invoke the captured callback.
  oldRetry();
  assert.equal(f.playCount, before);
  assert.equal(f.context.inspectOwnership().pendingPlayRetry, currentRetry);
  f.video.playResult = null; f.context.document.emit('touchend'); await flush();
  assert.equal(f.playCount, before + 1);
  assert.match(f.playSources.at(-1), /\/B\//);
}
await test('queued outgoing gesture cannot play B early or disarm its own current retry', () => assertQueuedGestureGuard());

async function assertManifestGuard(transformProduction) {
  const f = fixture({ hls: true, backend: 'plex', transformProduction });
  await f.select(transcode('A'), 1); const old = f.hlsInstances[0];
  await f.select(transcode('B'), 2);
  old.events.manifest(); assert.equal(f.playCount, 0);
  f.hlsInstances[1].events.manifest(); assert.equal(f.playCount, 1);
  assert.equal(old.destroyed, true);
}
await test('only the current HLS manifest can start playback through the UI tune path', () => assertManifestGuard());

async function assertNativeFullscreenLifecycle(transformProduction) {
  const f = fixture({ fullscreen: false, subtitles: true, transformProduction });
  const withSubs = id => ({ ...direct(id), subtitles: [{ lang: 'en', index: 1 }] });
  await f.select(withSubs('A'), 1);
  assert.equal(f.requests.length, 0);
  f.context.toggleFullscreen();
  assert.equal(f.video.fullscreenEntries, 1);
  assert.equal(f.context.isVideoFullscreen(), true);
  assert.equal(f.requests.length, 1);
  await f.select(withSubs('B'), 2);
  assert.equal(f.requests[0].options.signal.aborted, true);
  f.context.toggleFullscreen();
  assert.equal(f.video.fullscreenExits, 1);
  assert.equal(f.context.isVideoFullscreen(), false);
  assert.equal(f.playCount, 1);
  assert.equal(f.video.paused, false);
  assert.match(f.playSources[0], /\/B\//);
  for (const request of f.requests) request.resolve({ ok: true, text: async () => 'late-vtt' });
  await flush(); assert.equal(f.attached.length, 0);
  f.context.stopVideo(); const plays = f.playCount;
  f.video.emit('webkitendfullscreen'); assert.equal(f.playCount, plays);
  assert.equal(f.video.src, '');
}
await test('registered native fullscreen callbacks resume the current item inline and discard late subtitles', () => assertNativeFullscreenLifecycle());

await test('registered document fullscreenchange cancels subtitle work when leaving fullscreen', async () => {
  const f = fixture({ fullscreen: false, subtitles: true });
  const item = { ...direct('A'), subtitles: [{ lang: 'en', index: 1 }] };
  await f.select(item);
  f.context.document.fullscreenElement = f.element('video-container');
  f.context.document.emit('fullscreenchange');
  assert.equal(f.requests.length, 1);
  f.context.document.fullscreenElement = null;
  f.context.document.emit('fullscreenchange');
  assert.equal(f.requests[0].options.signal.aborted, true);
  f.requests[0].resolve({ ok: true, text: async () => 'late-vtt' }); await flush();
  assert.equal(f.attached.length, 0);
});

// ── PLAYBACK INFORMATION inside the real playback code ──────────────────────
// The panel reads playbackInfoRows(). Each programme has a generation and each try at
// playing it an attempt; only the attempt that is current may mark it ready.
const rowValue = (f, id) => (f.context.playbackInfoRows().find(r => r.id === id) || {}).value;
const playingListeners = f => [...(f.listeners.get('playing') || [])];

async function assertInfoLateCallbackGuard(transformProduction) {
  const f = fixture({ transformProduction });
  await f.tune(direct('A'), 1);
  const lateA = playingListeners(f);
  assert.equal(lateA.length, 1);
  const b = f.tune(transcode('B'), 2);
  assert.equal(rowValue(f, 'delivery'), 'Loading');
  lateA.forEach(fn => fn({ type: 'playing' }));   // A's event, delivered after B was tuned
  assert.equal(rowValue(f, 'delivery'), 'Loading');
  assert.equal(rowValue(f, 'presentation'), 'Unknown');
  f.info(0, 'B'); await b;
  f.video.videoWidth = 1280; f.video.videoHeight = 720;
  f.video.emit('playing');
  assert.equal(rowValue(f, 'delivery'), 'Server stream');
  assert.equal(rowValue(f, 'presentation'), '1280 × 720');
  assert.equal(rowValue(f, 'reason'), 'Server streaming was selected for this source.');
}
await test('info: an old programme\'s late playing event cannot mark the new one ready', () => assertInfoLateCallbackGuard());

await test('info: direct play fields, then nothing once playback stops', async () => {
  const f = fixture({ backend: 'emby' });
  await f.tune(direct('A'), 1);
  assert.equal(rowValue(f, 'backend'), 'Emby');
  assert.equal(rowValue(f, 'delivery'), 'Loading');
  assert.equal(rowValue(f, 'quality'), 'Up to 120 Mbps');
  assert.equal(rowValue(f, 'source'), 'Video: H.264 · Audio: AAC');
  f.video.videoWidth = 1920; f.video.videoHeight = 1080; f.video.emit('playing');
  assert.equal(rowValue(f, 'delivery'), 'Direct Play');
  assert.equal(rowValue(f, 'presentation'), '1920 × 1080');
  assert.equal(rowValue(f, 'reason'), 'No fallback used.');
  const text = JSON.stringify(f.context.playbackInfoRows());
  for (const forbidden of ['fixture.invalid', 'fixture-token', 'fixture-user', 'fixture-device', '/Videos/']) {
    assert.equal(text.includes(forbidden), false, forbidden);
  }
  f.context.stopVideo();
  assert.equal(f.context.playbackInfoRows().length, 0, 'unavailable once nothing is playing');
});

await test('info: a failed direct play keeps the programme, says why, and ignores the old attempt', async () => {
  const f = fixture();
  await f.tune(direct('A'), 1);
  const oldAttempt = playingListeners(f);
  f.video.onerror();
  assert.equal(rowValue(f, 'reason'), 'Direct Play failed. Trying a server stream.');
  assert.equal(rowValue(f, 'delivery'), 'Loading');
  oldAttempt.forEach(fn => fn({ type: 'playing' }));
  assert.equal(rowValue(f, 'delivery'), 'Loading');
  f.info(0, 'A'); await flush();
  f.video.emit('playing');
  assert.equal(rowValue(f, 'delivery'), 'Server stream');
  assert.equal(rowValue(f, 'reason'), 'Direct Play failed. Trying a server stream.');
});

await test('info: an hls.js retry is a new attempt, and the old ready does not carry over', async () => {
  const f = fixture({ backend: 'plex', hls: true });
  await f.tune(transcode('A'), 1);
  f.video.emit('playing');
  assert.equal(rowValue(f, 'delivery'), 'Server stream');
  f.hlsInstances[0].events.error(null, { fatal: true, details: 'fragLoadError', type: 'network' });
  assert.equal(f.hlsInstances[0].startLoads, 1);
  assert.equal(rowValue(f, 'delivery'), 'Loading');
  assert.equal(rowValue(f, 'reason'), 'The player could not open the stream. Retrying it once.');
  f.video.paused = false; f.video.readyState = 4; f.video.emit('timeupdate');
  assert.equal(rowValue(f, 'delivery'), 'Server stream', 'a picture that never stopped still counts');
});

// ── Emby in the real playback code ───────────────────────────────────────
const bodyOf = request => JSON.parse(request.options.body);
await test('Emby: the retry after a failed direct play asks PlaybackInfo for a server stream only', async () => {
  const f = fixture({ backend: 'emby' });
  await f.tune(direct('A'), 1);
  f.video.onerror();
  const body = bodyOf(f.requests[0]);
  assert.equal(body.EnableDirectPlay, false);
  assert.equal(body.EnableDirectStream, false);
  assert.equal(body.MediaSourceId, 'A');
  assert.match(f.requests[0].url.pathname, /\/Items\/A\/PlaybackInfo$/);
  assert.equal(f.requests[0].url.searchParams.get('userId'), 'fixture-user');
});
await test('Emby: a first-attempt server stream lets Emby decide (no flags)', async () => {
  const f = fixture({ backend: 'emby' });
  const a = f.tune(transcode('A'), 1);
  const body = bodyOf(f.requests[0]);
  assert.equal('EnableDirectPlay' in body, false);
  assert.equal('EnableDirectStream' in body, false);
  f.info(0, 'A'); await a;
});
await test('Jellyfin unchanged: the same retry sends the same body as before, no flags', async () => {
  const f = fixture({ backend: 'jellyfin' });
  await f.tune(direct('A'), 1);
  f.video.onerror();
  const body = bodyOf(f.requests[0]);
  // SubtitleStreamIndex (-1, no subtitle burned into the video) goes to both servers on every
  // attempt since 2026-10-19; see scripts/nostalgex-jellyfin-subtitles-smoke.mjs.
  assert.equal(Object.keys(body).sort().join(), 'DeviceProfile,MaxStreamingBitrate,MediaSourceId,StartTimeTicks,SubtitleStreamIndex');
});
await test('Emby: direct play URL, MediaBrowser auth on PlaybackInfo, and the encode is stopped by its own session', async () => {
  const f = fixture({ backend: 'emby' });
  await f.tune(direct('A'), 1);
  assert.equal(f.video.src, 'https://fixture.invalid/Videos/A/stream.mp4?Static=true&MediaSourceId=A&api_key=fixture-token');
  const b = f.tune(transcode('B'), 2);
  assert.equal(f.requests[0].options.headers.Authorization, 'fixture-auth-fixture-token');
  f.info(0, 'B'); await b;
  f.context.stopVideo();
  assert.equal(f.cleanups.length, 1);
  assert.equal(f.cleanups[0].options.method, 'DELETE');
  assert.equal(f.cleanups[0].url.pathname, '/Videos/ActiveEncodings');
  assert.equal(f.cleanups[0].url.searchParams.get('playSessionId'), 'session-B');
});
await test('Emby: a user change invalidates a pending request, as on Jellyfin', async () => {
  const f = fixture({ backend: 'emby' }); const a = f.tune(transcode('A')); f.context.jellyfinUserId = 'next-user';
  f.info(0, 'A'); await a;
  assert.equal(f.context.currentPlayingItem, null); assert.equal(f.cleanups.length, 1);
});
await test('switching backend from Jellyfin to Emby mid-resolve invalidates the old request', async () => {
  const f = fixture({ backend: 'jellyfin' }); const a = f.tune(transcode('A')); f.context.mediaBackend = 'emby';
  f.info(0, 'A'); await a;
  assert.equal(f.context.currentPlayingItem, null); assert.equal(f.cleanups.length, 1);
});

// In-memory negative controls must fail a specific behavioral assertion, not a
// missing extraction anchor or fixture exception. Production files are never edited.
function replaceOnce(source, before, after) {
  const targets = source.split(before).length - 1;
  if (targets !== 1) throw new Error(`negative control needs one production target, found ${targets}`);
  return source.replace(before, after);
}
let negativeCount = 0;
async function negative(name, scenario, transform, expected, actual) {
  await test(`negative control: ${name}`, async () => {
    await assert.rejects(() => scenario(transform), error =>
      error.code === 'ERR_ASSERTION' && error.operator === 'strictEqual'
      && error.expected === expected && error.actual === actual);
  });
  negativeCount++;
}
await negative('bypassing request ownership is caught by the real switchChannel race', assertSwitchRace,
  source => replaceOnce(source, between('  function ownsPlaybackRequest(', '  function stopTranscodeSession('),
    '  function ownsPlaybackRequest(request) { return !!request; }\n\n'), 'B', 'A');
await negative('removing the queued gesture guard is caught before B is played early', assertQueuedGestureGuard,
  source => replaceOnce(source, 'const retry = () => {\n      if (!ownsPlaybackRequest(request)) return;', 'const retry = () => {'), 2, 3);
await negative('removing the old HLS manifest guard is caught', assertManifestGuard,
  source => replaceOnce(source, 'hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => {\n        if (!ownsPlaybackRequest(request)) return;',
    'hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => {'), 0, 1);
await negative('removing native fullscreen resume is caught by the registered callback test', assertNativeFullscreenLifecycle,
  source => replaceOnce(source, 'if (video.paused && !video.ended && (video.src || video.currentSrc)) startVideoPlayback(video);',
    '/* negative control: native fullscreen resume omitted */'), 1, 0);
// Two layers keep a late event off the panel: request ownership, and the programme
// generation plus attempt the listener registered with. Remove both and the old
// programme's event marks the new one ready.
await negative('an unguarded ready listener is caught by the late-callback test', assertInfoLateCallbackGuard,
  source => replaceOnce(source,
    '    const mark = () => {\n      if (!ownsPlaybackRequest(request)) return;\n      if (info === playbackInfo && info.markReady(generation, attempt)) stop();\n    };',
    '    const mark = () => { if (playbackInfo && playbackInfo.markReady(playbackInfo.generation, playbackInfo.attemptId)) stop(); };'),
  'Loading', 'Server stream');
console.log(`web tune ownership: ${count - negativeCount} production-function scenarios and ${negativeCount} negative controls passed (offline)`);
