package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.LaunchChannelMemory.Saved
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** The Apple TV's LaunchChannelMemoryTests: saved, restored, gone, renumbered, the default and demo mode. */
class LaunchChannelMemoryTest {
    private data class Ch(val id: Int, val name: String)

    private val lineup = listOf(Ch(1, "NOSTALGEX"), Ch(3, "NOSTALGEX LOL"), Ch(310, "STAR WARS"))

    private fun open(enabled: Boolean, saved: Saved?, demo: Boolean = false, channels: List<Ch> = lineup) =
        LaunchChannelMemory.channelToOpenFirst(channels, Ch::id, Ch::name, enabled, saved, demo)

    @Test fun offByDefault() {
        assertFalse(LaunchChannelMemory.ENABLED_BY_DEFAULT)
        assertEquals("nostalgex_open_on_last_channel", LaunchChannelMemory.ENABLED_KEY)
        assertEquals("nostalgex_last_watched_channel", LaunchChannelMemory.SAVED_KEY)
    }

    @Test fun onAndSavedOpensTheSavedChannel() {
        assertEquals(Ch(3, "NOSTALGEX LOL"), open(true, Saved(3, "NOSTALGEX LOL")))
    }

    @Test fun offOpensTheFirstChannel() {
        assertEquals(Ch(1, "NOSTALGEX"), open(false, Saved(3, "NOSTALGEX LOL")))
    }

    @Test fun nothingSavedOpensTheFirstChannel() {
        assertEquals(Ch(1, "NOSTALGEX"), open(true, null))
    }

    @Test fun aChannelThatIsGoneOpensTheFirst() {
        assertEquals(Ch(1, "NOSTALGEX"), open(true, Saved(42, "GONE")))
    }

    /** A collection or franchise channel renumbered by a rebuild: the id now names another channel. */
    @Test fun aRenumberedChannelOpensTheFirst() {
        assertEquals(Ch(1, "NOSTALGEX"), open(true, Saved(310, "INDIANA JONES")))
    }

    @Test fun demoModeOpensTheFirst() {
        assertEquals(Ch(1, "NOSTALGEX"), open(true, Saved(3, "NOSTALGEX LOL"), demo = true))
    }

    @Test fun anEmptyLineupOpensNothing() {
        assertNull(open(true, Saved(3, "NOSTALGEX LOL"), channels = emptyList()))
    }
}
