// The guide's programme cursor for the web tuner: Left and Right move a programme at a time, not the window by 30 minutes.
// PARITY with tvOS:
//   Nostalgex/Nostalgex/Models/GuideTimeCursor.swift   enum GuideProgramCursor (and GuideTimeCursor.entry(in:at:), entry(after:in:))
//   Nostalgex/NostalgexTests/GuideProgramCursorTests.swift   the vectors, replayed in scripts/nostalgex-guide-cursor-smoke.mjs
// (Chad 2026-11-15: "it should jump to the next title not the next 30 minutes and we should have a highlight or some way of seeing
// where the cursor is at".)
//
// Focus stays on the row; the cursor is a time on it, and the programme the cursor is on is the one covering that time.
//   Right: the next programme on the row, whatever its length, over a gap too.
//   Left: the previous programme, as long as it has not ended; from the programme on now there is none, and the guide goes to
//     the bundle stripe as before.
//   Up and Down: the row changes and the time stays, so the cursor is on the programme of the new row at that time.
//   The window moves in time only when the programme the cursor moves to would leave the view: it starts before it or past it, or
//   in its last 15 minutes. Then it moves to the 30 minute slot the programme starts in.
//   null is the live programme: where the guide comes back to on the playing channel.
//
// An entry is { startSec, endSec, ... } (the guide's blocks); times are Unix seconds.
(function (global) {
  'use strict';

  const SLOT_SECONDS = 1800;
  const VISIBLE_SECONDS = 7200;

  /** The time the cursor stands at: its own, or now when it is on the live programme or has fallen behind now. */
  function time(cursor, nowSec) { return Math.max(cursor == null ? nowSec : cursor, nowSec); }

  /** The programme covering `t`, or null in a gap. */
  function entryAt(entries, t) {
    return entries.find((e) => e.startSec <= t && t < e.endSec) || null;
  }

  /** The programme that follows `entry` on the schedule: the first to start at or after its end. */
  function entryAfter(entries, entry) {
    let best = null;
    for (const e of entries) if (e.startSec >= entry.endSec && (best === null || e.startSec < best.startSec)) best = e;
    return best;
  }

  /** The programme the cursor is on: the one covering its time. null in a gap. */
  function current(entries, cursor, nowSec) { return entryAt(entries, time(cursor, nowSec)); }

  /** Right: the programme after the cursor's, or the first to start after its time when it is in a gap. */
  function next(entries, cursor, nowSec) {
    const cur = current(entries, cursor, nowSec);
    if (cur) return entryAfter(entries, cur);
    const t = time(cursor, nowSec);
    let best = null;
    for (const e of entries) if (e.startSec > t && (best === null || e.startSec < best.startSec)) best = e;
    return best;
  }

  /** Left: the programme before the cursor's that has not ended yet. null from the programme on now. */
  function previous(entries, cursor, nowSec) {
    const cur = current(entries, cursor, nowSec);
    const anchor = cur ? cur.startSec : time(cursor, nowSec);
    let best = null;
    for (const e of entries) if (e.endSec <= anchor && e.endSec > nowSec && (best === null || e.startSec > best.startSec)) best = e;
    return best;
  }

  /** The cursor for a programme: its start, or null (live) when it is on now. */
  function cursorFor(entry, nowSec) { return entry.startSec <= nowSec ? null : entry.startSec; }

  /**
   * The window's offset, in `slot` steps from `windowStartSec`, that shows `entry`: the offset it has while the programme starts
   * inside the view with at least half a slot of it showing; otherwise the slot its start is in (for the live programme, the slot
   * now is in).
   */
  function windowOffset(entry, offset, windowStartSec, nowSec, maxOffset, visible = VISIBLE_SECONDS, slot = SLOT_SECONDS) {
    const start = Math.max(entry.startSec, nowSec);
    const viewStart = windowStartSec + offset * slot;
    const viewEnd = viewStart + visible;
    if (start >= viewStart && start < viewEnd - slot / 2) return offset;
    const wanted = Math.floor((start - windowStartSec) / slot);
    return Math.min(Math.max(0, wanted), maxOffset);
  }

  const api = { SLOT_SECONDS, VISIBLE_SECONDS, time, entryAt, entryAfter, current, next, previous, cursorFor, windowOffset };
  global.NostalgexGuideCursor = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
