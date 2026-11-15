package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Apple TV's GuideTextSizeTests: three steps, raw values that old copies and the other platforms keep reading, and the sizes. */
class GuideTextSizeTest {
    private fun all(m: GuideTextMetrics) = listOf(m.title, m.timeLabel, m.channelHeading, m.number, m.name, m.placeholder, m.packageRowText, m.packageHeading, m.panelText)

    @Test fun nothingSavedOrAnythingUnknownIsDefault() {
        assertEquals(GuideTextSize.NORMAL, GuideTextSize.fromStored(null))
        assertEquals(GuideTextSize.NORMAL, GuideTextSize.fromStored(""))
        assertEquals(GuideTextSize.NORMAL, GuideTextSize.fromStored("huge"))
        assertEquals(GuideTextSize.NORMAL, GuideTextSize.fromStored("LARGE"))
    }

    @Test fun rawValuesAndLabels() {
        assertEquals(listOf("small", "normal", "large"), GuideTextSize.entries.map { it.raw })
        assertEquals(listOf("SMALLER", "DEFAULT", "LARGER"), GuideTextSize.entries.map { it.label })
        for (s in GuideTextSize.entries) assertEquals(s, GuideTextSize.fromStored(s.raw))
        assertEquals("nostalgex_guide_text_size", GuideTextSize.STORAGE_KEY)
    }

    @Test fun theRowCyclesSmallerDefaultLargerAndRoundAgain() {
        assertEquals(GuideTextSize.NORMAL, GuideTextSize.SMALL.next)
        assertEquals(GuideTextSize.LARGE, GuideTextSize.NORMAL.next)
        assertEquals(GuideTextSize.SMALL, GuideTextSize.LARGE.next)
    }

    @Test fun defaultSizes() {
        val m = GuideTextSize.NORMAL.metrics
        assertEquals(listOf(20, 22, 22, 20, 36, 20, 22), listOf(m.title, m.timeLabel, m.channelHeading, m.number, m.numberWidth, m.name, m.placeholder))
        assertEquals(listOf(20, 22, 20, 29, 28), listOf(m.packageRowText, m.packageHeading, m.panelText, m.panelTitle, m.panelTag))
    }

    @Test fun smallerIsTheNamedSizes() {
        val m = GuideTextSize.SMALL.metrics
        assertEquals(listOf(17, 19, 19, 17, 31, 17, 19), listOf(m.title, m.timeLabel, m.channelHeading, m.number, m.numberWidth, m.name, m.placeholder))
        assertEquals(listOf(17, 19, 17, 25, 24), listOf(m.packageRowText, m.packageHeading, m.panelText, m.panelTitle, m.panelTag))
        assertEquals(17, GuideTextMetrics.SMALL_ROW_TEXT); assertEquals(19, GuideTextMetrics.SMALL_TIMES)
    }

    @Test fun largerIsTodaysLarge() {
        val m = GuideTextSize.LARGE.metrics
        assertEquals(listOf(29, 29, 29, 29, 54, 29, 29), listOf(m.title, m.timeLabel, m.channelHeading, m.number, m.numberWidth, m.name, m.placeholder))
        assertEquals(listOf(22, 25, 22, 29, 28), listOf(m.packageRowText, m.packageHeading, m.panelText, m.panelTitle, m.panelTag))
    }

    @Test fun noGuideTextIsBelow17() {
        for (s in GuideTextSize.entries) assertTrue(s.name, all(s.metrics).all { it >= 17 })
    }

    @Test fun eachStepIsAtLeastAsBigAsTheOneBelow() {
        val steps = GuideTextSize.entries.map { it.metrics }
        for ((a, b) in steps.zipWithNext()) {
            for ((x, y) in all(a).zip(all(b))) assertTrue("$x then $y", y >= x)
            assertTrue(b.numberWidth >= a.numberWidth && b.panelTitle >= a.panelTitle && b.panelTag >= a.panelTag)
        }
    }
}
