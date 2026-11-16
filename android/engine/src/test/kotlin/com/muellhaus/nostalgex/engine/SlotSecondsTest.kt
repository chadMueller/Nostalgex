package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Test

/** The slot a programme is given (#315), held to the five edge cases in scripts/schedule-parity-golden.json (channel 12). */
class SlotSecondsTest {
    private fun slot(minutes: Int, exact: Double?) = MediaItem("k", duration = minutes, exactDurationSeconds = exact).slotSeconds

    @Test fun noRuntimeIsTheMinutes() = assertEquals(95 * 60, slot(95, null))
    @Test fun aRuntime61SecondsOffIsABadValueSoTheMinutes() = assertEquals(90 * 60, slot(90, 5461.0))
    @Test fun aRuntimeInRangeIsRoundedUp() = assertEquals(5461, slot(90, 5460.4))
    @Test fun aShorterRuntimeIsItsOwnLength() = assertEquals(5390, slot(90, 5390.0))
    @Test fun aWholeMinuteIsThatMinute() = assertEquals(3600, slot(60, 3600.0))
    @Test fun nonsenseIsTheMinutes() {
        assertEquals(60 * 60, slot(60, 0.5))
        assertEquals(60 * 60, slot(60, Double.NaN))
        assertEquals(60 * 60, slot(60, Double.POSITIVE_INFINITY))
    }
    @Test fun secondsFromServerValues() {
        assertEquals(5460.4, DailyManifest.secondsFromPlexMs(5_460_400)!!, 1e-9)
        assertEquals(5460.4, DailyManifest.secondsFromTicks(54_604_000_000)!!, 1e-6)
        assertEquals(null, DailyManifest.secondsFromPlexMs(0))
        assertEquals(null, DailyManifest.secondsFromTicks(null))
    }
}
