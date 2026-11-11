// When an open page reads the library again, and when it can skip the read.
// PARITY with tvOS (and the Roku port, #67):
//   Nostalgex/Nostalgex/App/AppState+Schedule.swift          startDailyRefresh: a check every 15 minutes, a refresh once 6 hours have passed
//   Nostalgex/Nostalgex/Services/LibrarySnapshotStore.swift  refreshAfterSeconds (6 hours)
//   Nostalgex/Nostalgex/Services/LibraryChangeSignature.swift the Plex section fingerprint and the 24 hour cap
(function (global) {
  'use strict';
  const REFRESH_AFTER_SECONDS = 6 * 3600;
  const CHECK_EVERY_SECONDS = 15 * 60;
  const HARD_CAP_SECONDS = 24 * 3600;

  /** A Plex server's fingerprint from its sections' `updatedAt` and `contentChangedAt` (they move only when something changed;
   *  `scannedAt` is left out, Plex bumps it on every scheduled scan). Null when a section carries neither, so "unchanged" is
   *  never claimed about a library that cannot be observed (Jellyfin and Emby). */
  function signature(serverId, sections) {
    const parts = [];
    for (const s of sections || []) {
      if (s.updatedAt == null && s.contentChangedAt == null) return null;
      parts.push(`${s.key}=u${s.updatedAt || 0}/c${s.contentChangedAt || 0}`);
    }
    if (!parts.length) return null;
    return `${serverId}:` + parts.sort().join(',');
  }
  /** Every server's fingerprint as one. Null if any server has none. */
  function combine(perServer) {
    if (!perServer.length || perServer.some((x) => !x)) return null;
    return [...perServer].sort().join(';');
  }
  /** Skip the read only when the library is provably unchanged and the hard cap has not passed. */
  function shouldSkipRefresh(ageSeconds, stored, current, hardCapSeconds) {
    if (!(ageSeconds < (hardCapSeconds == null ? HARD_CAP_SECONDS : hardCapSeconds))) return false;
    return !!stored && !!current && stored === current;
  }
  /** The loop's test, run every 15 minutes (and when a hidden tab returns): 6 hours since the last load and 6 hours since the last check. */
  function isDue(nowSeconds, lastLoadSeconds, lastCheckSeconds) {
    return nowSeconds - lastLoadSeconds >= REFRESH_AFTER_SECONDS && nowSeconds - lastCheckSeconds >= REFRESH_AFTER_SECONDS;
  }

  const api = { REFRESH_AFTER_SECONDS, CHECK_EVERY_SECONDS, HARD_CAP_SECONDS, signature, combine, shouldSkipRefresh, isDue };
  global.NostalgexLibraryRefresh = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
