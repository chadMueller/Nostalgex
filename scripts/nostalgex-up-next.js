// The words the Now Playing panel uses for the time until the next programme.
// PARITY: Nostalgex/Nostalgex/Services/NowPlayingPanelLogic.swift, enum UpNextLabel.
//   "UP NEXT IN 12 MIN", "UP NEXT IN 1 HR 5 MIN", "UP NEXT IN 2 HR", "UP NEXT IN LESS THAN 1 MIN".
// Whole minutes, rounded down, so it never promises sooner than it is. The vectors are in the smoke.
(function (global) {
  'use strict';
  function span(minutes) {
    if (minutes < 60) return `${minutes} MIN`;
    const hours = Math.floor(minutes / 60);
    const rest = minutes % 60;
    return rest === 0 ? `${hours} HR` : `${hours} HR ${rest} MIN`;
  }
  /** `seconds` until the next programme starts. */
  function label(seconds) {
    if (!(seconds >= 60)) return 'UP NEXT IN LESS THAN 1 MIN';
    return `UP NEXT IN ${span(Math.floor(seconds / 60))}`;
  }
  const api = { label };
  global.NostalgexUpNext = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
