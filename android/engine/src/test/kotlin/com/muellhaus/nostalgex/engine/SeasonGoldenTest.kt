package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.time.LocalDate
import java.time.LocalDateTime

/** scripts/season-golden.json's Thanksgiving, in-season and label cases, as the Apple TV and web read them. */
class SeasonGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private fun read(path: String) = Json.parseToJsonElement(repoRoot.resolve(path).readText()).jsonObject
    private val golden = read("scripts/season-golden.json")
    private val bundles = ChannelConfig(read("channels.json")).bundles.associateBy { it.id }

    private fun bundle(c: JsonObject): ChannelConfig.Bundle =
        c["bundle"]?.jsonPrimitive?.content?.let { bundles.getValue(it) }
            ?: ChannelConfig.Bundle.fromJson(JsonObject(c["def"]!!.jsonObject + ("id" to kotlinx.serialization.json.JsonPrimitive("inline"))))

    @Test
    fun thanksgivingAndSeasonStarts() {
        for (c in golden["thanksgiving"]!!.jsonArray.map { it.jsonObject }) {
            val year = c["year"]!!.jsonPrimitive.int
            assertEquals(LocalDate.parse(c["thanksgiving"]!!.jsonPrimitive.content), Season.usThanksgiving(year))
            assertEquals(LocalDate.parse(c["tisTheSeasonStart"]!!.jsonPrimitive.content), Season.seasonStart(bundles.getValue("tis-the-season"), year))
        }
    }

    @Test
    fun everyInSeasonCase() {
        val cases = golden["inSeason"]!!.jsonArray.map { it.jsonObject }
        val failures = cases.filter { c ->
            Season.isInSeason(bundle(c), LocalDateTime.parse(c["at"]!!.jsonPrimitive.content)) != c["want"]!!.jsonPrimitive.boolean
        }.map { it["name"]!!.jsonPrimitive.content }
        assertEquals(emptyList<String>(), failures)
    }

    @Test
    fun everyLabelCase() {
        for (c in golden["label"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(c.toString(), c["want"]!!.jsonPrimitive.content.uppercase(), Season.spotlightLabel(bundle(c), LocalDateTime.parse(c["at"]!!.jsonPrimitive.content)))
        }
    }
}
