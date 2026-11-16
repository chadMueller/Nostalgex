package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The loading pattern's words (Chad, 2026-11-15), pinned so the four platforms can be compared line by line. */
class LoadNoticeTest {
    @Test fun theTitlesAreTheTwoTheBriefNames() {
        assertEquals("CHANNEL GUIDE IS CHANGING", LoadNotice.title(afterSwitch = true))
        assertEquals("LOADING YOUR LIBRARY", LoadNotice.title(afterSwitch = false))
    }

    @Test fun theReadLineCountsTitlesAndSaysOfNOnlyWithATotal() {
        assertEquals("READ 4,210 TITLES", LoadNotice.readLine(4210))
        assertEquals("READ 4,210 OF 9,800 TITLES", LoadNotice.readLine(4210, 9800))
        assertEquals("READ 1 TITLE", LoadNotice.readLine(1))
        assertEquals("READ 0 TITLES", LoadNotice.readLine(0))
    }

    @Test fun aTotalBelowWhatWasReadIsNotShown() {
        // A server that under-reports: "READ 5 OF 3" would be wrong, so the plain count says what is known.
        assertEquals("READ 5 TITLES", LoadNotice.readLine(5, 3))
        assertEquals("READ 5 TITLES", LoadNotice.readLine(5, 0))
    }

    @Test fun theLibraryLineNamesTheLibraryAndItsTotalWhenKnown() {
        assertEquals("MOVIES", LoadNotice.libraryLine("Movies"))
        assertEquals("MOVIES: 1,200 OF 3,400", LoadNotice.libraryLine("Movies", 1200, 3400))
        assertEquals("TV SHOWS: 12 OF 40", LoadNotice.libraryLine(" TV shows ", 12, 40))
        assertEquals("MOVIES", LoadNotice.libraryLine("Movies", 12, null))
    }

    @Test fun theScanLineHasTheLibraryAndHowFarOnlyWhenTheServerSaid() {
        fun p(type: String, so: Int, done: Int? = null, total: Int? = null, sd: Int? = null, st: Int? = null) =
            ScanProgress(0, 2, "x", type, so, done, total, sectionTotal = st, sectionDone = sd)
        assertEquals("MOVIES: 1,200 OF 3,400", LoadNotice.scanLine(p("movie", 5000, sd = 1200, st = 3400), "Movies"))
        assertEquals("TV SHOWS: 12 OF 40", LoadNotice.scanLine(p("show", 900, done = 12, total = 40), "TV shows"))
        assertEquals("MOVIES", LoadNotice.scanLine(p("movie", 5000), "Movies"))
        assertEquals("STUB A · MOVIES: 40 OF 40", LoadNotice.scanLine(p("movie", 40, sd = 40, st = 40), "Movies", "Stub A"))
    }

    @Test fun theHeaderLinesAreUpdatingThenReady() {
        assertEquals("UPDATING LIBRARY", HeaderNotice.Updating(null).line)
        assertEquals("UPDATING LIBRARY", HeaderNotice.Updating(0).line)
        assertEquals("UPDATING LIBRARY: 2,300 TITLES READ", HeaderNotice.Updating(2300).line)
        assertEquals("GUIDE READY: 4,210 TITLES", HeaderNotice.Ready(4210).line)
        assertEquals("GUIDE READY: 1 TITLE", HeaderNotice.Ready(1).line)
    }

    @Test fun theReadyLineStaysForAboutFourSeconds() = assertEquals(4000L, LoadNotice.READY_MS)

    @Test fun theCountReadsTheSameInAnyLocale() {
        val before = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.GERMANY)
            assertEquals("4,210", LoadNotice.count(4210))
        } finally { java.util.Locale.setDefault(before) }
    }

    @Test fun theBlockHasNoReadLineUntilTheServerAnswers() {
        assertNull(GuideLoad(afterSwitch = true).readLine)
        assertEquals("READ 40 TITLES", GuideLoad(afterSwitch = true, read = 40).readLine)
        assertEquals("CHANNEL GUIDE IS CHANGING", GuideLoad(afterSwitch = true).title)
    }

    @Test fun onlyAFinishedWholeReadSaysGuideReady() {
        assertTrue(readyAfter(RefreshResult.ADOPTED))
        assertTrue(readyAfter(RefreshResult.UNCHANGED))
        assertFalse(readyAfter(RefreshResult.ABANDONED))
        assertFalse(readyAfter(RefreshResult.STALE))
    }
}
