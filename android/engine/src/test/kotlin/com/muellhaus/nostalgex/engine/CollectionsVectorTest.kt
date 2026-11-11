package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.EnrichmentVectorTest.Companion.canon
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Server collections against the web tuner's own (scripts/nostalgex-collections.js), over the
 * fixtures the Roku port tests with (roku/tests/gen-collections.mjs): name cleaning, stock
 * matching, manifest overlap, the member index, candidates, folds into stock franchise
 * channels, numbering, and the Plex and Jellyfin/Emby calls. Values compare as canonical JSON.
 */
class CollectionsVectorTest {
    private val vectors = Json.parseToJsonElement(File(System.getProperty("nostalgex.collectionsVectors")).readText()).jsonObject
    private val json = Json { ignoreUnknownKeys = true }
    private val C = Collections

    private fun list(k: String) = vectors[k]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.int(k: String) = (this[k] as? JsonPrimitive)?.doubleOrNull?.toInt()
    private fun str(v: String?): JsonElement = if (v == null) JsonNull else JsonPrimitive(v)

    private fun channel(o: JsonObject, pool: List<MediaItem> = emptyList()) =
        Collections.StockChannel(o.int("id")!!, o.int("number"), o.s("name") ?: "", pool)

    private fun channels(v: JsonElement?) = (v as? JsonArray)?.map { channel(it.jsonObject) } ?: emptyList()

    private fun items(v: JsonElement?): List<MediaItem> =
        (v as? JsonArray)?.map { json.decodeFromJsonElement<MediaItem>(it) } ?: emptyList()

    private fun overlapJson(o: Collections.ContentOverlap?): JsonElement = o?.let {
        JsonObject(mapOf(
            "channelID" to JsonPrimitive(it.channelID), "channelName" to JsonPrimitive(it.channelName),
            "overlapCount" to JsonPrimitive(it.overlapCount), "totalCount" to JsonPrimitive(it.totalCount),
            "percent" to JsonPrimitive(it.percent),
        ))
    } ?: JsonNull

    private fun collectionsJson(out: List<ServerCollection>) = JsonArray(out.map {
        JsonObject(mapOf(
            "id" to JsonPrimitive(it.id), "title" to str(it.title),
            "childKeys" to JsonArray(it.childKeys.map(::JsonPrimitive)), "serverKey" to JsonPrimitive(it.serverKey),
        ))
    })

    @Test fun theConstantsMatch() {
        val c = vectors["constants"]!!.jsonObject
        assertEquals(c.int("ID_BASE"), C.ID_BASE)
        assertEquals(c.int("NUMBER_BASE"), C.NUMBER_BASE)
        assertEquals(c.int("NUMBER_END"), C.NUMBER_END)
        assertEquals(c.int("CAPACITY"), C.CAPACITY)
    }

    @Test fun titlesCleanAsTheWebTunersDo() {
        for (v in list("text")) {
            val title = v.s("title")!!
            val clean = C.cleanTitle(title)
            assertEquals("clean '$title'", v.s("clean"), clean)
            assertEquals("decade '$title'", v.s("decade"), C.decadeNormalized(clean))
        }
    }

    @Test fun stockMatchesAsTheWebTunersDo() {
        val lineup = channels(vectors["lineup"])
        val smoke = channels(vectors["smokeStock"])
        for (v in list("match")) {
            val stock = when (v.s("stock")) {
                "lineup" -> lineup
                "smoke" -> smoke
                else -> listOf(Collections.StockChannel(7, null, ""))
            }
            assertEquals("${v.s("stock")} '${v.s("title")}'", v.s("label"), C.matchStaticChannel(v.s("title"), stock))
        }
    }

    @Test fun manifestOverlapAsTheWebTunersDo() {
        for (v in list("overlap")) {
            val byID = channels(v["channels"]).associateBy { it.id }
            val manifest = v["manifest"] as? JsonObject
            val threshold = v.int("threshold") ?: Collections.OVERLAP_THRESHOLD
            val got = C.contentOverlap(items(v["items"]), manifest, byID, threshold)
            assertEquals(v.s("name"), canon(v["overlap"]), canon(overlapJson(got)))
        }
    }

