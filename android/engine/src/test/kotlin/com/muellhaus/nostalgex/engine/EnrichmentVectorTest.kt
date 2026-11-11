package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.math.BigDecimal
import java.math.MathContext

/**
 * The enrichment's pure steps against the web tuner's own (scripts/nostalgex-enrichment.js),
 * over the fixture documents the Roku port tests with (roku/tests/gen-enrichment.mjs):
 * TMDB and OMDb parsing, Supabase rows both ways, work items, OMDb gates and candidates, and
 * the quota clock. Records compare as canonical JSON, the generator's `canon`.
 */
class EnrichmentVectorTest {
    private val vectors = Json.parseToJsonElement(File(System.getProperty("nostalgex.enrichmentVectors")).readText()).jsonObject
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot"))
    private val nowMs = (vectors["nowSec"]!!.jsonPrimitive.doubleOrNull!! * 1000).toLong()
    private val E = EnrichmentService

    private fun list(k: String) = vectors[k]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun doc(o: JsonObject) = Json.parseToJsonElement(o.s("doc") ?: o.s("row") ?: o.s("items")!!)

    @Test fun theConstantsMatch() {
        val c = vectors["constants"]!!.jsonObject
        fun n(k: String) = c[k]!!.jsonPrimitive.doubleOrNull!!.toLong()
        assertEquals(n("supabaseChunk"), E.SUPABASE_CHUNK.toLong())
        assertEquals(n("relayConcurrency"), E.RELAY_CONCURRENCY.toLong())
        assertEquals(n("cacheTtlSec") * 1000, E.CACHE_TTL_MS)
        assertEquals(n("missTtlSec") * 1000, E.MISS_TTL_MS)
        assertEquals(n("omdbPerLoad"), E.OMDB_PER_LOAD.toLong())
        assertEquals(n("omdbConcurrency"), E.OMDB_CONCURRENCY.toLong())
        assertEquals(c.s("tmdbColumns"), E.TMDB_COLUMNS.joinToString(","))
        assertEquals(c.s("omdbColumns"), E.OMDB_COLUMNS.joinToString(","))
        assertEquals(vectors.s("fetchedAt"), EnrichmentService.isoTime(nowMs))
    }

    @Test fun tmdbDocumentsParseAsTheWebTunersDo() {
        for ((i, v) in list("tmdb").withIndex()) {
            val got = E.parseTMDBResponse(doc(v), v.s("tmdbID")!!, v.s("imdbID"), v.s("mediaType")!!, nowMs)
            assertEquals("TMDB case $i: ${v.s("doc")}", v.s("want"), canon(record(got)))
        }
    }

    @Test fun omdbAnswersParseAsTheWebTunersDo() {
        for ((i, v) in list("omdb").withIndex()) {
            val json = doc(v)
            val got = E.parseOMDbResponse(json)?.let {
                JsonObject(mapOf(
                    "imdbRating" to num(it.imdbRating), "imdbVotes" to num(it.imdbVotes), "rottenTomatoesScore" to num(it.rtScore),
                    "metacriticScore" to num(it.metacriticScore), "awards" to JsonPrimitive(it.awards),
                ))
            } ?: JsonNull
            assertEquals("OMDb case $i: ${v.s("doc")}", v.s("want"), canon(got))
            assertEquals("OMDb limit $i: ${v.s("doc")}", v["limit"]!!.jsonPrimitive.booleanOrNull, E.isOMDbLimit(json))
        }
    }

    @Test fun supabaseRowsRoundTrip() {
        for ((i, v) in list("rows").withIndex()) {
            val e = E.fromSupabaseRow(doc(v))
            assertEquals("row $i: ${v.s("row")}", v.s("want"), canon(e?.let(::record) ?: JsonNull))
            assertEquals("TMDB write $i", v.s("tmdbRow"), canon(e?.let(E::toSupabaseRow) ?: JsonNull))
            assertEquals("OMDb write $i", v.s("omdbRow"), canon(e?.let(E::toOMDbRow) ?: JsonNull))
        }
    }

