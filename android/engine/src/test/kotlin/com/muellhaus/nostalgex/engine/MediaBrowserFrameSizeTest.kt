package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #287: a Jellyfin or Emby item keeps its video stream's frame size, so a 4K film's server
 * stream gets the 40 s startup deadline (PlaybackWatchdog.deadlineSeconds) and a 1080p one 20.
 * The items are a lab Jellyfin 12.4's answers to the scan's own request, saved with ids and
 * paths taken out (src/test/resources/mediabrowser-items). The Emby case serves the same
 * answer through the scan's Emby path: Emby's MediaStreams have the same Width and Height, and
 * no Emby server was at hand to save one from.
 */
class MediaBrowserFrameSizeTest {
    private fun saved(name: String) = Json.parseToJsonElement(javaClass.getResource("/mediabrowser-items/$name")!!.readText())

    private fun scan(answer: JsonElement, backend: String): MediaItem = MediaBrowserLibrary({ path ->
        when {
            path.contains("Views") -> 200 to JsonObject(mapOf("Items" to JsonArray(listOf(JsonObject(mapOf(
                "Id" to JsonPrimitive("films"), "Name" to JsonPrimitive("Films"), "CollectionType" to JsonPrimitive("movies")))))))
            path.contains("/Items?") -> 200 to answer
            else -> 404 to null
        } as Pair<Int, JsonElement?>
    }, "u1", backend).scan().single()

    @Test fun aScopeFilmIsFourKByItsWidth() {
        for (backend in listOf("jellyfin", "emby")) {
            val item = scan(saved("jellyfin-scope.json"), backend)
            assertEquals(backend, 3840, item.videoWidth)
            assertEquals(backend, 1600, item.videoHeight)
            assertEquals("$backend: a 4K server stream waits 40 s", 40, PlaybackWatchdog.deadlineSeconds(false, item.videoWidth, item.videoHeight))
            assertEquals("$backend: direct play still 15 s", 15, PlaybackWatchdog.deadlineSeconds(true, item.videoWidth, item.videoHeight))
        }
    }

    @Test fun aSmallerFilmStaysAtTwentySeconds() {
        for (backend in listOf("jellyfin", "emby")) {
            val item = scan(saved("jellyfin-commentary.json"), backend)
            assertEquals(backend, 1280, item.videoWidth)
            assertEquals(backend, 720, item.videoHeight)
            assertEquals(backend, 20, PlaybackWatchdog.deadlineSeconds(false, item.videoWidth, item.videoHeight))
        }
    }

    /** With no video stream there is no size, and the deadline is the 20 s it always was. */
    @Test fun noVideoStreamNoSize() {
        val bare = Json.parseToJsonElement("""{"Items":[{"Id":"x","Name":"X","Type":"Movie","RunTimeTicks":54000000000,"MediaSources":[{"Id":"x","MediaStreams":[]}]}],"TotalRecordCount":1}""")
        val item = scan(bare, "jellyfin")
        assertEquals(null, item.videoWidth)
        assertEquals(20, PlaybackWatchdog.deadlineSeconds(false, item.videoWidth, item.videoHeight))
    }
}