    @Test fun candidatesFoldsAndChannelsAsTheWebTunersDo() {
        for (v in list("candidates")) {
            val name = v.s("name")!!
            val all = items(v["items"])
            val keyOf = { it: MediaItem -> "${it.serverID}|${it.ratingKey}" }
            val byKey = all.associateBy(keyOf)
            val index = C.indexLibrary(all) { it.serverID ?: "undefined" }
            val raw = v["raw"]!!.jsonArray.map {
                val o = it.jsonObject
                ServerCollection(o.s("id")!!, o.s("title"), o["childKeys"]!!.jsonArray.map { k -> k.jsonPrimitive.content }, o.s("serverKey")!!)
            }
            val franchise = v["franchiseChannels"]!!.jsonArray.map {
                val o = it.jsonObject
                val pool = o["pool"]!!.jsonArray.map { r ->
                    val ro = r.jsonObject
                    byKey["${ro.s("serverID")}|${ro.s("ratingKey")}"]!!
                }
                channel(o, pool)
            }
            val ctx = Collections.Context(
                staticChannels = channels(v["staticChannels"]),
                channelsByID = (v["channels"] as? JsonArray)?.let { channels(it).associateBy { c -> c.id } },
                franchiseChannels = franchise,
                itemKey = keyOf,
                enabledKeys = v["enabledKeys"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet(),
                manifest = v["manifest"] as? JsonObject,
            )
            val list = C.buildCandidates(raw, index, ctx)
            val got = JsonArray(list.map { c ->
                JsonObject(mapOf(
                    "id" to JsonPrimitive(c.id), "title" to JsonPrimitive(c.title),
                    "movieCount" to JsonPrimitive(c.movieCount), "showCount" to JsonPrimitive(c.showCount),
                    "episodeCount" to JsonPrimitive(c.episodeCount), "items" to JsonArray(c.items.map { JsonPrimitive(keyOf(it)) }),
                    "enabled" to JsonPrimitive(c.enabled), "matchedChannel" to str(c.matchedChannel),
                    "contentOverlap" to overlapJson(c.contentOverlap), "foldedInto" to str(c.foldedInto),
                    "warning" to str(C.duplicateWarning(c)), "summary" to JsonPrimitive(C.memberSummary(c)),
                ))
            })
            val want = v["candidates"]!!.jsonArray
            assertEquals("$name: count", want.size, got.size)
            for (i in want.indices) assertEquals("$name: candidate $i", canon(want[i]), canon(got[i]))

            val m = C.materialize(list)
            val wantM = v["materialized"]!!.jsonObject
            assertEquals("$name: overCap", wantM.int("overCap"), m.overCap)
            val gotChannels = m.channels.map { ch ->
                JsonObject(mapOf(
                    "id" to JsonPrimitive(ch.id), "number" to JsonPrimitive(ch.number), "name" to JsonPrimitive(ch.name),
                    "colorHex" to JsonPrimitive(ch.colorHex), "minItems" to JsonPrimitive(ch.minItems),
                    "enabled" to JsonPrimitive(ch.enabled), "collectionID" to str(ch.collectionID),
                    "pool" to JsonArray(ch.itemPool.map { JsonPrimitive(keyOf(it)) }),
                ))
            }
            val wantChannels = wantM["channels"]!!.jsonArray
            assertEquals("$name: channel count", wantChannels.size, gotChannels.size)
            for (i in wantChannels.indices) assertEquals("$name: channel $i", canon(wantChannels[i]), canon(gotChannels[i]))
        }
    }

    /** A fetch over the vector's documents: a path it lacks throws, as the JS stub does. */
    private class Stub(private val docs: JsonObject) {
        // Collection members are read four at a time (Collections.mapLimit), so from several threads.
        val calls: MutableList<String> = java.util.Collections.synchronizedList(ArrayList())
        fun get(path: String): JsonElement {
            calls.add(path)
            return docs[path] ?: throw IllegalStateException("404")
        }
    }

    @Test fun plexCallsAsTheWebTunersDo() {
        for (v in list("plex")) {
            val stub = Stub(v["docs"]!!.jsonObject)
            val out: JsonElement = try {
                collectionsJson(C.fetchPlexCollections("mid", stub::get))
            } catch (e: Exception) {
                JsonPrimitive("throws")
            }
            // The JS reads four collections' members at once, so the calls compare sorted, as a set
            // with its counts; the results keep the list's order and compare as they are.
            assertEquals("${v.s("name")}: calls", v["calls"]!!.jsonArray.map { it.jsonPrimitive.content }.sorted(), stub.calls.sorted())
            assertEquals("${v.s("name")}: out", canon(v["out"]), canon(out))
        }
    }

    @Test fun boxSetCallsAsTheWebTunersDo() {
        for (v in list("boxSets")) {
            val stub = Stub(v["docs"]!!.jsonObject)
            val out: JsonElement = try {
                collectionsJson(C.fetchBoxSetCollections("srv", "u 1/2", stub::get))
            } catch (e: Exception) {
                JsonPrimitive("throws")
            }
            // The JS reads four BoxSets at once, so the calls compare sorted, as a set.
            assertEquals("${v.s("name")}: calls", canon(v["calls"]), canon(JsonArray(stub.calls.sorted().map(::JsonPrimitive))))
            assertEquals("${v.s("name")}: out", canon(v["out"]), canon(out))
        }
    }
}
