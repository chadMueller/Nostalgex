package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * scripts/filter-golden.json, the file FilterGoldenTests.swift and
 * scripts/nostalgex-filter-golden-smoke.mjs read, against the shipped channels.json, its
 * exclusive rules and channels-memberships.json: the same title on the same channels.
 */
class FilterGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private fun read(path: String) = Json.parseToJsonElement(repoRoot.resolve(path).readText()).jsonObject
    private val golden = read("scripts/filter-golden.json")
    private val config = ChannelConfig(read("channels.json"))
    private val manifest = read("channels-memberships.json")
    private val channels = config.channels.associateBy { it.id }

    private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonObject.list(k: String) = (this[k] as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList()

    /** Same defaults as nostalgex-filter-golden-smoke.mjs toItem. */
    private fun toItem(g: JsonObject): MediaItem {
        val type = g.str("type") ?: "movie"
        return MediaItem(
            ratingKey = "golden",
            title = g.str("title") ?: "",
            type = type,
            duration = (g["duration"] as? JsonPrimitive)?.intOrNull ?: 100,
            artist = g.str("artist"),
            episodeTitle = g.str("episodeTitle"),
            summary = g.str("summary") ?: "",
            originallyAvailableAt = g.str("originallyAvailableAt"),
            year = (g["year"] as? JsonPrimitive)?.intOrNull,
            librarySource = g.str("librarySource") ?: if (type == "episode") "tv" else "movie",
            genres = g.list("genres"),
            contentRating = g.str("contentRating"),
            rating = (g["rating"] as? JsonPrimitive)?.doubleOrNull ?: 0.0,
            studio = g.str("studio"),
            tmdbID = (g["tmdbID"] as? JsonPrimitive)?.longOrNull,
            doviProfile = (g["doviProfile"] as? JsonPrimitive)?.intOrNull,
            enrichment = (g["enrichment"] as? JsonObject)?.let { e ->
                fun num(k: String) = (e[k] as? JsonPrimitive)?.doubleOrNull
                Enrichment(
                    e.list("keywords"), e.list("productionCompanies"), e.list("networks"), e.list("tmdbGenres"),
                    imdbRating = num("imdbRating"), imdbVotes = num("imdbVotes"), rtScore = num("rtScore"),
                    metacriticScore = num("metacriticScore"), awards = e.str("awards"),
                )
            },
        )
    }

    @Test
    fun everyCasePutsTheTitleOnTheAppleTvsChannels() {
        val cases = golden["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size > 50)
        val failures = ArrayList<String>()
        for (c in cases) {
            val g = c["item"]!!.jsonObject
            val item = toItem(g)
            val opts = ChannelFilter.Options(manifest, config.exclusiveRules, g.str("backend") ?: "plex")
            fun passes(id: Int): Boolean {
                val ch = channels[id] ?: error("channel id $id is not in channels.json")
                return ChannelFilter.itemPasses(item, ChannelFilter.Channel(ch.id, ch.rules, ch.category), opts) != null
            }
            val problems = ArrayList<String>()
            for (id in c["in"]?.jsonArray?.map { it.jsonPrimitive.int } ?: emptyList()) if (!passes(id)) problems.add("not on $id ${channels[id]?.name}")
            for (id in c["out"]?.jsonArray?.map { it.jsonPrimitive.int } ?: emptyList()) if (passes(id)) problems.add("on $id ${channels[id]?.name}")
            if (problems.isNotEmpty()) failures.add("${c.str("name")}: ${problems.joinToString("; ")}")
        }
        assertEquals("cases that differ from the Apple TV", emptyList<String>(), failures)
    }

    /**
     * Whole words, with JavaScript's ASCII `\b`. filter-golden.json has no case that tells a
     * whole word from a substring (the JS passes it with `includes` too), so this pins it here.
     */
    @Test
    fun titleRulesMatchWholeWordsOnly() {
        assertTrue(ChannelFilter.titleContainsWord("santa claus", "Santa"))
        assertTrue(ChannelFilter.titleContainsWord("the santa-clause", "santa"))
        assertTrue(!ChannelFilter.titleContainsWord("santana live", "santa"))
        assertTrue(!ChannelFilter.titleContainsWord("kicking & screaming", "scream"))
        assertTrue(!ChannelFilter.titleContainsWord("santa_x", "santa"))
        // Non-ASCII letters are not word characters to JavaScript's `\b` without the u flag.
        assertTrue(ChannelFilter.titleContainsWord("éscream", "scream"))
    }

    @Test
    fun foreignRatingsMapToTheUsBand() {
        assertEquals("PG-13", ChannelFilter.usContentRating("GB-12A", "movie"))
        assertEquals("TV-MA", ChannelFilter.usContentRating("FSK-16", "episode"))
        assertEquals("R", ChannelFilter.usContentRating("gb/15", "movie"))
        assertEquals("PG-13", ChannelFilter.usContentRating("PG-13", "movie"))
        assertEquals("weird", ChannelFilter.usContentRating("weird", "movie"))
    }
}
