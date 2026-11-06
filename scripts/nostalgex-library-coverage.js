// Where the loaded titles land, for the library line in Settings and the COVERAGE line in the console.
//
// PARITY with the Apple TV (appletv/library-coverage-counts, Nostalgex/Nostalgex/Services/LibraryDiagnostics.swift:
// Coverage, coverage(...), coverageLine, orphanReport). Same definitions, same wording.
//
//   ON A CHANNEL     in the pool of at least one channel that would show if its package were on: a
//                    channels.json channel whose pool reaches its minItems, whether or not its package
//                    is on (seasonal ones count), or a collection or franchise channel already built.
//                    Not "on the channels in the guide now": that is a smaller number.
//   ON NO CHANNEL    every other loaded title. Nothing in channels.json takes it, so switching a package
//                    on would not bring it back. Split by kind (MOVIES, EPISODES, MUSIC VIDEOS) when more
//                    than one kind has some.
//   SKIPPED          movies and episodes the scan dropped for having no runtime. Counted by the loaders
//   (NO RUNTIME)     in plex-tuner.html, not here.
//
//   11,633 OF 11,809 ON CHANNELS · 176 ON NO CHANNEL (4 MOVIES, 172 EPISODES) · 12 SKIPPED (NO RUNTIME)
//
// The count runs every channel's rules over every title: 11,809 titles took 4.5 s in Node, 100,000 about
// 33 s. It runs in slices and gives the page back between them, so it never freezes the guide, and it stops
// at once when a newer library replaces the one it is reading. Pure apart from the timer: the page passes
// in the channel test (`passes`), so this file needs no filter, no DOM and no storage.
//
// USAGE (browser: plain <script src="scripts/nostalgex-library-coverage.js">, node: import it, then globalThis):
//   const LC = globalThis.NostalgexLibraryCoverage;
//   const cov = await LC.compute({ items, channels, passes, dynamicPools, isCancelled });   // or null if cancelled
//   LC.formatLine(cov, skippedNoRuntime);   // the Settings line, or null
//   LC.orphanReport(cov, onEnabledChannels);   // the console line
(function (global) {
  'use strict';

  const KINDS = [
    { id: 'movie', label: 'MOVIES', name: 'movie' },
    { id: 'episode', label: 'EPISODES', name: 'episode' },
    { id: 'musicVideo', label: 'MUSIC VIDEOS', name: 'musicVideo' },
  ];

  /** The Apple TV's Kind: an episode, a music video (a music video library's item), or a movie. */
  function kindOf(item) {
    if (item && item.type === 'episode') return 'episode';
    if (item && item.librarySource === 'musicVideo') return 'musicVideo';
    return 'movie';
  }

  /** A title's identity across the pools: its server and its rating key, never its URL. */
  function defaultKey(item) { return `${item.serverUrl || ''}|${item.ratingKey}`; }

  const nextTurn = () => new Promise((resolve) => setTimeout(resolve, 0));

  /**
   * @param {object} opts
   * @param {object[]} opts.items         the loaded library
   * @param {{minItems?: number}[]} opts.channels   the static channels (each is what `passes` reads)
   * @param {(item, channel) => boolean} opts.passes   whether the channel's rules take the title
   * @param {object[][]} [opts.dynamicPools]   pools of the collection and franchise channels already built
   * @param {(item) => string} [opts.keyOf]
   * @param {number} [opts.sliceMs]       how long to work before giving the page back (default 12)
   * @param {() => number} [opts.now]
   * @param {() => Promise<void>} [opts.yieldFn]   how to give the page back (default a zero timeout)
   * @param {() => boolean} [opts.isCancelled]   asked after each give-back; true stops the count
   * @param {number} [opts.sampleSize]    how many titles on no channel to keep for the log (default 25)
   * @returns {Promise<null | {loaded, onChannels, totalLoaded, totalOnChannels, totalOnNoChannel, orphanSample}>}
   */
  async function compute(opts) {
    const {
      items, channels, passes, dynamicPools = [], keyOf = defaultKey, sliceMs = 12,
      now = () => Date.now(), yieldFn = nextTurn, isCancelled = () => false, sampleSize = 25,
    } = opts;
    const n = items.length;
    const covered = new Uint8Array(n);
    let sliceStart = now();
    // Gives the page back once a slice is used up. True when the count should stop.
    const tired = () => now() - sliceStart >= sliceMs;
    const rest = async () => { await yieldFn(); sliceStart = now(); return isCancelled(); };

    for (const channel of channels) {
      const hits = [];
      for (let i = 0; i < n; i++) {
        if (passes(items[i], channel)) hits.push(i);
        if ((i & 127) === 127 && tired() && await rest()) return null;
      }
      if (hits.length >= (channel.minItems || 50)) for (const i of hits) covered[i] = 1;
      if (tired() && await rest()) return null;
    }

    const built = new Set();
    for (const pool of dynamicPools) for (const it of pool) built.add(keyOf(it));
    const loaded = {};
    const onChannels = {};
    const orphans = [];
    for (let i = 0; i < n; i++) {
      const it = items[i];
      const k = kindOf(it);
      loaded[k] = (loaded[k] || 0) + 1;
      if (covered[i] || (built.size && built.has(keyOf(it)))) onChannels[k] = (onChannels[k] || 0) + 1;
      else orphans.push(it);
      if ((i & 1023) === 1023 && tired() && await rest()) return null;
    }
    const orphanSample = orphans
      .sort((a, b) => String(a.title || '').localeCompare(String(b.title || ''), 'en', { sensitivity: 'base' }))
      .slice(0, sampleSize);
    const sum = (m) => Object.values(m).reduce((a, b) => a + b, 0);
    const totalLoaded = sum(loaded);
    const totalOnChannels = sum(onChannels);
    return { loaded, onChannels, totalLoaded, totalOnChannels, totalOnNoChannel: totalLoaded - totalOnChannels, orphanSample };
  }

  const fmt = (n) => Number(n).toLocaleString('en-US');

  /**
   * The Settings line. "ON NO CHANNEL" and "SKIPPED" are left out at zero; the split by kind shows only
   * when more than one kind has titles on no channel. Null when there is nothing to say.
   */
  function formatLine(coverage, skippedNoRuntime) {
    const parts = [];
    if (coverage && coverage.totalLoaded > 0) {
      parts.push(`${fmt(coverage.totalOnChannels)} OF ${fmt(coverage.totalLoaded)} ON CHANNELS`);
      if (coverage.totalOnNoChannel > 0) {
        let orphans = `${fmt(coverage.totalOnNoChannel)} ON NO CHANNEL`;
        const byKind = KINDS
          .map((k) => ({ k, n: (coverage.loaded[k.id] || 0) - (coverage.onChannels[k.id] || 0) }))
          .filter((x) => x.n > 0)
          .map((x) => `${fmt(x.n)} ${x.k.label}`);
        if (byKind.length > 1) orphans += ` (${byKind.join(', ')})`;
        parts.push(orphans);
      }
    }
    if (skippedNoRuntime > 0) parts.push(`${fmt(skippedNoRuntime)} SKIPPED (NO RUNTIME)`);
    return parts.length ? parts.join(' · ') : null;
  }

  /**
   * One console line for the titles on no channel, so a support report can show why. Counts, then the
   * first few by title, each with the fields the rules read. Console only: titles stay out of anything
   * that is sent anywhere. Mirrors LibraryDiagnostics.orphanReport.
   */
  function orphanReport(coverage, onEnabledChannels) {
    const counts = KINDS.map((k) => `${k.name} ${coverage.onChannels[k.id] || 0}/${coverage.loaded[k.id] || 0}`).join(', ');
    let line = `COVERAGE: ${coverage.totalOnChannels} of ${coverage.totalLoaded} on a channel with every package on, `
      + `${coverage.totalOnNoChannel} on none; ${onEnabledChannels == null ? '?' : onEnabledChannels} on the channels in the guide now (${counts})`;
    if (!coverage.orphanSample.length) return line;
    const rows = coverage.orphanSample.map((it) => {
      const year = it.year ? String(it.year) : 'no year';
      const rating = it.rating > 0 ? Number(it.rating).toFixed(1) : 'no rating';
      const genres = it.genres && it.genres.length ? it.genres.join('|') : 'no genre';
      const studio = it.studio || 'no studio';
      const cert = it.contentRating || 'unrated';
      const tmdb = it.tmdbID ? 'TMDB' : 'no TMDB';
      const name = it.type === 'episode' && it.episodeTitle ? `${it.title}: ${it.episodeTitle}` : it.title;
      return `"${name}" (${year}, ${cert}, ${rating}, ${genres}, ${studio}, ${it.duration}m, ${tmdb})`;
    });
    return `${line}. Not on any channel (first ${rows.length}): ${rows.join('; ')}`;
  }

  const api = { compute, formatLine, orphanReport, kindOf };
  global.NostalgexLibraryCoverage = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
