// One guide row's programme blocks, laid out inside the 2-hour window: the web tuner's copy of the Apple TV's
// ProgramRowLayout.
//
// PARITY with tvOS
//   Nostalgex/Nostalgex/Models/ProgramRowLayout.swift       ProgramRowLayout.segments (the cursor walk)
//
// Why a cursor. The row used to tile its blocks end to end, each as wide as the part of it inside the window.
// That is only right when the schedule is contiguous. An airing that runs past local midnight overlaps the first
// airing of the next day (the 24-hour guide window holds both), so the overlap was counted twice: the row grew
// wider than the window and every later programme was drawn late (a 104 minute movie from 23:24 to 01:08 pushed
// the programmes after it 68 minutes right). The row clips its overflow, so nothing showed it but the times.
//
// Walking a cursor from the window start makes the widths sum to exactly the span they cover:
//   - an airing that overlaps the one before it is trimmed at its start (the earlier airing keeps its time);
//   - a hole between airings becomes a spacer at its true position, so later programmes are not pulled left;
//   - nothing can total more than the window.
//
// Pure: seconds in, fractions out. Same arithmetic as the Swift; scripts/program-row-layout-smoke.mjs runs the
// cases of NostalgexTests/ProgramRowLayoutTests.swift against it.
//
// USAGE: window.NostalgexProgramRowLayout (browser), or import this file in node and read globalThis.

(function (global) {
  'use strict';

  /**
   * `intervals` is [{ startSec, endSec }], parallel to the caller's blocks; the segments refer back by index.
   * Blocks are walked in start order whatever the order given. Returns, left to right,
   *   { kind: 'gap',   fraction, startSec, endSec }
   *   { kind: 'block', index, fraction, startSec, endSec }   (startSec/endSec: the part that is drawn)
   * where `fraction` is that span's share of the window. An empty list when the window has no length.
   */
  function segments(intervals, windowStartSec, windowDurationSec) {
    if (!(windowDurationSec > 0)) return [];
    const windowEndSec = windowStartSec + windowDurationSec;
    const ordered = intervals
      .map((interval, index) => ({ interval, index }))
      .sort((a, b) => a.interval.startSec - b.interval.startSec);

    const out = [];
    let cursor = windowStartSec;
    for (const { interval, index } of ordered) {
      if (cursor >= windowEndSec) break;
      // Clip against the cursor, not just the window start: that is how the overlap of the earlier airing is
      // trimmed from this one instead of counted twice.
      const visStart = Math.max(interval.startSec, cursor);
      const visEnd = Math.min(interval.endSec, windowEndSec);
      if (!(visEnd > visStart)) continue;
      if (visStart > cursor) {
        out.push({ kind: 'gap', fraction: (visStart - cursor) / windowDurationSec, startSec: cursor, endSec: visStart });
      }
      out.push({ kind: 'block', index, fraction: (visEnd - visStart) / windowDurationSec, startSec: visStart, endSec: visEnd });
      cursor = visEnd;
    }
    return out;
  }

  global.NostalgexProgramRowLayout = { segments };
})(typeof globalThis !== 'undefined' ? globalThis : window);
