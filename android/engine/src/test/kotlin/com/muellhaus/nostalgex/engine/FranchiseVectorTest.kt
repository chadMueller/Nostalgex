package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The franchise builder's text handling against the web tuner's own
 * (scripts/nostalgex-franchise-builder.js), over the edge cases the Roku port tests with
 * (roku/tests/gen-franchise.mjs): Unicode titles and their keys, case mapping (final sigma,
 * ß, İ), token boundaries next to accents, kana and superscripts, cleaned and merged names,
 * and auto-found channels that only name and sort right by code point. Every answer is the
 * JS's, written out by the `genFranchiseVectors` task.
 */
class FranchiseVectorTest {
    private val vectors = Json.parseToJsonElement(File(System.getProperty("nostalgex.franchiseVectors")).readText()).jsonObject
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot"))
    private val dictionary = FranchiseBuilder.parseDefinitions(repoRoot.resolve("franchises.json").readText())

    private fun list(k: String) = vectors[k]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.s(k: String) = this[k]!!.jsonPrimitive.content

    @Test fun titlesNormalizeAndKeyAsTheWebTunersDo() {
        val failures = ArrayList<String>()
        for (v in list("text")) {
            val title = v.s("title")
            val n = FranchiseBuilder.normalizedTitle(title)
            val k = FranchiseBuilder.explicitTitleKey(title)
            if (n != v.s("normalized")) failures.add("normalizedTitle ${JsonPrimitive(title)}: want ${JsonPrimitive(v.s("normalized"))}, have ${JsonPrimitive(n)}")
            if (k != v.s("key")) failures.add("explicitTitleKey ${JsonPrimitive(title)}: want ${JsonPrimitive(v.s("key"))}, have ${JsonPrimitive(k)}")
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test fun tokensMatchOnTheSameBoundaries() {
        for (v in list("tokens")) {
            assertEquals("titleContainsToken(${v["title"]}, ${v["token"]})", v["out"]!!.jsonPrimitive.boolean,
                FranchiseBuilder.titleContainsToken(v.s("title"), v.s("token")))
        }
    }

    @Test fun franchiseNamesCleanStripAndMerge() {
        for (v in list("names")) {
            val name = v.s("name")
            assertEquals("cleanFranchiseName ${v["name"]}", v.s("clean"), FranchiseBuilder.cleanFranchiseName(name))
            assertEquals("stripParentheticalSuffix ${v["name"]}", v.s("strip"), FranchiseBuilder.stripParentheticalSuffix(name))
            assertEquals("franchiseMergeKey ${v["name"]}", v.s("merge"), FranchiseBuilder.franchiseMergeKey(name))
        }
    }

    @Test fun theSameFranchisesStartSwitchedOn() {
        assertEquals(vectors["defaultOn"]!!.jsonArray.map { it.jsonPrimitive.content }, FranchiseBuilder.defaultOnIDs(dictionary).toList())
        // isOn: an explicit choice wins, else the default.
        assertTrue(FranchiseBuilder.isOn("dict:STAR TREK", null, null, dictionary))
        assertEquals(false, FranchiseBuilder.isOn("dict:STAR TREK", null, setOf("dict:STAR TREK"), dictionary))
        assertTrue(FranchiseBuilder.isOn("dict:JOHN WICK", setOf("dict:JOHN WICK"), setOf("dict:JOHN WICK"), dictionary))
    }

    @Test fun librariesGroupNameAndSortAsTheWebTunersDo() {
        val failures = ArrayList<String>()
        for (c in list("cases")) {
            val got = FranchiseBuilder.build(
                movies = Franchises.items(c["movies"]),
                tvItems = Franchises.items(c["tvItems"]),
                definitions = dictionary,
                availableStockChannelIDs = Franchises.ints(c["availableStockChannelIDs"]),
            )
            val want = c["expected"]!!
            val have = Franchises.project(got)
            if (want != have) failures.add("case ${c["name"]}\n  want $want\n  have $have")
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    /**
     * Names compare composed (NFC), so an E with a combining accent sorts as É, after Z.
     * None of the generated vectors carries a decomposed name, so the JS's answer for this
     * library is pinned here: [["ZED","tmdb:8002"],["ÉMILA","tmdb:8000"],["ÉMILE","tmdb:8001"]].
     */
    @Test fun decomposedNamesSortAsComposed() {
        fun film(id: String, fid: Long, name: String) =
            MediaItem(ratingKey = id, title = id, enrichment = Enrichment(franchiseID = fid.toDouble(), franchiseName = name))
        val movies = (1..3).map { film("a$it", 8001, "Émile Collection") } +
            (1..3).map { film("b$it", 8000, "Émila Collection") } +
            (1..3).map { film("c$it", 8002, "Zed Collection") }
        val got = FranchiseBuilder.build(movies, emptyList(), emptyList(), emptyList())
        assertEquals(listOf("ZED" to "tmdb:8002", "ÉMILA" to "tmdb:8000", "ÉMILE" to "tmdb:8001"), got.map { it.name to it.stableID })
    }

    @Test fun serverCollectionsFoldTheSame() {
        for (v in list("collectionFolds")) Franchises.checkFold(v, dictionary)
    }
}
