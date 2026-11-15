package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Apple TV's GuideProgramCursor rules (appletv/integration-1115). */
class GuideCursorTest {
    private val now = 1_000_000.0
    private val base = 1_000_000L - 600      // the window begins a little before now
    private val half = 1800L
    private fun e(id: String, start: Long, end: Long) = ScheduleEntry(id, MediaItem(id, title = id), start, end, start <= now && now < end, false)

    // a (live) | b | c (long) | gap | d
    private val a = e("a", base - 600, base + half)
    private val b = e("b", base + half, base + 2 * half)
    private val c = e("c", base + 2 * half, base + 6 * half)
    private val d = e("d", base + 8 * half, base + 9 * half)
    private val entries = listOf(a, b, c, d)

    @Test fun noCursorIsTheLiveProgramme() = assertEquals("a", GuideCursor.current(entries, null, now)?.id)

    @Test fun aCursorBehindNowStandsAtNow() {
        assertEquals(now, GuideCursor.time(base - 5000, now), 0.0)
        assertEquals("a", GuideCursor.current(entries, base - 5000, now)?.id)
    }

    @Test fun rightGoesToTheNextProgrammeWhateverItsLength() {
        assertEquals("b", GuideCursor.next(entries, null, now)?.id)
        assertEquals("c", GuideCursor.next(entries, b.startSec, now)?.id)
        assertEquals("d", GuideCursor.next(entries, c.startSec, now)?.id)     // over the gap, not a half hour on
        assertNull(GuideCursor.next(entries, d.startSec, now))
    }

    @Test fun rightFromAGapIsTheFirstToStartAfterIt() = assertEquals("d", GuideCursor.next(entries, base + 7 * half, now)?.id)

    @Test fun leftGoesToThePreviousProgrammeThatHasNotEnded() {
        assertEquals("c", GuideCursor.previous(entries, d.startSec, now)?.id)
        assertEquals("b", GuideCursor.previous(entries, c.startSec, now)?.id)
    }

    @Test fun leftFromTheLiveProgrammeIsNothingSoTheGuideGoesToTheStripe() {
        assertNull(GuideCursor.previous(entries, null, now))
        assertEquals("a", GuideCursor.previous(entries, b.startSec, now)?.id)
    }

    @Test fun theLiveProgrammeIsTheCursorsNull() {
        assertNull(GuideCursor.cursorFor(a, now))
        assertEquals(b.startSec, GuideCursor.cursorFor(b, now))
    }

    @Test fun upAndDownKeepTheTime() {
        val other = listOf(e("f", base - 600, base + 3 * half), e("g", base + 3 * half, base + 4 * half))
        assertEquals("f", GuideCursor.current(other, c.startSec - 3 * half, now)?.id)
        assertEquals("g", GuideCursor.current(other, base + 3 * half + 10, now)?.id)
    }

    @Test fun theWindowStaysWhileTheProgrammeStartsInViewWithHalfASlotShowing() {
        assertEquals(0, GuideCursor.windowOffset(b, 0, base, now, 44))
    }

    @Test fun theWindowMovesWhenTheProgrammeStartsInTheLast15Minutes() {
        // The view is 7200 s from the window start; b' starts 7200 - 600 s in: inside the last 15 minutes.
        val late = e("late", base + 7200 - 600, base + 7200 + half)
        assertEquals(3, GuideCursor.windowOffset(late, 0, base, now, 44))
    }

    @Test fun theWindowMovesToTheHalfHourAProgrammeStartsInWhenItIsPastTheView() = assertEquals(8, GuideCursor.windowOffset(d, 0, base, now, 44))

    @Test fun theWindowMovesBackWhenTheProgrammeStartsBeforeTheView() = assertEquals(2, GuideCursor.windowOffset(c, 5, base, now, 44))

    @Test fun theLiveProgrammeBringsTheWindowToTheSlotNowIsIn() {
        // Viewed from offset 4, the live programme (start before now) is at now: slot 0 here.
        assertEquals(0, GuideCursor.windowOffset(a, 4, base, now, 44))
    }

    @Test fun theWindowIsHeldToItsBounds() {
        assertEquals(10, GuideCursor.windowOffset(e("z", base + 30 * half, base + 31 * half), 0, base, now, 10))
    }

    @Test fun thePanelPreviewsOnlyALaterProgrammeAndOnlyWithACursor() {
        assertNull(GuideCursor.preview(entries, null, now))
        assertEquals("b", GuideCursor.preview(entries, b.startSec, now)?.id)
        assertNull(GuideCursor.preview(entries, base - 5000, now))
    }
}
