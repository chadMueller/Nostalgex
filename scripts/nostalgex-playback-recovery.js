// Playback recovery: the starvation watch, the failure run and the capped retry, as the Apple TV has them.
// PARITY with tvOS (and the Roku and Android ports):
//   Nostalgex/Nostalgex/Services/PlaybackStarvation.swift     a stream that WAS playing and is starved by its source
//   Nostalgex/Nostalgex/Services/ChannelFailureRun.swift      five failures in a row stop the channel
//   Nostalgex/Nostalgex/App/AppState+Playback.swift           direct play, then the server stream, then one retry capped at 1080p
// Vectors: Nostalgex/NostalgexTests/PlaybackStarvationTests.swift, replayed in scripts/nostalgex-playback-recovery-smoke.mjs.
(function (global) {
  'use strict';

  const STALL_SECONDS = 3;            // the playhead standing still this long is a stall (HLS pauses a moment between segments)
  const HARD_STALL_SECONDS = 20;      // one stall this long is a frozen picture, whatever came before
  const STALLS_TO_STARVE = 3;         // this many stalls inside WINDOW_SECONDS means the source cannot keep up
  const WINDOW_SECONDS = 120;
  const ARM_AFTER_PROGRESS_SECONDS = 1;   // only once playback has genuinely run (startup is the other watchdog's job)
  const MINIMUM_PROGRESS_SECONDS = 0.25;
  const TAIL_SECONDS = 5;             // the tail of an item belongs to the end-of-item fallback
  const FAILURE_RUN_LIMIT = 5;        // programmes in a row on one channel with no picture in between

  /** One monitor per program. `observe` is fed once a second; it returns { stalls, longestStallSeconds } when the stream is starving, else null. */
  function createStarvationMonitor() {
    let armed = false, firstPlayhead = null, lastPlayhead = null, stallStartedAt = null, longestStall = 0;
    let stallsEndedAt = [];
    return {
      get armed() { return armed; },
      observe(playhead, wall, paused, remaining) {
        if (!Number.isFinite(playhead)) return null;
        // A deliberate pause is not a stall, and a stall that began before it does not carry across it (the Swift ignores paused samples;
        // this also forgets the one in progress, so a long pause cannot read as a 20 s freeze on resume).
        if (paused) { stallStartedAt = null; lastPlayhead = null; return null; }
        if (remaining != null && Number.isFinite(remaining) && remaining <= TAIL_SECONDS) return null;
        if (firstPlayhead === null) firstPlayhead = playhead;
        const last = lastPlayhead;
        lastPlayhead = playhead;
        if (!armed) {
          if (playhead - firstPlayhead >= ARM_AFTER_PROGRESS_SECONDS) armed = true;
          return null;
        }
        if (last === null) return null;
        const moved = playhead - last >= MINIMUM_PROGRESS_SECONDS;
        if (moved) {
          if (stallStartedAt !== null && wall - stallStartedAt >= STALL_SECONDS) {
            stallsEndedAt.push(wall);
            longestStall = Math.max(longestStall, wall - stallStartedAt);
          }
          stallStartedAt = null;
        } else {
          if (stallStartedAt === null) stallStartedAt = wall;
          const length = wall - stallStartedAt;
          longestStall = Math.max(longestStall, length);
          if (length >= HARD_STALL_SECONDS) return { stalls: stallsEndedAt.length + 1, longestStallSeconds: longestStall };
        }
        stallsEndedAt = stallsEndedAt.filter((t) => wall - t <= WINDOW_SECONDS);
        if (stallsEndedAt.length >= STALLS_TO_STARVE) return { stalls: stallsEndedAt.length, longestStallSeconds: longestStall };
        return null;
      },
    };
  }

  /** Programmes that failed in a row on one channel. Only a picture counts as playing. */
  function createFailureRun(limit) {
    const max = limit || FAILURE_RUN_LIMIT;
    let channelId = null, count = 0;
    return {
      get count() { return count; },
      get isStopped() { return count >= max; },
      /** One more programme on `id` failed. True when the channel should stop. */
      recordFailure(id) { if (channelId !== id) { channelId = id; count = 0; } count += 1; return count >= max; },
      reset() { channelId = null; count = 0; },
    };
  }

  /**
   * What the page tries after a delivery fails: direct play goes to the server stream; a server stream goes to one retry with the
   * video capped at 1080p, unless the viewer's STREAM QUALITY already caps it (at 1080p or lower) or that retry was already made;
   * then the program fails (the card, then the next program).
   */
  function nextRung(delivery, qualityIsCapped, cappedRetryMade) {
    if (delivery === 'direct') return 'server';
    if (delivery === 'server' && !qualityIsCapped && !cappedRetryMade) return 'capped1080';
    return 'fail';
  }

  const api = { STALL_SECONDS, HARD_STALL_SECONDS, STALLS_TO_STARVE, WINDOW_SECONDS, FAILURE_RUN_LIMIT, createStarvationMonitor, createFailureRun, nextRung };
  global.NostalgexPlaybackRecovery = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
