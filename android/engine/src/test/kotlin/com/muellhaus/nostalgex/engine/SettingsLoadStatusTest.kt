package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The SERVERS & ACCOUNTS page's progress while a server change is built with Settings left open: the loading pattern's own words, in order. */
class SettingsLoadStatusTest {
    private val S = SettingsLoadStatus

    @Test fun nothingRunningSaysNothing() = assertNull(S.lines(null, null))

    @Test fun theReadShowsBuildingChannelsTheCountAndTheLibrary() {
        val l = S.lines(GuideLoad(afterSwitch = true, read = 4210, detail = LoadNotice.libraryLine("Movies", 1200, 3000)), null)!!
        assertEquals("BUILDING CHANNELS", l.title)
        assertEquals("READ 4,210 TITLES", l.count)
        assertEquals("MOVIES: 1,200 OF 3,000", l.detail)
        assertFalse(l.ready)
    }

    @Test fun beforeTheFirstAnswerThereIsNoCount() {
        val l = S.lines(GuideLoad(afterSwitch = true, detail = "CONNECTING TO PLEX"), null)!!
        assertNull(l.count)
        assertEquals("CONNECTING TO PLEX", l.detail)
    }

    @Test fun theLaterStepsFollowAsTheyHappen() {
        val steps = listOf("DISCOVERING COLLECTIONS", "ENRICHING METADATA", "CHANNEL 5 OF 22", SettingsLoadStatus.SCHEDULE)
        for (d in steps) assertEquals(d, S.lines(GuideLoad(true, 100, d), null)!!.detail)
        assertEquals("BUILDING SCHEDULE", SettingsLoadStatus.SCHEDULE)
        // The title stays BUILDING CHANNELS throughout.
        assertTrue(steps.all { S.lines(GuideLoad(true, 100, it), null)!!.title == "BUILDING CHANNELS" })
    }

    @Test fun whenItIsDoneTheGuideReadyLineFollows() {
        val l = S.lines(null, HeaderNotice.Ready(11805))!!
        assertEquals("GUIDE READY: 11,805 TITLES", l.title)
        assertTrue(l.ready)
        assertNull(l.count)
        // A load still running outranks a ready line left in the header.
        assertEquals("BUILDING CHANNELS", S.lines(GuideLoad(true, 1), HeaderNotice.Ready(5))!!.title)
    }

    @Test fun aRefreshBehindSaysUpdatingLibrary() {
        assertEquals("UPDATING LIBRARY: 300 TITLES READ", S.lines(null, HeaderNotice.Updating(300))!!.title)
        assertEquals("UPDATING LIBRARY", S.lines(null, HeaderNotice.Updating(null))!!.title)
    }
}
