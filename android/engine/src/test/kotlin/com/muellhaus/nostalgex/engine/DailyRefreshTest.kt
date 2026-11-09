package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.DailyRefresh.SectionStamp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #195. The due rule is the Roku's DailyRefreshTests.brs case for case; the signature and the
 * skip are the Apple TV's LibraryRefreshEfficiencyTests.
 */
class DailyRefreshTest {
    private val h = 3600L
    private val now = 1761480000L

    @Test fun theTimes() {
        assertEquals("checks every 15 minutes", 900L, DailyRefresh.CHECK_SECONDS)
        assertEquals("refresh after 6 hours", 21600L, DailyRefresh.AFTER_SECONDS)
        assertEquals("the cap is a day", 86400L, DailyRefresh.FORCE_AFTER_SECONDS)
    }

    @Test fun whenTheCheckIsDue() {
        assertFalse("loaded 5 h 59 m ago: not yet", DailyRefresh.due(now, now - 6 * h + 60, 0))
        assertTrue("loaded 6 h ago, never checked: due", DailyRefresh.due(now, now - 6 * h, 0))
        assertTrue("loaded a day ago, never checked: due", DailyRefresh.due(now, now - 24 * h, 0))
        assertFalse("load old, checked an hour ago: wait", DailyRefresh.due(now, now - 24 * h, now - h))
        assertTrue("load old, checked 6 h ago: due", DailyRefresh.due(now, now - 24 * h, now - 6 * h))
        assertFalse("loaded just now: not due", DailyRefresh.due(now, now, 0))
    }

    private fun section(key: String, updated: Long?, changed: Long?) = SectionStamp(key, updated, changed)

    @Test fun theSignatureIsOrderIndependentAndTracksRealChanges() {
        val a = DailyRefresh.signature("s", listOf(section("1", 20, 5), section("2", 3, null)))
        val b = DailyRefresh.signature("s", listOf(section("2", 3, null), section("1", 20, 5)))
        assertEquals(a, b)
        assertEquals("s:1=u20/c5,2=u3/c0", a)
        assertNotEquals(a, DailyRefresh.signature("s", listOf(section("1", 20, 99), section("2", 3, null))))
    }

    /** Plex's scheduled scans bump scannedAt every run, which SectionStamp doesn't carry, so a routine scan changes nothing. */
    @Test fun aRoutineRescanDoesNotChangeTheSignature() {
        val before = DailyRefresh.signature("s", listOf(section("1", 1789169420, 2339733)))
        val after = DailyRefresh.signature("s", listOf(section("1", 1789169420, 2339733)))
        assertEquals(before, after)
    }

    /** Claiming "unchanged" about a library that can't be seen would freeze the guide. */
    @Test fun sectionsWithoutStampsGiveNoSignature() {
        assertNull(DailyRefresh.signature("s", listOf(section("1", null, null))))
        assertNull(DailyRefresh.signature("s", listOf(section("1", 20, 5), section("2", null, null))))
        assertNull(DailyRefresh.signature("s", emptyList()))
    }

    @Test fun serversCombineInAnyOrder() {
        assertEquals(DailyRefresh.combine(listOf("b:1=u1/c1", "a:1=u2/c2")), DailyRefresh.combine(listOf("a:1=u2/c2", "b:1=u1/c1")))
    }

    @Test fun skipOnlyWhenUnchangedAndUnderTheCap() {
        assertTrue(DailyRefresh.shouldSkip(7 * h, "x", "x"))
        assertFalse("library changed", DailyRefresh.shouldSkip(7 * h, "x", "y"))
        assertFalse("hard cap: watch counts etc. don't move the stamps", DailyRefresh.shouldSkip(25 * h, "x", "x"))
        assertFalse("no baseline", DailyRefresh.shouldSkip(7 * h, null, "x"))
        assertFalse("server unreachable or the backend can't say", DailyRefresh.shouldSkip(7 * h, "x", null))
    }
}
