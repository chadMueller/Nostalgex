package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cases of the Apple TV's LibraryLoadStallDetectorTests.swift: a library load is judged by
 * whether it is still moving, never by how long it has been running.
 */
class LibraryLoadStallDetectorTest {
    private val start = 1_000_000.0
    private val p = LibraryLoadStallDetector.Verdict.Progressing
    private fun slow(s: Double) = LibraryLoadStallDetector.Verdict.Slow(s)
    private fun stalled(s: Double) = LibraryLoadStallDetector.Verdict.Stalled(s)
    private fun sample(section: Int = 0, items: Int = 0, detail: String = "") = LibraryLoadProgressSample(1, section, 4, items, detail)

    @Test fun aSlowScanNeverStallsWhileItemsKeepArriving() {
        val d = LibraryLoadStallDetector(sample(), start)
        for (step in 1..25) assertEquals("step $step", p, d.evaluate(sample(items = step * 150), start + step * 90))
    }

    @Test fun showLevelDetailCountsAsProgressWhenCountersHaveNotMoved() {
        val d = LibraryLoadStallDetector(sample(detail = "Section 1/4 · 10/130 shows"), start)
        var now = start
        for (shows in 20..130 step 10) {
            now += 120
            assertEquals(p, d.evaluate(sample(detail = "Section 1/4 · $shows/130 shows"), now))
        }
    }

    @Test fun movingToTheNextSectionIsProgress() {
        val d = LibraryLoadStallDetector(sample(section = 0, items = 900), start)
        assertEquals(p, d.evaluate(sample(section = 1, items = 900), start + 200))
    }

    @Test fun quietPastWarnThresholdIsSlowNotStalled() {
        assertEquals(slow(61.0), LibraryLoadStallDetector(sample(items = 500), start).evaluate(sample(items = 500), start + 61))
    }

    @Test fun staysProgressingJustBeforeWarnThreshold() {
        assertEquals(p, LibraryLoadStallDetector(sample(items = 500), start).evaluate(sample(items = 500), start + 59))
    }

    @Test fun theFullRetryLadderIsNotLongEnoughToStall() {
        assertEquals(slow(182.0), LibraryLoadStallDetector(sample(items = 500), start).evaluate(sample(items = 500), start + 182))
    }

    @Test fun silencePastStallThresholdStalls() {
        assertEquals(stalled(210.0), LibraryLoadStallDetector(sample(items = 500), start).evaluate(sample(items = 500), start + 210))
    }

    @Test fun theStallClockResetsOnEveryScrapOfProgress() {
        val d = LibraryLoadStallDetector(sample(items = 500), start)
        assertEquals(slow(200.0), d.evaluate(sample(items = 500), start + 200))
        assertEquals(p, d.evaluate(sample(items = 650), start + 201))
        assertEquals(slow(200.0), d.evaluate(sample(items = 650), start + 401))
    }

    @Test fun recoveryAfterAStallVerdictIsReportedAsProgress() {
        val d = LibraryLoadStallDetector(sample(items = 500), start)
        d.evaluate(sample(items = 500), start + 300)
        assertEquals(p, d.evaluate(sample(items = 501), start + 302))
    }

    @Test fun customThresholdsAreHonoured() {
        val d = LibraryLoadStallDetector(sample(), start, warnAfter = 5.0, stallAfter = 10.0)
        assertEquals(p, d.evaluate(sample(), start + 4))
        assertEquals(slow(6.0), d.evaluate(sample(), start + 6))
        assertEquals(stalled(11.0), d.evaluate(sample(), start + 11))
    }

    @Test fun aClockMovingBackwardsNeverStalls() {
        assertEquals(p, LibraryLoadStallDetector(sample(), start).evaluate(sample(), start - 600))
    }

    @Test fun theDefaultThresholdsAreOrdered() {
        assertTrue(LibraryLoadStallDetector.DEFAULT_WARN_AFTER < LibraryLoadStallDetector.DEFAULT_STALL_AFTER)
        assertTrue(LibraryLoadStallDetector.DEFAULT_STALL_AFTER > 182)
    }
}
