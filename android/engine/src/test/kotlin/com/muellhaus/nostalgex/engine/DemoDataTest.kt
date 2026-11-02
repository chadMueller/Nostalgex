package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneId
import java.time.ZonedDateTime

/** Demo mode: the Apple TV's five sample channels air as a lineup, and the clip seeks inside its 600 s. */
class DemoDataTest {
    private val root = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private val config = ChannelConfig(Json.parseToJsonElement(File(root, "channels.json").readText()).jsonObject)

    @Test fun theFiveChannelsOfTheAppleTv() {
        val ch = DemoData.channels()
        assertEquals(listOf(1, 2, 3, 4, 5), ch.map { it.number })
        assertEquals(listOf("DEMO ACTION", "DEMO COMEDY", "DEMO SCI-FI", "DEMO 80s TV", "DEMO LATE NIGHT"), ch.map { it.name })
        assertTrue(ch.all { it.pool.size == 5 && it.pool.all { i -> i.duration > 0 } })
    }

    @Test fun everyChannelHasAGuideAndSomethingOn() {
        val zone = ZoneId.of("America/New_York")
        val lineup = Lineup(config, null, DailyManifest(zone, InMemoryManifestStore()), DemoData.SERVER_KEY)
        lineup.airFixed(DemoData.channels())
        val now = ZonedDateTime.of(2026, 11, 2, 20, 15, 0, 0, zone)
        lineup.rebuildSchedules(now)
        assertEquals(5, lineup.schedules.size)
        for (ch in lineup.channels) {
            val pick = lineup.tune(ch, now)!!
            assertTrue(pick.item in ch.pool)
            assertNotNull(lineup.schedules[ch.id]?.nowPlaying)
        }
        // Packages don't reach it: the demo channels stay whatever is switched on.
        lineup.setBundles(setOf("nostalgex", "kids"))
        assertEquals(5, lineup.channels.size)
    }

    /** playerSeekSeconds: 87% of tune-ins land 600 s or more into a block, past the clip's end. */
    @Test fun theClipSeeksToTheClockModuloItsLength() {
        assertEquals(0L, DemoData.clipOffset(0))
        assertEquals(599L, DemoData.clipOffset(599))
        assertEquals(0L, DemoData.clipOffset(600))
        assertEquals(1234L % 600, DemoData.clipOffset(1234))
    }
}
