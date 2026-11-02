package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The Android TV builds the franchise channels the Apple TV and the web tuner build.
 *
 * scripts/franchise-golden.json is upstream's golden file, which FranchiseGoldenTests.swift
 * and scripts/nostalgex-franchise-smoke.mjs both pass. This runs every check the smoke test
 * runs, in the same shape, through the Kotlin port.
 */
class FranchiseGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private val golden = Json.parseToJsonElement(repoRoot.resolve("scripts/franchise-golden.json").readText()).jsonObject
    private val dictionaryJson = Json.parseToJsonElement(repoRoot.resolve("franchises.json").readText())
    private val dictionary = FranchiseBuilder.parseDefinitions(dictionaryJson)
    private fun list(k: String) = golden[k]!!.jsonArray.map { it.jsonObject }

    @Test fun theDictionaryFileHoldsWhatTheSmokeTestExpects() {
        assertEquals(19, dictionary.size)
        assertEquals(19, dictionary.map { it.canonicalName }.toSet().size)
        assertEquals("2026-10-11", dictionaryJson.jsonObject["verified"]!!.jsonPrimitive.content)
        val ids = dictionary.flatMap { it.tmdbCollectionIDs }
        assertEquals("a collection id is claimed by two franchises", ids.size, ids.toSet().size)
        assertEquals(listOf("dict:FAST & FURIOUS", "dict:STAR TREK"), FranchiseBuilder.defaultOnIDs(dictionary).sorted())
    }

    @Test fun everyGoldenCaseGroupsTheSame() {
        val cases = list("cases")
        assertTrue(cases.isNotEmpty())
        val failures = ArrayList<String>()
        for (c in cases) {
            val defs = c["definitions"]?.let(FranchiseBuilder::parseDefinitions) ?: dictionary
            val got = FranchiseBuilder.build(
                movies = Franchises.items(c["movies"]),
                tvItems = Franchises.items(c["tvItems"]),
                definitions = defs,
                availableStockChannelIDs = Franchises.ints(c["availableStockChannelIDs"]),
                minimumFilms = (c["minimumFilms"] as? JsonPrimitive)?.int ?: FranchiseBuilder.DEFAULT_MINIMUM_FILMS,
            )
            val want = c["expected"]!!
            val have = Franchises.project(got)
            if (want != have) failures.add("case ${c["name"]}\n  want $want\n  have $have")
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test fun titleKeysMatch() {
        for (v in list("titleKeys")) {
            val title = v["title"]!!.jsonPrimitive.content
            assertEquals("titleKey $title", v["key"]!!.jsonPrimitive.content, FranchiseBuilder.explicitTitleKey(title))
        }
    }

    @Test fun filmTitlesMatchTheSameFranchise() {
        for (v in list("filmMatches")) {
            val title = v["title"]!!.jsonPrimitive.content
            val want = (v["franchise"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
            assertEquals("filmMatch $title", want, FranchiseBuilder.dictionaryMatchForFilmTitle(title, dictionary)?.canonicalName)
        }
    }

    @Test fun mergeKeysMatch() {
        for (v in list("mergeKeys")) {
            val name = v["name"]!!.jsonPrimitive.content
            assertEquals("mergeKey $name", v["key"]!!.jsonPrimitive.content, FranchiseBuilder.franchiseMergeKey(name))
        }
    }

    @Test fun serverCollectionsFoldIntoTheSameStockChannel() {
        for (v in list("collectionFolds")) Franchises.checkFold(v, dictionary)
    }
}

/** What the franchise tests share: the JS fixtures' items as MediaItems, and the smoke test's `project`. */
internal object Franchises {
    /** The JS `intOrNull` over a JSON list, as `build` reads availableStockChannelIDs. */
    fun ints(v: JsonElement?): List<Int> = (v as? JsonArray)?.mapNotNull { FranchiseBuilder.intOrNull(it)?.toInt() } ?: emptyList()

    /**
     * Fixture items, `{ id, title, enrichment: { franchiseID, franchiseName } }`. The id is
     * the ratingKey. A string franchiseID ("10") is read through the JS `intOrNull` first,
     * since Enrichment carries it as a number.
     */
    fun items(v: JsonElement?): List<MediaItem> = (v as? JsonArray)?.map { e ->
        val o = e.jsonObject
        val enrichment = (o["enrichment"] as? JsonObject)?.let { en ->
            Enrichment(
                franchiseID = FranchiseBuilder.intOrNull(en["franchiseID"])?.toDouble(),
                franchiseName = (en["franchiseName"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
            )
        }
        MediaItem(
            ratingKey = o["id"]!!.jsonPrimitive.content,
            title = (o["title"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: "",
            episodeTitle = (o["episodeTitle"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
            enrichment = enrichment,
        )
    } ?: emptyList()

    /** The comparable shape: items reduced to their ids. Mirrors the smoke test's `project`. */
    fun project(groupings: List<FranchiseGrouping>): JsonArray = JsonArray(groupings.map { g ->
        JsonObject(mapOf(
            "name" to JsonPrimitive(g.name),
            "stableID" to JsonPrimitive(g.stableID),
            "placement" to when (val p = g.placement) {
                is FranchisePlacement.Stock -> JsonObject(mapOf("type" to JsonPrimitive("stock"), "channelID" to JsonPrimitive(p.channelID)))
                FranchisePlacement.Dynamic -> JsonObject(mapOf("type" to JsonPrimitive("dynamic")))
            },
            "movies" to JsonArray(g.movies.map { JsonPrimitive(it.ratingKey) }),
            "tvItems" to JsonArray(g.tvItems.map { JsonPrimitive(it.ratingKey) }),
            "mergedFranchiseIDs" to JsonArray(g.mergedFranchiseIDs.map { JsonPrimitive(it) }),
            "fromDictionary" to JsonPrimitive(g.fromDictionary),
        ))
    })

    fun checkFold(v: JsonObject, dictionary: List<FranchiseDefinition>) {
        val got = FranchiseBuilder.stockChannelForCollectionItems(Franchises.items(v["items"]), dictionary, ints(v["availableStockChannelIDs"]))
        val want = (v["stockChannelID"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.int
        assertEquals("collectionFold ${v["about"] ?: v["items"]}", want, got)
    }
}
