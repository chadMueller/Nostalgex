package com.muellhaus.nostalgex.engine

import kotlin.math.max
import kotlin.math.min

/**
 * The guide's programme cursor: Left and Right go to the previous or next programme on the focused row, whatever its
 * length, and the programme the cursor is on has a cell of its own. A port of the Apple TV's `GuideProgramCursor`
 * (appletv/integration-1115, Chad 2026-11-15), with the same rules:
 *
 * - The cursor is a time on the row ([cursorSec], seconds); null is the live programme. A cursor that has fallen
 *   behind now stands at now.
 * - Right: the programme after the cursor's, or the first to start after the cursor's time when it is in a gap.
 * - Left: the programme before the cursor's that has not ended yet. From the programme on now there is none (null), and
 *   the guide goes to the bundle stripe.
 * - Up and Down change the row and keep the time, so the cursor is on the new row's programme at that time.
 * - The window moves in time only when the programme the cursor moves to starts before the view, past it, or in its last
 *   15 minutes, to the half hour its start is in ([windowOffset]).
 * - Back to the live programme (Back, a return from full screen, select): the cursor to null and the window to its start.
 */
object GuideCursor {
    /** The time the cursor stands at: its own, or now when it is on the live programme or has fallen behind now. */
    fun time(cursorSec: Long?, nowSec: Double): Double = max(cursorSec?.toDouble() ?: nowSec, nowSec)

    /** The programme the cursor is on: the one covering its time. Null in a gap. */
    fun current(entries: List<ScheduleEntry>, cursorSec: Long?, nowSec: Double): ScheduleEntry? {
        val t = time(cursorSec, nowSec)
        return entries.firstOrNull { it.startSec <= t && t < it.endSec }
    }

    /** The programme after [entry]: the earliest one starting at or after its end. */
    fun after(entries: List<ScheduleEntry>, entry: ScheduleEntry): ScheduleEntry? =
        entries.filter { it.startSec >= entry.endSec }.minByOrNull { it.startSec }

    /** Right. */
    fun next(entries: List<ScheduleEntry>, cursorSec: Long?, nowSec: Double): ScheduleEntry? {
        current(entries, cursorSec, nowSec)?.let { return after(entries, it) }
        val t = time(cursorSec, nowSec)
        return entries.filter { it.startSec > t }.minByOrNull { it.startSec }
    }

    /** Left: the programme before the cursor's that has not ended yet. Null from the programme on now. */
    fun previous(entries: List<ScheduleEntry>, cursorSec: Long?, nowSec: Double): ScheduleEntry? {
        val anchor = current(entries, cursorSec, nowSec)?.startSec?.toDouble() ?: time(cursorSec, nowSec)
        return entries.filter { it.endSec <= anchor && it.endSec > nowSec }.maxByOrNull { it.startSec }
    }

    /** The cursor for a programme: its start, or null (live) when it is on now. */
    fun cursorFor(entry: ScheduleEntry, nowSec: Double): Long? = if (entry.startSec <= nowSec) null else entry.startSec

    /**
     * The window's offset, in half hours from [windowStartSec], that shows [entry]: the offset it has while the
     * programme starts inside the view with at least half a slot of it showing; otherwise the slot its start is in
     * (for the live programme, the slot now is in), within [0, maxOffset].
     */
    fun windowOffset(
        entry: ScheduleEntry, offset: Int, windowStartSec: Long, nowSec: Double, maxOffset: Int,
        visibleSeconds: Long = 7200, slotSeconds: Long = 1800,
    ): Int {
        val start = max(entry.startSec.toDouble(), nowSec)
        val viewStart = windowStartSec + offset * slotSeconds
        val viewEnd = viewStart + visibleSeconds
        if (start >= viewStart && start < viewEnd - slotSeconds / 2.0) return offset
        val wanted = Math.floor((start - windowStartSec) / slotSeconds).toInt()
        return min(max(0, wanted), maxOffset)
    }

    /** What the info panel shows while the cursor is on a later programme: that programme, with its time range. Null shows what is on now. */
    fun preview(entries: List<ScheduleEntry>, cursorSec: Long?, nowSec: Double): ScheduleEntry? {
        if (cursorSec == null) return null
        return current(entries, cursorSec, nowSec)?.takeIf { it.startSec > nowSec }
    }
}
