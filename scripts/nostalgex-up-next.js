// The words the Now Playing panel uses for the time until the next programme.
// PARITY: Nostalgex/Nostalgex/Services/NowPlayingPanelLogic.swift, enum UpNextLabel.
//   "UP NEXT IN 12 MIN", "UP NEXT IN 84 MIN", "UP NEXT IN 120 MIN", "UP NEXT IN LESS THAN 1 MIN" (minutes only, Chad 2026-11-10).
// Whole minutes, rounded down, so it never promises sooner than it is. The vectors are in the smoke.
(function (global) {
  'use strict';
  /** `seconds` until the next programme starts. Minutes only, never hours (84 MIN, 120 MIN), whole minutes rounded down, so it never promises sooner than it is. */
  function label(seconds) {
    if (!(seconds >= 60)) return 'UP NEXT IN LESS THAN 1 MIN';
    return `UP NEXT IN ${Math.floor(seconds / 60)} MIN`;
  }
  const api = { label };
  global.NostalgexUpNext = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
