package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Live channels.json (N-074): what is taken, what is thrown away, and that the copy kept survives a bad fetch. */
class LiveChannelsTest {
    private val bundled = File(System.getProperty("nostalgex.repoRoot") ?: "..").resolve("channels.json").readText()
    private val bundledVersion = ChannelConfig(kotlinx.serialization.json.Json.parseToJsonElement(bundled) as kotlinx.serialization.json.JsonObject).version!!

    private class MemCache(var text: String? = null, var writes: Int = 0) : LiveChannels.Cache {
        override fun read() = text
        override fun write(text: String) { this.text = text; writes++ }
    }

    /** The bundled file with its version changed (and anything else done to it), as a fetched copy. */
    private fun copy(version: Int = bundledVersion + 1, edit: (String) -> String = { it }) =
        edit(bundled.replaceFirst(Regex("\"version\"\\s*:\\s*\\d+"), "\"version\": $version"))

    private fun live(cache: MemCache, answer: String?) = LiveChannels({ bundled }, cache) { answer }

    @Test fun aLaunchWithNothingKeptReadsTheBundledCopy() {
        val l = live(MemCache(), null).load()
        assertEquals("bundled", l.source)
        assertEquals(bundledVersion, l.config.version)
    }

    @Test fun aGoodCopyIsKeptAndThenReadAtTheNextLaunch() {
        val cache = MemCache()
        val r = live(cache, copy()).refresh()
        assertTrue(r is LiveChannels.Refresh.Updated)
        assertEquals(bundledVersion + 1, (r as LiveChannels.Refresh.Updated).config.version)
        val next = live(cache, null).load()
        assertEquals("cache", next.source)
        assertEquals(bundledVersion + 1, next.config.version)
        assertTrue(next.config.channels.isNotEmpty())
    }

    @Test fun theSameCopyAgainChangesNothing() {
        val cache = MemCache()
        val text = copy()
        live(cache, text).refresh()
        assertTrue(live(cache, text).refresh() is LiveChannels.Refresh.Unchanged)
        assertEquals(1, cache.writes)
    }

    @Test fun anInvalidFileIsRejectedAndTheCacheIsKept() {
        val good = copy(bundledVersion + 1)
        val cache = MemCache(good)
        val bad = listOf(
            "" to "empty",
            "<html><body>502 Bad Gateway</body></html>" to "an error page",
            "{\"version\": 99, \"channels\": [" to "cut off",
            "[]" to "not an object",
            "{\"version\": 99, \"channels\": []}" to "no channels",
            copy(99) { it.replaceFirst("\"channels\": [", "\"channels\": [{\"id\": 1, \"name\": \"A\"}, {\"id\": 1, \"name\": \"B\"},") } to "an id twice",
            "{\"channels\": [{\"id\": 1, \"name\": \"A\"}]}" to "no version",
            "{\"version\": 99, \"channels\": [{\"name\": \"no id\"}]}" to "a channel with no id",
            copy(bundledVersion - 1) to "older than the bundled copy",
            copy(99) { it.replaceFirst("{", "{\"formatVersion\": 2,") } to "a format this build does not read",
            copy(99) { it.replaceFirst("{", "{\"formatVersion\": \"two\",") } to "a format that is not a number",
        )
        for ((text, why) in bad) {
            val r = live(cache, text).refresh()
            assertTrue("$why: should be kept, was ${r::class.simpleName}", r is LiveChannels.Refresh.Kept)
            assertEquals("$why: the kept copy changed", good, cache.text)
        }
        assertEquals(0, cache.writes)
        // A fetch that fails outright keeps it too, and so does a fetch that throws.
        assertTrue(live(cache, null).refresh() is LiveChannels.Refresh.Kept)
        assertTrue(LiveChannels({ bundled }, cache) { error("offline") }.refresh() is LiveChannels.Refresh.Kept)
        // And the next launch still reads it.
        assertEquals("cache", live(cache, null).load().source)
    }

    @Test fun aKeptCopyThatCannotBeReadFallsBackToTheBundledOne() {
        for (broken in listOf("{", "not json", "{\"version\": 99, \"channels\": []}")) {
            val l = live(MemCache(broken), null).load()
            assertEquals("bundled for: $broken", "bundled", l.source)
        }
    }

    @Test fun aKeptCopyOlderThanTheNewBuildIsIgnored() {
        // The build shipped later than the copy was fetched: the bundled file is newer, so it is the one used.
        val l = live(MemCache(copy(bundledVersion - 3)), null).load()
        assertEquals("bundled", l.source)
        assertEquals(bundledVersion, l.config.version)
    }

    @Test fun aFormatTheBuildReadsIsAccepted() {
        val r = live(MemCache(), copy(bundledVersion + 1) { it.replaceFirst("{", "{\"formatVersion\": 1,") }).refresh()
        assertTrue(r is LiveChannels.Refresh.Updated)
    }

    @Test fun aKeptCopyThatCannotBeWrittenIsNotAnUpdate() {
        val cache = object : LiveChannels.Cache {
            override fun read() = null
            override fun write(text: String) = throw java.io.IOException("disk full")
        }
        val r = LiveChannels({ bundled }, cache) { copy() }.refresh()
        assertTrue(r is LiveChannels.Refresh.Kept)
    }
}
