package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GuideCursorTest {
    private val base = 1_000_000L
    private val half = 1800L
    private fun e(id: String, start: Long, end: Long, now: Boolean = false) =
        ScheduleEntry(id, MediaItem(id, title = id), start, end, now, false)

    // a (live, began before the window) | b | c (long) | gap | d
    private val entries = listOf(
        e("a", base - 600, base + half, now = true),
        e("b", base + half, base + 2 * half),
        e("c", base + 2 * half, base + 6 * half),
        e("d", base + 8 * half, base + 9 * half),
    )

    @Test fun noCursorIsTheLiveProgramme() = assertEquals("a", GuideCursor.focusedEntry(entries, null, base.toDouble())?.id)

    @Test fun aCursorIsWhateverCoversIt() {
        assertEquals("b", GuideCursor.focusedEntry(entries, base + half + 5, base.toDouble())?.id)
        assertEquals("c", GuideCursor.focusedEntry(entries, base + 5 * half, base.toDouble())?.id)
    }

    @Test fun aCursorInAGapIsTheNextProgramme() = assertEquals("d", GuideCursor.focusedEntry(entries, base + 7 * half, base.toDouble())?.id)

    @Test fun pastTheEndIsTheLastProgramme() = assertEquals("d", GuideCursor.focusedEntry(entries, base + 20 * half, base.toDouble())?.id)

    @Test fun nothingScheduledIsNothingFocused() = assertNull(GuideCursor.focusedEntry(emptyList(), null, 0.0))

    @Test fun rightGoesToTheNextProgrammeWhateverItsLength() {
        assertEquals("b", GuideCursor.next(entries, entries[0])?.id)
        assertEquals("c", GuideCursor.next(entries, entries[1])?.id)
        assertEquals("d", GuideCursor.next(entries, entries[2])?.id)     // over the gap, not a half hour on
        assertNull(GuideCursor.next(entries, entries[3]))
    }

    @Test fun leftGoesToThePreviousProgramme() {
        assertEquals("c", GuideCursor.previous(entries, entries[3])?.id)
        assertEquals("a", GuideCursor.previous(entries, entries[1])?.id)
        assertNull(GuideCursor.previous(entries, entries[0]))
    }

    @Test fun theReferenceTimeIsNeverBeforeTheGuideBegins() {
        assertEquals(base, GuideCursor.referenceTime(entries[0], base))
        assertEquals(base + half, GuideCursor.referenceTime(entries[1], base))
    }

    @Test fun upAndDownKeepTheColumn() {
        // The cursor on "c" (long); another row has f | g | h: the cursor lands on whatever covers its time.
        val other = listOf(e("f", base, base + 3 * half), e("g", base + 3 * half, base + 4 * half), e("h", base + 4 * half, base + 7 * half))
        val cursor = GuideCursor.referenceTime(entries[2], base)
        assertEquals("f", GuideCursor.focusedEntry(other, cursor, base.toDouble())?.id)
    }

    @Test fun theWindowStaysWhileTheProgrammeIsInView() =
        assertEquals(0, GuideCursor.slotOffsetFor(entries[1], 0, base, 7200, 44))

    @Test fun theWindowMovesToABeginningThatIsOffTheRight() {
        // d starts 8 half hours in; the window shows 4: its own half hour goes to the left edge.
        assertEquals(8, GuideCursor.slotOffsetFor(entries[3], 0, base, 7200, 44))
    }

    @Test fun theWindowMovesBackToAProgrammeOffTheLeft() = assertEquals(2, GuideCursor.slotOffsetFor(entries[2], 5, base, 7200, 44))

    @Test fun theWindowIsHeldToItsBounds() {
        assertEquals(0, GuideCursor.slotOffsetFor(entries[0], 3, base, 7200, 44))
        assertEquals(10, GuideCursor.slotOffsetFor(e("z", base + 30 * half, base + 31 * half), 0, base, 7200, 10))
    }

    @Test fun aProgrammeThatIsNotLiveIsAPreview() {
        assertFalse(GuideCursor.isPreview(entries[0], base.toDouble()))
        assertTrue(GuideCursor.isPreview(entries[1], base.toDouble()))
        assertFalse(GuideCursor.isPreview(null, 0.0))
    }
}
