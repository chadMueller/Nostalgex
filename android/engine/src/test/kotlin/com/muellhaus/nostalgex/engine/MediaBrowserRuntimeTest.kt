package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.net.URLDecoder

/**
 * What a Jellyfin or Emby scan keeps of a runtime (#315): the floored minutes in `duration` and the real runtime in
 * seconds in `exactDurationSeconds`, which the schedule gives a programme as its slot (`slotSeconds`). Over canned answers.
 */
class MediaBrowserRuntimeTest {
    private fun ticks(seconds: Double) = (seconds * 10_000_000).toLong()

    private fun movie(id: String, runtimeSeconds: Double?) = buildJsonObject {
        put("Id", id); put("Name", "Movie $id"); put("Type", "Movie"); put("DateCreated", "2026-01-02T03:04:05.0000000Z")
        if (runtimeSeconds != null) put("RunTimeTicks", ticks(runtimeSeconds))
    }

    private fun episode(id: String, runtimeSeconds: Double) = buildJsonObject {
        put("Id", id); put("Name", "Episode $id"); put("Type", "Episode"); put("ParentIndexNumber", 1); put("IndexNumber", 1)
        put("RunTimeTicks", ticks(runtimeSeconds))
    }

    private fun serve(path: String): Pair<Int, JsonElement?> {
        val bare = path.substringBefore('?')
        val q = path.substringAfter('?', "").split('&').filter { it.isNotEmpty() }
            .associate { URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8") }
        fun page(items: List<JsonObject>) = 200 to JsonObject(mapOf("Items" to JsonArray(items), "TotalRecordCount" to JsonPrimitive(items.size)))
        if (bare.endsWith("/UserViews") || Regex("/Users/[^/]+/Views").matches(bare)) {
            return page(listOf(
                buildJsonObject { put("Id", "films"); put("Name", "Films"); put("CollectionType", "movies") },
                buildJsonObject { put("Id", "shows"); put("Name", "Shows"); put("CollectionType", "tvshows") },
            ))
        }
        if (bare.endsWith("/Items")) {
            return when (q["ParentId"]) {
                "films" -> page(listOf(
                    movie("a", 5460.4),     // 91 minutes floored, 0.4 s past: slot 5461
                    movie("b", 3600.0),     // a whole hour
                    movie("c", 5390.0),     // 89 minutes floored, 50 s past: still in range
                    movie("d", null),       // no runtime: dropped, as before
                ))
                "shows" -> page(listOf(buildJsonObject { put("Id", "show1"); put("Name", "A Show"); put("Type", "Series") }))
                "show1" -> page(listOf(episode("e1", 1500.2)))
                else -> page(emptyList())
            }
        }
        return 404 to null
    }

    private val items = MediaBrowserLibrary({ p -> serve(p) }, "user1", "jellyfin").scan()
    private fun item(id: String) = items.first { it.ratingKey == id }

    @Test fun aMovieKeepsItsRealRuntimeBesideTheFlooredMinutes() {
        assertEquals(91, item("a").duration)
        assertEquals(5460.4, item("a").exactDurationSeconds!!, 1e-6)
        assertEquals(5461, item("a").slotSeconds)
    }

    @Test fun aWholeHourIsExact() {
        assertEquals(60, item("b").duration)
        assertEquals(3600, item("b").slotSeconds)
    }

    @Test fun aRuntimeUnderTheNextMinuteKeepsItsLength() {
        assertEquals(89, item("c").duration)
        assertEquals(5390, item("c").slotSeconds)
    }

    @Test fun anEpisodeKeepsItsRuntimeToo() {
        val e = item("e1")
        assertEquals(25, e.duration)
        assertEquals(1500.2, e.exactDurationSeconds!!, 1e-6)
        assertEquals(1501, e.slotSeconds)
    }

    @Test fun anItemWithNoRuntimeIsStillDropped() {
        assertEquals(listOf("a", "b", "c", "e1"), items.map { it.ratingKey }.sorted())
        assertNull(items.firstOrNull { it.ratingKey == "d" })
    }
}
