package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The Apple TV's MovieSectionScanProgressTests (N-033): a Jellyfin or Emby movie library reports
 * progress after every page, as Plex does, so the stall watch sees a big library arriving; and a
 * scan stopped mid-library keeps the pages it read. Before, a movie library reported once, at its
 * start, and a 15,000-movie Emby library that was still answering was given up at 210 s with
 * everything it had read thrown away.
 */
class MovieSectionScanProgressTest {
    private val movies = 1000

    private fun movie(i: Int) = JsonObject(mapOf(
        "Id" to JsonPrimitive("m$i"),
        "Name" to JsonPrimitive("Film $i"),
        "Type" to JsonPrimitive("Movie"),
        "RunTimeTicks" to JsonPrimitive(90L * 60 * 10_000_000),
        "Genres" to JsonArray(listOf(JsonPrimitive("Drama"))),
    ))

    /** A server with one movie library of `movies` films; `onItems` sees each page request by its start. */
    private fun server(backend: String, onItems: (start: Int) -> Unit = {}, failAt: Int? = null) = MediaBrowserLibrary({ path ->
        when {
            path.contains("Views") -> 200 to JsonObject(mapOf("Items" to JsonArray(listOf(JsonObject(mapOf(
                "Id" to JsonPrimitive("films"), "Name" to JsonPrimitive("Films"), "CollectionType" to JsonPrimitive("movies"),
            ))))))
            path.contains("/Items?") -> {
                val start = Regex("StartIndex=(\\d+)").find(path)!!.groupValues[1].toInt()
                val limit = Regex("Limit=(\\d+)").find(path)!!.groupValues[1].toInt()
                onItems(start)
                if (start == failAt) 500 to null
                else 200 to JsonObject(mapOf(
                    "Items" to JsonArray((start until minOf(start + limit, movies)).map(::movie)),
                    "TotalRecordCount" to JsonPrimitive(movies),
                ))
            }
            else -> 404 to null
        } as Pair<Int, JsonElement?>
    }, "u1", backend)

    @Test fun aMovieLibraryReportsEveryPage() {
        for (backend in listOf("jellyfin", "emby")) {
            val counts = ArrayList<Int>()
            val items = server(backend).scan(progress = { counts += it.itemsSoFar })
            assertEquals(backend, movies, items.size)
            // The section's start, then after each of the five pages of 200.
            assertEquals(backend, listOf(0, 200, 400, 600, 800, 1000), counts.distinct())
        }
    }

    @Test fun aStopMidLibraryKeepsThePagesRead() {
        for (backend in listOf("jellyfin", "emby")) {
            val kept = ArrayList<MediaItem>()
            // The stop lands as the fourth page is asked for, as the client's cancel check does.
            val lib = server(backend, onItems = { start -> if (start == 600) throw ScanCancelled() })
            try {
                lib.scan(onSection = { kept += it })
                fail("$backend: the scan should have been stopped")
            } catch (e: ScanCancelled) {
                // expected
            }
            assertEquals(backend, 600, kept.size)
            assertEquals(backend, (0 until 600).map { "m$it" }, kept.map { it.ratingKey })
        }
    }

    /** An error is not a stop: the library goes whole or not at all, as the web tuner's per-view catch. */
    @Test fun aLibraryThatFailsMidwayLeavesNoneOfItsItems() {
        val items = server("jellyfin", failAt = 400).scan()
        assertTrue(items.isEmpty())
    }
}
