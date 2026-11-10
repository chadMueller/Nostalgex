// STOP WAITING during a slow library scan, for the web tuner and the Docker tuner (Trello:
// "Web tuner + Docker: STOP WAITING during a slow library scan (parity)").
//
// WEB ONLY. The Apple TV has LibraryLoadStallWatch.swift and the Roku app has
// roku/source/util/LoadStall.brs; this is the same watch for the browser, with the same two
// numbers and the same rule. Nothing here is shared with them, so keep it out of the engine
// files the Roku app copies.
//
// The rule (Apple TV): only the ABSENCE of forward progress counts, never elapsed time. A big
// library over a thin link legitimately takes minutes, and abandoning that would punish the
// people this is for. The scan's counters are sampled every 2 s; any change at all is progress.
//   quiet for WARN_AFTER_MS  (60 s)   the loading screen says so and offers STOP WAITING
//   quiet for STALL_AFTER_MS (210 s)  the scan is abandoned on its own
// STOP WAITING abandons it at once. Either way the caller keeps every section it finished (and,
// on Jellyfin and Emby, the pages it had read of the one in flight), says the library is not
// whole, and does not save it as the library (the next visit reads it again).
//
// One difference from the Apple TV, taken from the Roku port (LoadStall.brs, found on a stick on
// 2026-11-04): a look that comes later than PAUSE_GAP_MS after the last one means the page was
// asleep (a laptop lid, a throttled background tab), not that the server was quiet, so the gap is
// not counted. The Apple TV compares wall-clock dates and would have abandoned that scan.
//
// A press belongs to the server it was made on (Apple TV #146): every scan starts a watch of its
// own, and a stopped watch can never be pressed again.
//
// USAGE (browser: plain <script src="scripts/nostalgex-load-stall.js">, node: import it, then
// globalThis):
//
//   const w = NostalgexLoadStall.watch({
//     sample: () => NostalgexLoadStall.sampleKey(LL.state, answers),
//     onVerdict: (v) => showStopWaiting(v === 'slow'),
//     onAbandon: (userInitiated, quietMs) => controller.abort(),
//   });
//   ... the scan ...
//   w.stop();                  // always, in a finally
//   w.stopWaiting();           // the button
//   w.abandoned                // null, or { userInitiated, quietMs }

(function (global) {
  'use strict';

  const WARN_AFTER_MS = 60000;
  const STALL_AFTER_MS = 210000;
  const POLL_MS = 2000;
  const PAUSE_GAP_MS = 20000;

  /**
   * The counters a healthy scan keeps moving, as one string. Any field changing means the load is
   * still doing something. `answers` is the count of server answers the scan has taken (a page, a
   * section list): the counters in `state` alone do not move while the pages of one big section
   * come in, and a TV section reading episodes moves none of them.
   */
  function sampleKey(state, answers) {
    return [state.phase, state.detail, state.scanSectionIndex, state.scanTotalSections, state.scanItemsFound, answers || 0].join('|');
  }

  /** Apple TV's LibraryLoadStallDetector. Verdicts: 'progressing', 'slow', 'stalled'. */
  function createDetector(startSample, nowMs, opts) {
    const warnAfterMs = (opts && opts.warnAfterMs) || WARN_AFTER_MS;
    const stallAfterMs = (opts && opts.stallAfterMs) || STALL_AFTER_MS;
    let lastSample = startSample;
    let changedAt = nowMs;
    let lookedAt = nowMs;
    return {
      /** Called on every look. Returns { verdict, quietMs }. */
      evaluate(sample, now) {
        // The page was asleep for this gap, not the server quiet.
        const gap = now - lookedAt;
        if (gap >= PAUSE_GAP_MS) changedAt += gap;
        lookedAt = now;
        if (sample !== lastSample) {
          lastSample = sample;
          changedAt = now;
          return { verdict: 'progressing', quietMs: 0 };
        }
        const quietMs = now - changedAt;
        if (quietMs >= stallAfterMs) return { verdict: 'stalled', quietMs };
        if (quietMs >= warnAfterMs) return { verdict: 'slow', quietMs };
        return { verdict: 'progressing', quietMs };
      },
    };
  }

  /**
   * Starts watching one scan. Options: sample() -> string; onVerdict('progressing'|'slow'|'stalled',
   * quietMs) on every look; onAbandon(userInitiated, quietMs) once, when the scan is to be given up.
   * opts.warnAfterMs / stallAfterMs / pollMs / now / setInterval / clearInterval are for tests.
   */
  function watch(opts) {
    const now = opts.now || Date.now;
    const setIv = opts.setInterval || global.setInterval.bind(global);
    const clearIv = opts.clearInterval || global.clearInterval.bind(global);
    const detector = createDetector(opts.sample(), now(), opts);
    let timer = null;
    let stopped = false;
    const w = { abandoned: null, stop, stopWaiting };

    function abandon(userInitiated, quietMs) {
      if (stopped || w.abandoned) return;
      w.abandoned = { userInitiated, quietMs };
      stop();
      if (opts.onVerdict) opts.onVerdict('progressing', 0); // the STOP WAITING block goes with the scan
      if (opts.onAbandon) opts.onAbandon(userInitiated, quietMs);
    }
    function stop() {
      stopped = true;
      if (timer != null) { clearIv(timer); timer = null; }
    }
    function stopWaiting() {
      // A press after this watch ended (the scan finished, or another server's scan has its own
      // watch now) is nothing.
      if (stopped) return false;
      abandon(true, 0);
      return true;
    }
    timer = setIv(() => {
      if (stopped) return;
      const r = detector.evaluate(opts.sample(), now());
      if (opts.onVerdict) opts.onVerdict(r.verdict, r.quietMs);
      if (r.verdict === 'stalled') abandon(false, r.quietMs);
    }, opts.pollMs || POLL_MS);
    return w;
  }

  global.NostalgexLoadStall = { WARN_AFTER_MS, STALL_AFTER_MS, POLL_MS, PAUSE_GAP_MS, sampleKey, createDetector, watch };
})(typeof globalThis !== 'undefined' ? globalThis : window);
