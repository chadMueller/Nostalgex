package com.muellhaus.nostalgex.engine

import kotlin.math.max
import kotlin.math.min

/**
 * The guide's programme cursor (Chad, 2026-11-15, after release 7: Left and Right "should jump to the next title not
 * the next 30 minutes", with a highlight "of where the cursor is"). The Apple TV's guide still moves its window 30
 * minutes at a time (`GuideTimeCursor`), with focus on the whole row; this is Android's own step beyond it, and the
 * info panel's preview of the focused programme is the Apple TV's (I-089).
 *
 * The cursor is one instant, [cursorSec], that lies inside the focused programme of whichever row has focus: Left and
 * Right set it to the previous or next programme's start, and Up and Down keep it, so the new row's focused programme
 * is whatever covers that instant, which keeps the cursor in the same column of the grid. Null is the live programme.
 * Everything here is pure.
 */
object GuideCursor {
    /** The programme the cursor is on in a row: the live one when there is no cursor, else the one covering it (or the next one starting after it). */
    fun focusedEntry(entries: List<ScheduleEntry>, cursorSec: Long?, nowSec: Double): ScheduleEntry? {
        if (entries.isEmpty()) return null
        if (cursorSec == null) return entries.firstOrNull { it.isNowPlaying } ?: entries.firstOrNull { it.endSec > nowSec } ?: entries.last()
        return entries.firstOrNull { it.startSec <= cursorSec && cursorSec < it.endSec }
            ?: entries.firstOrNull { it.startSec >= cursorSec }
            ?: entries.last()
    }

    /** The programme that follows [entry]: the earliest one starting at or after its end. */
    fun next(entries: List<ScheduleEntry>, entry: ScheduleEntry): ScheduleEntry? =
        entries.filter { it.startSec >= entry.endSec }.minByOrNull { it.startSec }

    /** The programme before [entry]: the latest one that ended at or before its start. */
    fun previous(entries: List<ScheduleEntry>, entry: ScheduleEntry): ScheduleEntry? =
        entries.filter { it.endSec <= entry.startSec }.maxByOrNull { it.startSec }

    /** The instant that stands for [entry]: its start, but never before the guide's first moment (a live programme began earlier). */
    fun referenceTime(entry: ScheduleEntry, baseSec: Long): Long = max(entry.startSec, baseSec)

    /**
     * The window's offset, in half hours from the base, that keeps [entry] in view: unchanged while its start is inside the
     * window with at least half an hour of room, otherwise moved so the programme's own half hour is at the left edge.
     */
    fun slotOffsetFor(entry: ScheduleEntry, currentOffset: Int, baseSec: Long, visibleSeconds: Long, maxOffset: Int, slotSeconds: Long = 1800): Int {
        val start = baseSec + currentOffset * slotSeconds
        val ref = referenceTime(entry, baseSec)
        val own = Math.floorDiv(ref - baseSec, slotSeconds).toInt()
        return when {
            ref < start -> max(0, own)
            ref >= start + visibleSeconds - slotSeconds -> min(maxOffset, own)
            else -> currentOffset
        }
    }

    /** What the info panel shows while the cursor is on a programme that is not the live one: its time range, and the programme after it. */
    fun isPreview(entry: ScheduleEntry?, nowSec: Double): Boolean = entry != null && !(entry.startSec <= nowSec && nowSec < entry.endSec)
}
