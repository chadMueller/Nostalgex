package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URLDecoder

/**
 * #206, the Apple TV's JellyfinPlaylistLeakTests. The scan asked every view that is not TV or
 * Music Videos for `IncludeItemTypes=Movie`. Jellyfin's Playlists view answers any request with
 * its playlists (`PlaylistsFolder` sets `IncludeItemTypes = [Playlist]`), and each row became a
 * film: a 33 minute workout mix with no year reached VHS VAULT, DVD SHELF and FLICKS. Now views
 * that hold no videos are never read, and a row whose `Type` was not asked for is dropped.
 */
class JellyfinPlaylistLeakTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private fun read(path: String) = Json.parseToJsonElement(repoRoot.resolve(path).readText()).jsonObject
    private val golden = read("scripts/jellyfin-library-golden.json")
    private val config = ChannelConfig(read("channels.json"))
    private val memberships = read("channels-memberships.json")

    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    // The shared cases

    /** `sections`: a CollectionType gives a section type and what it is asked for (null: not read). */
    @Test fun everySectionsCase() {
        val cases = golden["sections"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 20)
        val failures = cases.mapNotNull { c ->
            val type = MediaBrowserLibrary.sectionType(c.s("collectionType"))
            val asked = MediaBrowserLibrary.itemTypes(type)
            if (type == c.s("sectionType") && asked == c.s("itemTypes")) null else "$c: $type, $asked"
        }
        assertEquals("cases that differ from the web tuner", emptyList<String>(), failures)
    }

    /** `types`: a row's Type, what was asked, kept or dropped. */
    @Test fun everyTypesCase() {
        val cases = golden["types"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 18)
        val failures = cases.mapNotNull { c ->
            val kept = MediaBrowserLibrary.hasAskedType(c["item"]!!.jsonObject.s("Type"), c.s("asked")!!)
            if (kept == c["kept"]!!.jsonPrimitive.boolean) null else "$c: kept $kept"
        }
        assertEquals("cases that differ from the web tuner", emptyList<String>(), failures)
    }

    // The scan

    private class Fake(backend: String) {
        val requests = ArrayList<String>()
        val library = MediaBrowserLibrary({ p -> requests += p; reply(p) }, "u1", backend)

        fun askedParents() = requests.filter { it.substringBefore('?').endsWith("/Items") }
            .mapNotNull { Regex("[?&]ParentId=([^&]+)").find(it)?.groupValues?.get(1)?.let { id -> URLDecoder.decode(id, "UTF-8") } }.toSet()

        private fun reply(path: String): Pair<Int, JsonElement?> {
            val bare = path.substringBefore('?')
            fun page(rows: List<JsonObject>) = 200 to JsonObject(mapOf("TotalRecordCount" to JsonPrimitive(rows.size), "Items" to JsonArray(rows)))
            if (bare.endsWith("/UserViews") || bare.endsWith("/Views")) return page(VIEWS)
            if (!bare.endsWith("/Items")) return 404 to null
            return when (Regex("[?&]ParentId=([^&]+)").find(path)?.groupValues?.get(1)) {
                "movies" -> page(FILM_TITLES.mapIndexed { i, t -> row("m$i", t, "Movie", 1984 + i % 6, 100, mapOf("OfficialRating" to JsonPrimitive("PG"))) })
                "tv" -> page(listOf(row("show1", "Lab Show", "Series", 1990, 0)))
                "show1" -> page((1..3).map { n ->
                    row("e$n", "Lab Show $n", "Episode", 1990, 22, mapOf("SeriesName" to JsonPrimitive("Lab Show"),
                        "ParentIndexNumber" to JsonPrimitive(1), "IndexNumber" to JsonPrimitive(n)))
                })
                "mv" -> page(listOf(row("v1", "Song A", "MusicVideo", 1999, 4), row("v2", "Song B", "MusicVideo", 1999, 4),
                    row("v3", "Filed Film", "Movie", 1987, 95)))
                // Whatever is asked, a Playlists view answers with its playlists: no year, 33 minutes.
                "pl" -> page(listOf(row("p1", "Workout Mix", "Playlist", null, 33), row("p2", "Chill Mix", "Playlist", null, 48)))
                "music" -> page(listOf(row("a1", "Track 1", "Audio", null, 3), row("a2", "Track 2", "Audio", null, 4),
                    row("a3", "Best Of Album", "MusicAlbum", null, 40)))
                "boxsets" -> page(listOf(row("b1", "Action Box Set", "BoxSet", null, 240)))
                "home" -> page(listOf(row("h1", "Home Clip", "Video", null, 12)))
                // No CollectionType: a film view, but a row that is not a film is still not a film.
                "mixed" -> page(listOf(row("x1", "Mixed Film", "Movie", 1991, 100), row("x2", "Mixed Playlist", "Playlist", null, 33),
                    row("x3", "Mixed Clip", "Video", null, 9)))
                else -> 404 to null
            }
        }
    }

    private fun check(backend: String) {
        val fake = Fake(backend)
        val items = fake.library.scan()
        val titles = items.map { it.title }.toSet()

        assertTrue("$backend: ${titles.intersect(LEAKED)} scanned as titles", titles.intersect(LEAKED).isEmpty())
        assertTrue("$backend: items asked of ${fake.askedParents().intersect(BLIND_VIEWS)}", fake.askedParents().intersect(BLIND_VIEWS).isEmpty())

        // Controls: what should load still loads.
        for (t in FILM_TITLES) assertTrue("$backend: $t is missing", t in titles)
        assertEquals("$backend: the show's episodes", 3, items.count { it.type == "episode" })
        assertTrue("$backend: a film filed under Music Videos", "Filed Film" in titles)
        assertTrue("$backend: a film in a view with no CollectionType", "Mixed Film" in titles)
        val songs = items.filter { it.title == "Song A" || it.title == "Song B" }
        assertEquals("$backend: MusicVideo rows in a Music Videos library (I-067)", 2, songs.size)
        assertTrue("$backend: and they are music videos", songs.all { it.librarySource == "musicVideo" })

        // Nothing that is not a film reaches any channel, with every channel built.
        val opts = ChannelFilter.Options(memberships, config.exclusiveRules, backend).also { it.prepare(items) }
        val pools = config.channels.associate { def ->
            def.name to ChannelFilter.filterPool(items, ChannelFilter.Channel(def.id, def.rules, def.category), opts).map { it.title }.toSet()
        }
        assertNotNull("$backend: control, VHS VAULT exists", pools["VHS VAULT"])
        assertTrue("$backend: control, a real film is on VHS VAULT", "Vault Film 1" in pools["VHS VAULT"]!!)
        assertTrue("$backend: control, HIGH ROTATION has the music videos", pools["HIGH ROTATION"]!!.containsAll(listOf("Song A", "Song B")))
        for ((name, pool) in pools) assertTrue("$backend: ${pool.intersect(LEAKED)} on $name", pool.intersect(LEAKED).isEmpty())
    }

    @Test fun aJellyfinPlaylistIsNotAFilm() = check("jellyfin")
    @Test fun anEmbyPlaylistIsNotAFilm() = check("emby")

    /** Library selection lists only the views that hold videos, as the Apple TV's does. */
    @Test fun libraryselectionLeavesOutViewsWithNoVideos() {
        val sections = Fake("jellyfin").library.sections("srv", "Server")
        assertEquals(listOf("movies", "tv", "mv", "mixed"), sections.map { it.key })
        assertEquals(listOf("movie", "show", "musicvideo", "movie"), sections.map { it.type })
    }

    companion object {
        private fun row(id: String, name: String, type: String, year: Int?, minutes: Long, extra: Map<String, JsonElement> = emptyMap()) =
            JsonObject(mapOf(
                "Id" to JsonPrimitive(id), "Name" to JsonPrimitive(name), "Type" to JsonPrimitive(type),
                "Genres" to JsonArray(listOf(JsonPrimitive("Drama"))), "RunTimeTicks" to JsonPrimitive(minutes * 600_000_000L),
                "ProviderIds" to JsonObject(mapOf("Tmdb" to JsonPrimitive(Math.floorMod(id.hashCode(), 900_000).toString()))),
                "MediaSources" to JsonArray(listOf(JsonObject(mapOf("Id" to JsonPrimitive("ms-$id"), "Container" to JsonPrimitive("mkv"))))),
            ) + (if (year != null) mapOf("ProductionYear" to JsonPrimitive(year)) else emptyMap()) + extra)

        private fun view(id: String, name: String, type: String?) =
            JsonObject(mapOf("Id" to JsonPrimitive(id), "Name" to JsonPrimitive(name)) + (if (type != null) mapOf("CollectionType" to JsonPrimitive(type)) else emptyMap()))

        /** Eight views, as a user with the usual folders would have them. */
        private val VIEWS = listOf(
            view("movies", "Movies", "movies"), view("tv", "TV Shows", "tvshows"), view("mv", "Music Videos", "musicvideos"),
            view("pl", "Playlists", "playlists"), view("music", "Music", "music"), view("boxsets", "Collections", "boxsets"),
            view("home", "Home Videos", "homevideos"), view("mixed", "Everything Else", null),
        )
        private val FILM_TITLES = (1..6).map { "Vault Film $it" }
        private val LEAKED = setOf("Workout Mix", "Chill Mix", "Track 1", "Track 2", "Best Of Album", "Action Box Set", "Home Clip",
            "Mixed Playlist", "Mixed Clip")
        private val BLIND_VIEWS = setOf("pl", "music", "boxsets", "home")
    }
}