    @Test fun workItemsAreOnePerTmdbId() {
        for ((i, v) in list("work").withIndex()) {
            val items = doc(v).jsonArray.mapNotNull { it as? JsonObject }
                .map { E.jsString(it["tmdbID"]) to ((it["type"] as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: "") }
            val got = JsonArray(E.workItems(items).map { JsonObject(mapOf("tmdbID" to JsonPrimitive(it.tmdbID), "mediaType" to JsonPrimitive(it.mediaType))) })
            assertEquals("work $i: ${v.s("items")}", v.s("want"), canon(got))
        }
    }

    @Test fun theShippedChannelsGiveTheSameGatesAndCandidates() {
        val channels = Json.parseToJsonElement(File(repoRoot, "channels.json").readText()).jsonObject["channels"]!!.jsonArray
        val gates = E.omdbGates(channels.map { (it as? JsonObject)?.get("rules") as? JsonObject })
        val gateJson = JsonArray(gates.map { g ->
            JsonObject(mapOf(
                "mediaType" to JsonPrimitive(g.mediaType),
                "keywords" to JsonArray(g.keywords.map(::JsonPrimitive)),
                "genres" to JsonArray(g.genres.map(::JsonPrimitive)),
            ))
        })
        assertEquals(vectors.s("gates"), canon(gateJson))
        for ((i, v) in list("candidates").withIndex()) {
            fun strs(k: String) = v[k]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals("candidate $i: $v", v["want"]!!.jsonPrimitive.booleanOrNull,
                E.isOMDbCandidate(v.s("mediaType"), strs("keywords"), strs("genres"), gates))
        }
    }

    @Test fun theOmdbQuotaResetsAtUtcMidnight() {
        for (v in list("midnights")) {
            val now = (v["nowSec"]!!.jsonPrimitive.doubleOrNull!! * 1000).toLong()
            assertEquals("from ${v["nowSec"]}", (v["want"]!!.jsonPrimitive.doubleOrNull!! * 1000).toLong(), E.nextUTCMidnight(now))
        }
    }

    @Test fun jsNumberReadsAsJavaScriptsNumberDoes() {
        assertEquals(0.0, E.jsNumber("  "), 0.0)
        assertEquals(16.0, E.jsNumber("0x10"), 0.0)
        assertEquals(10.0, E.jsNumber("1e1"), 0.0)
        assertEquals(Double.POSITIVE_INFINITY, E.jsNumber("Infinity"), 0.0)
        assertEquals(true, E.jsNumber("7.5x").isNaN())
        assertEquals(true, E.jsNumber("-0x10").isNaN())
    }

    companion object {
        private fun num(d: Double?): JsonElement = if (d == null) JsonNull else JsonPrimitive(d)

        /** An [Enrichment] in the web tuner's record shape (its key names, every key present). */
        fun record(e: Enrichment) = JsonObject(mapOf(
            "tmdbID" to JsonPrimitive(e.tmdbID), "imdbID" to JsonPrimitive(e.imdbID), "mediaType" to JsonPrimitive(e.mediaType),
            "keywords" to JsonArray(e.keywords.map(::JsonPrimitive)), "networks" to JsonArray(e.networks.map(::JsonPrimitive)),
            "productionCompanies" to JsonArray(e.productionCompanies.map(::JsonPrimitive)),
            "tmdbGenres" to JsonArray(e.tmdbGenres.map(::JsonPrimitive)),
            "imdbRating" to num(e.imdbRating), "imdbVotes" to num(e.imdbVotes), "rottenTomatoesScore" to num(e.rtScore),
            "metacriticScore" to num(e.metacriticScore), "awards" to JsonPrimitive(e.awards),
            "franchiseID" to num(e.franchiseID), "franchiseName" to JsonPrimitive(e.franchiseName), "fetchedAt" to JsonPrimitive(e.fetchedAt),
        ))

        /** gen-enrichment.mjs's canon: keys sorted, non-integers to 7 significant digits, non-ASCII escaped. */
        fun canon(v: JsonElement?): String = when (v) {
            null, JsonNull -> "null"
            is JsonArray -> v.joinToString(",", "[", "]") { canon(it) }
            is JsonObject -> v.keys.sorted().joinToString(",", "{", "}") { "${JsonPrimitive(it)}:${canon(v[it])}" }
            is JsonPrimitive -> when {
                v.isString -> buildString {
                    for (c in JsonPrimitive(v.content).toString()) if (c.code >= 0x7f) append("\\u%04x".format(c.code)) else append(c)
                }
                v.booleanOrNull != null -> v.content
                else -> {
                    val d = v.doubleOrNull!!
                    if (d == Math.floor(d) && Math.abs(d) < 1e21) d.toLong().toString()
                    else BigDecimal(d).round(MathContext(7)).toDouble().toString()
                }
            }
        }
    }
}
