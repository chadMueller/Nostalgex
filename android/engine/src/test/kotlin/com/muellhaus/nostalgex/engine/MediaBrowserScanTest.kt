package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URLDecoder

/**
 * The Kotlin Jellyfin and Emby scan against the web tuner's own, over the same saved server
 * answers (roku/tests/fixtures/mediabrowser-server.json, served as the Roku's serveFixture
 * serves them): the same items, in the same order, field for field.
 */
class MediaBrowserScanTest {
    private val vectors = Json.parseToJsonElement(File(System.getProperty("nostalgex.mediaBrowserVectors")).readText()).jsonObject
    private val fixture = vectors["fixture"]!!.jsonObject

    private fun serve(path: String): Pair<Int, JsonElement?> {
        val bare = path.substringBefore('?')
        val q = path.substringAfter('?', "").split('&').filter { it.isNotEmpty() }
            .associate { URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8") }
        val views = fixture["views"]!!.jsonArray
        if (bare.endsWith("/UserViews") || Regex("/Users/[^/]+/Views").matches(bare)) {
            return 200 to JsonObject(mapOf("Items" to views, "TotalRecordCount" to JsonPrimitive(views.size)))
        }
        if (bare.endsWith("/Items")) {
            val parent = q["ParentId"]
            if ((fixture["fail"] as? JsonArray)?.any { it.jsonPrimitive.content == parent } == true) return 500 to null
            val all = (fixture["items"]!!.jsonObject[parent] as? JsonArray ?: JsonArray(emptyList()))
                .filter { it.jsonObject["Type"]?.jsonPrimitive?.content == q["IncludeItemTypes"] }
            val start = q["StartIndex"]?.toInt() ?: 0
            val limit = q["Limit"]?.toInt() ?: all.size
            return 200 to JsonObject(mapOf("Items" to JsonArray(all.drop(start).take(limit)), "TotalRecordCount" to JsonPrimitive(all.size)))
        }
        return 404 to null
    }

    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonObject.l(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.longOrNull

    @Test
    fun theScanMakesTheWebTunersItems() {
        val requests = ArrayList<String>()
        val got = MediaBrowserLibrary({ p -> requests += p; serve(p) }, vectors["userId"]!!.jsonPrimitive.content, "jellyfin").scan()
        val want = vectors["items"]!!.jsonArray.map { it.jsonObject }
        assertEquals("item count", want.size, got.size)
        val problems = ArrayList<String>()
        for ((i, pair) in want.zip(got).withIndex()) {
            val (w, g) = pair
            fun check(field: String, expected: Any?, actual: Any?) {
                if (expected != actual) problems += "#$i ${w.s("ratingKey")} $field: web $expected, here $actual"
            }
            check("ratingKey", w.s("ratingKey"), g.ratingKey)
            check("title", w.s("title"), g.title)
            check("artist", w.s("artist"), g.artist)
            check("episodeTitle", w.s("episodeTitle"), g.episodeTitle)
            check("summary", w.s("summary") ?: "", g.summary)
            check("year", (w["year"] as? JsonPrimitive)?.intOrNull, g.year)
            check("originallyAvailableAt", w.s("originallyAvailableAt"), g.originallyAvailableAt)
            check("contentRating", w.s("contentRating") ?: "", g.contentRating ?: "")
            check("duration", w.l("duration")?.toInt(), g.duration)
            check("partKey", w.s("partKey"), g.partKey)
            check("container", w.s("container"), g.container)
            check("videoCodec", w.s("videoCodec"), g.videoCodec)
            check("audioCodec", w.s("audioCodec"), g.audioCodec)
            check("bitrate", w.l("bitrate")?.toInt() ?: 0, g.bitrate ?: 0)
            check("genres", w["genres"]!!.jsonArray.map { it.jsonPrimitive.content }, g.genres)
            check("rating", (w["rating"] as? JsonPrimitive)?.doubleOrNull ?: 0.0, g.rating)
            check("type", w.s("type"), g.type)
            check("viewCount", w.l("viewCount")?.toInt() ?: 0, g.viewCount)
            check("addedAt", w.l("addedAt") ?: 0, g.addedAt)
            check("studio", w.s("studio") ?: "", g.studio ?: "")
            check("librarySource", w.s("librarySource"), g.librarySource)
            check("tmdbID", w.s("tmdbID")?.toLongOrNull(), g.tmdbID)
            check("doviProfile", w.l("doviProfile")?.toInt(), g.doviProfile)
        }
        assertEquals("fields that differ from the web tuner (first 15)", emptyList<String>(), problems.take(15))
        // The same requests, as a set: the web asks five series at once, so its order interleaves.
        assertEquals(vectors["requests"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet(), requests.toSet())
    }

    /** Answers taken from the JS itself (parseMusicVideoFromPlex), its "( )" quirk included. */
    @Test
    fun musicVideoTitlesSplitAsTheWebSplitsThem() {
        assertEquals("One More Time ( )" to "Daft Punk", MusicTitle.musicVideo("Daft Punk - One More Time (Official Video) [HD]", null, null))
        assertEquals("Bohemian Rhapsody" to "Queen", MusicTitle.musicVideo("Bohemian Rhapsody by Queen", null, null))
        assertEquals("Song" to "Artist", MusicTitle.musicVideo("Artist feat. Someone - Song ft. Other (1999)", null, null))
        assertEquals("Just A Title" to null, MusicTitle.musicVideo("Just A Title", null, null))
        assertTrue(MusicTitle.musicVideo("Daft Punk - One More Time", "Daft Punk Official", null).second == "Daft Punk Official")
    }

    @Test
    fun embyDolbyVisionProfiles() {
        assertEquals(5, MediaBrowserLibrary.embyDoviProfile("DoviProfile50"))
        assertEquals(8, MediaBrowserLibrary.embyDoviProfile("doviprofile81"))
        assertEquals(null, MediaBrowserLibrary.embyDoviProfile("Hdr10"))
    }
}
