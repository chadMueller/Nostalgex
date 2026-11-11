package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #290's cases, as the Apple TV's GuideTimeout tests and the web's guide-timeout smoke. */
class GuideTimeoutTest {
    private val t0 = 1_000_000L
    private fun due(timeout: GuideTimeout, afterMs: Long, frontmost: Boolean = true, playing: Boolean = true) =
        GuideTimeout.shouldGoFullScreen(timeout, t0, t0 + afterMs, frontmost, playing)

    @Test fun offNeverFires() = assertFalse(due(GuideTimeout.OFF, 24 * 3600_000L))

    @Test fun notWhileTheGuideIsNotInFront() = assertFalse(due(GuideTimeout.FIVE_MINUTES, 600_000, frontmost = false))

    @Test fun notWhileNothingPlays() = assertFalse(due(GuideTimeout.FIVE_MINUTES, 600_000, playing = false))

    @Test fun notUnderTheInterval() {
        assertFalse(due(GuideTimeout.FIVE_MINUTES, 299_999))
        assertFalse(due(GuideTimeout.FIFTEEN_MINUTES, 899_999))
    }

    @Test fun atTheInterval() {
        assertTrue(due(GuideTimeout.FIVE_MINUTES, 300_000))
        assertTrue(due(GuideTimeout.FIFTEEN_MINUTES, 900_000))
    }

    @Test fun theRowCyclesOffFiveFifteen() {
        assertEquals(GuideTimeout.FIVE_MINUTES, GuideTimeout.OFF.next)
        assertEquals(GuideTimeout.FIFTEEN_MINUTES, GuideTimeout.FIVE_MINUTES.next)
        assertEquals(GuideTimeout.OFF, GuideTimeout.FIFTEEN_MINUTES.next)
    }

    @Test fun storedValuesAndTheDefault() {
        assertEquals("nostalgex_guide_timeout", GuideTimeout.STORAGE_KEY)
        assertEquals(listOf("off", "5m", "15m"), GuideTimeout.entries.map { it.stored })
        assertEquals(listOf("OFF", "5 MIN", "15 MIN"), GuideTimeout.entries.map { it.label })
        assertEquals(GuideTimeout.FIVE_MINUTES, GuideTimeout.parse(null))
        assertEquals(GuideTimeout.FIVE_MINUTES, GuideTimeout.parse("10m"))
        assertEquals(GuideTimeout.OFF, GuideTimeout.parse("off"))
        assertEquals(GuideTimeout.FIFTEEN_MINUTES, GuideTimeout.parse("15m"))
    }
}
