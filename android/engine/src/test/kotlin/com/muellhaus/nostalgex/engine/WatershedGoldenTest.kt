package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * scripts/watershed-golden.json: which titles stay in a channel's pool at an hour with Watershed
 * on or off, and whether the channel is a Watershed hold, as WatershedGoldenTests.swift and
 * scripts/nostalgex-watershed-smoke.mjs read it.
 */
class WatershedGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private fun read(path: String) = Json.parseToJsonElement(repoRoot.resolve(path).readText()).jsonObject
    private val golden = read("scripts/watershed-golden.json")
    private val config = ChannelConfig(read("channels.json"))

    /** A plain channel, or one shaped like VHS VAULT with its own permanent hold until 9 PM. */
    private fun channel(ownBlockRatings: Boolean) = ChannelConfig.StockChannel(
        id = 7, number = 7, name = if (ownBlockRatings) "VHS VAULT" else "TEST CHANNEL", colorHex = null,
        category = "nostalgex", minItems = 0, rules = null, isPremiereChannel = false,
        timeRestrictions = if (ownBlockRatings) Json.parseToJsonElement("""{"blockRatings":{"ratings":["R","NC-17"],"blockBefore":21}}""").jsonObject else null,
    )

    @Test
    fun everyCase() {
        val cases = golden["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 13)
        val failures = ArrayList<String>()
        for (c in cases) {
            val on = c["watershedEnabled"]!!.jsonPrimitive.boolean
            val hour = c["hour"]!!.jsonPrimitive.int
            val ch = channel(c["hasOwnBlockRatings"]!!.jsonPrimitive.boolean)
            val pool = c["pool"]!!.jsonArray.map { it.jsonObject }.map { p: JsonObject ->
                MediaItem(
                    ratingKey = p["ratingKey"]!!.jsonPrimitive.content,
                    type = p["type"]!!.jsonPrimitive.content,
                    contentRating = p["contentRating"]?.jsonPrimitive?.content,
                )
            }
            val gotPool = config.timeFilteredPool(ch, pool, hour, on).map { it.ratingKey }
            val wantPool = c["expectPool"]!!.jsonArray.map { it.jsonPrimitive.content }
            val gotHold = config.isWatershedHold(ch, pool, hour, on)
            val wantHold = c["expectHold"]!!.jsonPrimitive.boolean
            if (gotPool != wantPool || gotHold != wantHold) {
                failures += "${c["name"]!!.jsonPrimitive.content}: pool $gotPool (want $wantPool), hold $gotHold (want $wantHold)"
            }
        }
        assertEquals("cases that differ from the Apple TV", emptyList<String>(), failures)
    }
}
