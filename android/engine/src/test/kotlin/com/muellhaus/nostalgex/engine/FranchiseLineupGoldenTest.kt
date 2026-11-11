package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The franchise lineups of scripts/franchise-lineup-golden.json, whose answers the Apple TV's
 * FranchiseLineupGoldenTests wrote: the same library, franchise choices and server collections
 * give the same found franchises, classic pools, Settings rows, folds, channels, numbers and
 * guide. Built as scripts/nostalgex-franchise-lineup-smoke.mjs builds them for the web tuner.
 */
class FranchiseLineupGoldenTest {
    private val root = File(System.getProperty("nostalgex.repoRoot"))
    private val golden = Json.parseToJsonElement(File(root, "scripts/franchise-lineup-golden.json").readText()).jsonObject
    private val definitions = FranchiseBuilder.parseDefinitions(File(root, "franchises.json").readText())
    private val config = ChannelConfig(Json.parseToJsonElement(File(root, "channels.json").readText()).jsonObject)
    private val bundleChannelIDs = config.bundles.first { it.id == "franchises" }.channelIDs

    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonElement?.strings() = (this as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList()

    /** The library item the page holds for a golden item (the smoke's toItem). */
    private fun toItem(g: JsonObject): MediaItem {
        val episode = g.s("type") == "episode"
        val e = g["enrichment"] as? JsonObject
        return MediaItem(
            ratingKey = g.s("id")!!,
            title = g.s("title") ?: "",
            type = g.s("type") ?: "movie",
            duration = if (episode) 45 else 120,
            genres = g["genres"].strings(),
            librarySource = if (episode) "tv" else "movie",
            tmdbID = ((g["tmdbID"] as? JsonPrimitive)?.content ?: g.s("id"))?.toLongOrNull(),
            episodeTitle = if (episode) g.s("episodeTitle") ?: "Pilot" else null,
            showKey = if (episode) g.s("showKey") else null,
            serverID = "srv",
            enrichment = e?.let {
                Enrichment(
                    franchiseID = (it["franchiseID"] as? JsonPrimitive)?.let { p -> p.doubleOrNull ?: p.content.toDoubleOrNull() },
                    franchiseName = it.s("franchiseName"),
                )
            },
        )
    }

    private class Run(val got: Map<String, JsonElement>, val candidates: Map<String, Collections.Candidate>)

    private fun run(s: JsonObject): Run {
        val items = s["items"]!!.jsonArray.map { toItem(it.jsonObject) }
        val byId = items.associateBy { it.ratingKey }
        val defs = config.channels.associateBy { it.id }
        val stock = s["stock"]!!.jsonObject.map { (id, pool) ->
            val def = defs.getValue(id.toInt())
            FranchiseLineup.Stock(def.id, def.number, def.name, pool.strings().map { byId.getValue(it) })
        }
        val manifest = s["manifest"] as? JsonObject
        val rules = (s["exclusiveRules"] as? JsonArray)?.map { ChannelFilter.ExclusiveRule.fromJson(it.jsonObject) } ?: emptyList()
        val packageOn = (s["packageOn"] as JsonPrimitive).booleanOrNull == true
        val raw = s["collections"]!!.jsonArray.map { it.jsonObject }.map { c -> ServerCollection(c.s("id")!!, c.s("title"), c["members"].strings(), "srv") }
        val staticChannels = stock.map { Collections.StockChannel(it.id, it.number, it.name, it.itemPool) }
        val result = FranchiseLineup.build(
            definitions, packageOn, s["enabledFranchiseIDs"].strings().toSet(), s["disabledFranchiseIDs"].strings().toSet(),
            items, stock, bundleChannelIDs, manifest, rules,
            FranchiseLineup.CollectionInput(raw, Collections.indexLibrary(items) { "srv" }, staticChannels, s["enabledCollectionIDs"].strings().toSet()),
        )

        fun ids(list: List<MediaItem>) = JsonArray(list.map { JsonPrimitive(it.ratingKey) })
        fun num(n: Int?) = n?.let { JsonPrimitive(it) } ?: JsonNull
        fun str(v: String?) = v?.let { JsonPrimitive(it) } ?: JsonNull
        val byCollection = result.candidates.associateBy { it.id }
        val unioned = stock.associate { c -> c.id.toString() to ids(c.itemPool + (result.stockAdditions[c.id] ?: emptyList())) }
        val overCap = LinkedHashMap<String, JsonElement>()
        if (result.overCapFound > 0) overCap["foundFranchises"] = JsonPrimitive(result.overCapFound)
        if (result.overCapFranchises > 0) overCap["collectionFranchises"] = JsonPrimitive(result.overCapFranchises)
        if (result.overCapCustom > 0) overCap["otherCollections"] = JsonPrimitive(result.overCapCustom)
        fun kind(id: Int) = when {
            id >= 1_020_000 -> "otherCollection"
            id >= 1_010_000 -> "franchiseCollection"
            else -> "found"
        }
        // The guide, as the page filters it: the classics and the runtime channels, CH 300-499.
        val guide = (stock.filter { FranchiseLineup.stockVisible(it.id, packageOn, bundleChannelIDs, result.switchedOffStock) }.map { it.number } +
            result.channels.filter { FranchiseLineup.runtimeVisible(it, packageOn) }.map { it.number })
            .filter { it in 300..499 }.sorted()

        val got = mapOf(
            "found" to JsonArray(result.found.map { f ->
                JsonObject(mapOf(
                    "id" to JsonPrimitive(f.id), "name" to JsonPrimitive(f.name), "covered" to num(f.coveredByChannelID),
                    "fromDictionary" to JsonPrimitive(f.fromDictionary), "enabled" to JsonPrimitive(f.enabled),
                    "movies" to ids(f.movies), "tvItems" to ids(f.tvItems),
                ))
            }),
            "stockPools" to JsonObject(unioned),
            "switchedOffStock" to JsonArray(result.switchedOffStock.sorted().map { JsonPrimitive(it) }),
            "rows" to JsonArray(result.rows.map { r ->
                JsonObject(mapOf(
                    "id" to JsonPrimitive(r.id), "name" to JsonPrimitive(r.name), "countLabel" to JsonPrimitive(r.countLabel),
                    "stockChannelID" to num(r.stockChannelID), "channelNumber" to num(r.channelNumber), "enabled" to JsonPrimitive(r.enabled),
                ))
            }),
            "collections" to JsonArray(raw.map { c ->
                val cand = byCollection.getValue(c.id)
                JsonObject(mapOf(
                    "id" to JsonPrimitive(c.id), "title" to JsonPrimitive(cand.title),
                    "category" to str(cand.category?.wire), "foldedInto" to str(cand.foldedInto),
                ))
            }),
            "channels" to JsonArray(result.channels.map { ch ->
                JsonObject(mapOf(
                    "number" to JsonPrimitive(ch.number), "id" to JsonPrimitive(ch.id), "name" to JsonPrimitive(ch.name),
                    "kind" to JsonPrimitive(kind(ch.id)), "items" to ids(ch.itemPool),
                ))
            }),
            "overCap" to JsonObject(overCap),
            "guide" to JsonArray(guide.map { JsonPrimitive(it) }),
        )
        return Run(got, byCollection)
    }

    /** Values as JSON compares them: whole numbers as integers, objects by key. */
    private fun norm(e: JsonElement?): JsonElement = when (e) {
        null, JsonNull -> JsonNull
        is JsonObject -> JsonObject(e.mapValues { norm(it.value) }.toSortedMap())
        is JsonArray -> JsonArray(e.map { norm(it) })
        is JsonPrimitive -> if (!e.isString && e.booleanOrNull == null && e.doubleOrNull != null) {
            val d = e.doubleOrNull!!
            if (d == Math.floor(d)) JsonPrimitive(d.toLong()) else e
        } else e
    }

    @Test fun everyLineupMatchesTheAppleTv() {
        val lineups = golden["lineups"]!!.jsonArray.map { it.jsonObject }
        assertTrue(lineups.size >= 9)
        val failures = ArrayList<String>()
        for (s in lineups) {
            val name = s.s("name")!!
            val expected = s["expected"]!!.jsonObject
            val got = run(s).got
            for (key in listOf("found", "stockPools", "switchedOffStock", "rows", "collections", "channels", "overCap", "guide")) {
                val want = norm(expected[key])
                val have = norm(got[key])
                if (want != have) failures += "$name: $key\n  want $want\n  got  $have"
            }
        }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    /** The Swift test is given each collection's name match and manifest overlap; this engine works them out and must agree. */
    @Test fun theCollectionSignalsMatchTheAppleTvsInputs() {
        val failures = ArrayList<String>()
        for (s in golden["lineups"]!!.jsonArray.map { it.jsonObject }) {
            val candidates = run(s).candidates
            for (c in s["collections"]!!.jsonArray.map { it.jsonObject }) {
                val cand = candidates.getValue(c.s("id")!!)
                if (cand.matchedChannel != c.s("matchedChannel")) failures += "${s.s("name")}: name match of ${c.s("id")}: ${cand.matchedChannel} vs ${c.s("matchedChannel")}"
                val want = (c["contentOverlap"] as? JsonObject)?.let { o ->
                    listOf("channelID", "overlapCount", "totalCount").map { (o[it] as JsonPrimitive).intOrNull }
                }
                val have = cand.contentOverlap?.let { listOf(it.channelID, it.overlapCount, it.totalCount) }
                if (want != have) failures += "${s.s("name")}: overlap of ${c.s("id")}: $have vs $want"
            }
        }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    @Test fun theClassicsAreCh300To306AndNothingNumberedReaches310To499() {
        assertEquals(listOf(300, 301, 302, 303, 304, 305, 306), bundleChannelIDs.map { id -> config.channels.first { it.id == id }.number })
        assertEquals(emptyList<Int>(), config.channels.map { it.number }.filter { it in 310..499 })
    }
}
