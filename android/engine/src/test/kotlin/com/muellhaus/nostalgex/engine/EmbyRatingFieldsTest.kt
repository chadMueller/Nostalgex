package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URLDecoder

/**
 * #204 and #209, the Apple TV's EmbyRatingFieldsTests. Emby 4.10 leaves `OfficialRating` and
 * `CommunityRating` out of an Items answer unless the request's `Fields` names them (Jellyfin
 * sends both either way). Before the scan named them, every Emby title read as unrated: a kids
 * channel aired a TV-MA show, VHS VAULT's 9 PM hold held nothing, and the `ratingMin` channels
 * saw no star rating.
 *
 * The fake server answers as Emby 4.10 does, and everything is measured through the real scan and
 * the real stock channel filter over channels.json, so these fail on the old request.
 */
class EmbyRatingFieldsTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private fun read(path: String) = Json.parseToJsonElement(repoRoot.resolve(path).readText()).jsonObject
    private val config = ChannelConfig(read("channels.json"))
    private val memberships = read("channels-memberships.json")

    private data class Film(val id: String, val name: String, val year: Int, val certificate: String?, val community: Double?,
                            val genres: List<String> = listOf("Action"))
    private data class Show(val id: String, val name: String, val year: Int, val certificate: String?, val community: Double?,
                            val genres: List<String>, val episodes: Int = 8)

    /** EMBY_410: a rating comes back only when `Fields` names it. JELLYFIN: always. WITHHELD: never. */
    private enum class Server { EMBY_410, JELLYFIN, WITHHELD }

    private class Fake(val server: Server, val films: List<Film>, val shows: List<Show>) {
        val requests = ArrayList<String>()

        fun library(backend: String = "emby") = MediaBrowserLibrary({ p -> requests += p; reply(p) }, "u1", backend)

        private fun query(path: String) = path.substringAfter('?', "").split('&').filter { it.isNotEmpty() }
            .associate { URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8") }

        private fun reply(path: String): Pair<Int, JsonElement?> {
            val bare = path.substringBefore('?')
            val q = query(path)
            val asked = (q["Fields"] ?: "").split(',').map { it.lowercase() }.toSet()
            fun ratings(certificate: String?, community: Double?): Map<String, JsonElement> {
                val d = LinkedHashMap<String, JsonElement>()
                val sendsCertificate = server == Server.JELLYFIN || (server == Server.EMBY_410 && "officialrating" in asked)
                val sendsScore = server == Server.JELLYFIN || (server == Server.EMBY_410 && "communityrating" in asked)
                if (certificate != null && sendsCertificate) d["OfficialRating"] = JsonPrimitive(certificate)
                if (community != null && sendsScore) d["CommunityRating"] = JsonPrimitive(community)
                return d
            }
            fun base(id: String, name: String, type: String, year: Int, genres: List<String>, minutes: Long) = mapOf(
                "Id" to JsonPrimitive(id), "Name" to JsonPrimitive(name), "Type" to JsonPrimitive(type),
                "Genres" to JsonArray(genres.map(::JsonPrimitive)), "ProductionYear" to JsonPrimitive(year),
                "RunTimeTicks" to JsonPrimitive(minutes * 600_000_000L),
                "ProviderIds" to JsonObject(mapOf("Tmdb" to JsonPrimitive((Math.floorMod(id.hashCode(), 900_000)).toString()))),
                "MediaSources" to JsonArray(listOf(JsonObject(mapOf("Id" to JsonPrimitive("ms-$id"), "Container" to JsonPrimitive("mkv"))))),
            )
            fun page(rows: List<Map<String, JsonElement>>) =
                200 to JsonObject(mapOf("TotalRecordCount" to JsonPrimitive(rows.size), "Items" to JsonArray(rows.map(::JsonObject))))
            if (bare.endsWith("/UserViews") || bare.endsWith("/Views")) {
                fun v(id: String, name: String, type: String) =
                    mapOf("Id" to JsonPrimitive(id), "Name" to JsonPrimitive(name), "CollectionType" to JsonPrimitive(type))
                return page(listOf(v("movies", "Movies", "movies"), v("tv", "TV Shows", "tvshows")))
            }
            if (!bare.endsWith("/Items")) return 404 to null
            val parent = q["ParentId"] ?: ""
            if (parent == "movies") return page(films.map { base(it.id, it.name, "Movie", it.year, it.genres, 100) + ratings(it.certificate, it.community) })
            if (parent == "tv") return page(shows.map { base(it.id, it.name, "Series", it.year, it.genres, 0) + ratings(it.certificate, it.community) })
            val show = shows.firstOrNull { it.id == parent } ?: return 404 to null
            return page((1..show.episodes).map { n ->
                base("${show.id}-e$n", "${show.name} $n", "Episode", show.year, emptyList(), 22) + mapOf(
                    "SeriesName" to JsonPrimitive(show.name), "ParentIndexNumber" to JsonPrimitive(1), "IndexNumber" to JsonPrimitive(n))
            })
        }
    }

    private fun scan(server: Server, backend: String = "emby", films: List<Film> = FILMS, shows: List<Show> = SHOWS) =
        Fake(server, films, shows).let { it.library(backend).scan() to it.requests }

    /** Every stock channel's pool, as the Lineup filters a first load (all channels, same options). */
    private fun pools(items: List<MediaItem>, backend: String = "emby"): Map<Int, List<MediaItem>> {
        val opts = ChannelFilter.Options(memberships, config.exclusiveRules, backend).also { it.prepare(items) }
        return config.channels.associate { def -> def.id to ChannelFilter.filterPool(items, ChannelFilter.Channel(def.id, def.rules, def.category), opts) }
    }

    private fun channel(id: Int, name: String) = config.channels.first { it.id == id }.also { assertEquals(name, it.name) }

    // The request

    @Test fun theScanAsksForBothRatingFields() {
        for (backend in listOf("emby", "jellyfin")) {
            val (_, requests) = scan(Server.EMBY_410, backend)
            val scans = requests.filter { it.substringBefore('?').endsWith("/Items") }
            assertTrue(backend, scans.isNotEmpty())
            for (r in scans) {
                val fields = URLDecoder.decode(Regex("[?&]Fields=([^&]*)").find(r)?.groupValues?.get(1) ?: "", "UTF-8").split(',')
                assertTrue("$backend asks for OfficialRating: $r", "OfficialRating" in fields)
                assertTrue("$backend asks for CommunityRating: $r", "CommunityRating" in fields)
            }
        }
    }

    // The titles

    /** A film and a show's episodes carry the certificate and the star rating; a title with neither stays unrated. */
    @Test fun embyTitlesCarryTheirCertificateAndStarRating() {
        val byTitle = scan(Server.EMBY_410).first.groupBy { it.title }
        assertEquals("R", byTitle["Vault R 4"]!!.single().contentRating)
        assertEquals(8.1, byTitle["Vault R 4"]!!.single().rating, 0.0)
        assertEquals(8.3, byTitle["Vault PG 4"]!!.single().rating, 0.0)
        assertEquals(8, byTitle["South Park"]!!.size)
        assertTrue("episodes take the show's certificate and score",
            byTitle["South Park"]!!.all { it.contentRating == "TV-MA" && it.rating == 8.7 })
        assertTrue(byTitle["Mystery Cartoon"]!!.all { it.contentRating.isNullOrEmpty() && it.rating == 0.0 })
    }

    /** Jellyfin sends them anyway, so its result is Emby's with the fields asked for. */
    @Test fun jellyfinAndEmbyReadTheSameTitles() {
        fun key(i: MediaItem) = "${i.title}|${i.contentRating.orEmpty()}|${i.rating}"
        assertEquals(scan(Server.EMBY_410).first.map(::key).sorted(), scan(Server.JELLYFIN, "jellyfin").first.map(::key).sorted())
    }

    // What the viewer sees

    /** SAT MORNING CARTOONS: no TV-MA or TV-14 show; the TV-Y7 one and the one with no certificate stay. */
    @Test fun aKidsChannelAirsNoAdultShowOnEmby() {
        channel(4, "SAT MORNING CARTOONS")
        val titles = pools(scan(Server.EMBY_410).first)[4]!!.map { it.title }.toSet()
        assertTrue("control: the TV-Y7 cartoon is on it $titles", "Kid Cartoon Hour" in titles)
        assertTrue("control: a show with no certificate is allowed on it $titles", "Mystery Cartoon" in titles)
        assertFalse("TV-MA on a kids channel", "South Park" in titles)
        assertFalse("TV-14 on a kids channel", "Teen Toon" in titles)
    }

    /** The same library read the old way: the kids channel lets both through. The test above has teeth. */
    @Test fun withoutTheFieldsTheKidsChannelLetsThemThrough() {
        val titles = pools(scan(Server.WITHHELD).first)[4]!!.map { it.title }.toSet()
        assertTrue(titles.containsAll(listOf("South Park", "Teen Toon")))
    }

    /** VHS VAULT holds its R titles back before 9 PM and airs them from 9. */
    @Test fun vhsVaultHoldsItsRTitlesBeforeNineOnEmby() {
        val vault = channel(7, "VHS VAULT")
        val pool = pools(scan(Server.EMBY_410).first)[7]!!
        assertEquals("control: all sixteen films are in its pool", FILMS.size, pool.size)
        val afternoon = config.timeFilteredPool(vault, pool, 15).map { it.title }
        assertTrue("an R title at 3 PM: $afternoon", afternoon.none { it.startsWith("Vault R") })
        assertEquals("the seven PG and two PG-13 titles stay", 9, afternoon.size)
        assertEquals("at 10 PM it airs all sixteen", 16, config.timeFilteredPool(vault, pool, 22).size)
    }

    /** WATERSHED (the setting) holds a channel's R and TV-MA titles until 9 PM too. */
    @Test fun watershedHoldsAdultTitlesOnEmby() {
        val built = pools(scan(Server.EMBY_410).first)
        val def = config.channels.firstOrNull { ch ->
            val pool = built[ch.id].orEmpty()
            ch.timeRestrictions?.get("blockRatings") == null && pool.any { it.contentRating == "R" } && pool.any { it.contentRating == "PG" }
        }
        assertNotNull("a channel holding both R and PG films", def)
        val day = config.timeFilteredPool(def!!, built[def.id]!!, 15, watershed = true).map { it.contentRating.orEmpty() }.toSet()
        assertFalse("CH ${def.number} ${def.name} shows R at 3 PM with WATERSHED on", "R" in day)
        assertTrue("and keeps its PG titles", "PG" in day)
    }

    /** CERTIFIED GOLD asks for 8 and up: six films. ALL TIME GREATS asks for 8.2: five. */
    @Test fun aRatingMinChannelReadsEmbyStarRating() {
        channel(68, "CERTIFIED GOLD")
        channel(67, "ALL TIME GREATS")
        val built = pools(scan(Server.EMBY_410).first)
        assertEquals(setOf("Vault R 4", "Vault R 5", "Vault R 7", "Vault PG 4", "Vault PG 7", "Vault PG-13 1"), built[68]!!.map { it.title }.toSet())
        assertEquals(setOf("Vault R 5", "Vault R 7", "Vault PG 4", "Vault PG 7", "Vault PG-13 1"), built[67]!!.map { it.title }.toSet())
    }

    // What changes for a library already on Emby

    /**
     * A `ratingMin` gate is "the server's rating clears the bar OR the OMDb rating does", so a
     * rating that was missing can only add titles. The same synthetic library read without the
     * fields and with them.
     */
    @Test fun ratingMinChannelsOnlyGrow() {
        val (films, shows) = generatedLibrary()
        val after = scan(Server.EMBY_410, films = films, shows = shows).first
        val before = scan(Server.WITHHELD, films = films, shows = shows).first
        assertEquals(before.size, after.size)
        assertTrue("control: nothing rated before", before.all { it.contentRating.isNullOrEmpty() && it.rating == 0.0 })
        val poolsBefore = pools(before)
        val poolsAfter = pools(after)
        val gated = config.channels.filter { it.rules?.get("ratingMin") != null }
        assertTrue(gated.isNotEmpty())
        for (ch in gated) {
            val b = poolsBefore[ch.id].orEmpty().map { it.ratingKey }.toSet()
            val a = poolsAfter[ch.id].orEmpty().map { it.ratingKey }.toSet()
            assertTrue("${ch.name} lost titles", a.containsAll(b))
        }
    }

    companion object {
        /** Sixteen late-1980s films for VHS VAULT (seven R, seven PG, two PG-13), star ratings either side of 8 and 8.2. */
        private val FILMS = listOf(
            Film("r1", "Vault R 1", 1984, "R", 6.5), Film("r2", "Vault R 2", 1985, "R", 7.0),
            Film("r3", "Vault R 3", 1986, "R", 7.5), Film("r4", "Vault R 4", 1987, "R", 8.1),
            Film("r5", "Vault R 5", 1988, "R", 8.5), Film("r6", "Vault R 6", 1989, "R", 5.0),
            Film("r7", "Vault R 7", 1989, "R", 8.9),
            Film("p1", "Vault PG 1", 1984, "PG", 6.2), Film("p2", "Vault PG 2", 1985, "PG", 6.8),
            Film("p3", "Vault PG 3", 1986, "PG", 7.2), Film("p4", "Vault PG 4", 1987, "PG", 8.3),
            Film("p5", "Vault PG 5", 1988, "PG", 4.0), Film("p6", "Vault PG 6", 1989, "PG", 5.5),
            Film("p7", "Vault PG 7", 1989, "PG", 8.6),
            Film("t1", "Vault PG-13 1", 1988, "PG-13", 8.4), Film("t2", "Vault PG-13 2", 1989, "PG-13", 7.9),
        )

        /** TV-MA and TV-14 cartoons that must leave SAT MORNING CARTOONS, a TV-Y7 one and an unrated one that stay. */
        private val SHOWS = listOf(
            Show("sp", "South Park", 1997, "TV-MA", 8.7, listOf("Animation", "Comedy")),
            Show("tt", "Teen Toon", 1995, "TV-14", 6.9, listOf("Animation")),
            Show("kc", "Kid Cartoon Hour", 1985, "TV-Y7", 7.0, listOf("Animation", "Kids")),
            Show("mc", "Mystery Cartoon", 1990, null, null, listOf("Animation")),
        )

        /** The Swift test's deterministic library: 400 films and 25 shows, star ratings around 6.4, a tenth with none. */
        private fun generatedLibrary(): Pair<List<Film>, List<Show>> {
            var seed = 0x9E3779B97F4A7C15uL
            fun next(): Double {
                seed = seed * 6364136223846793005uL + 1442695040888963407uL
                return (seed shr 11).toDouble() / (1L shl 53).toDouble()
            }
            fun gaussian() = (next() + next() + next() + next() - 2) * 1.7
            fun <T> pick(weighted: List<Pair<T, Double>>): T {
                var x = next() * weighted.sumOf { it.second }
                for ((v, w) in weighted) { x -= w; if (x <= 0) return v }
                return weighted.last().first
            }
            fun score(): Double? = if (next() < 0.10) null else (Math.round((6.4 + gaussian()) * 10) / 10.0).coerceIn(2.5, 9.3)
            val filmGenres = listOf(listOf("Action"), listOf("Comedy"), listOf("Drama"), listOf("Thriller"), listOf("Action", "Adventure"),
                listOf("Science Fiction"), listOf("Family", "Comedy"), listOf("Animation", "Family"), listOf("Horror"), listOf("Romance", "Comedy"))
            val films = (0 until 400).map { i ->
                Film("f$i", "Film $i", 1960 + (next() * 65).toInt(),
                    pick(listOf<Pair<String?, Double>>("G" to 8.0, "PG" to 22.0, "PG-13" to 25.0, "R" to 40.0, null to 5.0)),
                    score(), filmGenres[(next() * filmGenres.size).toInt()])
            }
            val showGenres = listOf(listOf("Comedy"), listOf("Drama"), listOf("Animation", "Comedy"), listOf("Animation", "Kids"),
                listOf("Crime", "Drama"), listOf("Science Fiction"), listOf("Reality"), listOf("Animation"))
            val shows = (0 until 25).map { i ->
                Show("s$i", "Show $i", 1960 + (next() * 62).toInt(),
                    pick(listOf<Pair<String?, Double>>("TV-Y" to 10.0, "TV-Y7" to 10.0, "TV-G" to 8.0, "TV-PG" to 20.0, "TV-14" to 27.0, "TV-MA" to 20.0, null to 5.0)),
                    score(), showGenres[(next() * showGenres.size).toInt()], episodes = 14)
            }
            return films to shows
        }
    }
}
