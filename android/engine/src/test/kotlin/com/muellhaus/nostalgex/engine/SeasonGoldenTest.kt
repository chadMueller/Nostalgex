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

/** scripts/season-golden.json, every section but the guide's lead order, as the Apple TV and web read them. */
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

    private val shipped = ChannelConfig(read("channels.json")).bundles
    private fun at(c: JsonObject) = LocalDateTime.parse(c["at"]!!.jsonPrimitive.content)
    private fun want(c: JsonObject, key: String) = (c[key] as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content

    @Test
    fun everyOfferCase() {
        for (c in golden["offer"]!!.jsonArray.map { it.jsonObject }) {
            val on = c["on"]?.jsonArray?.map { it.jsonPrimitive.content }?.toSet() ?: emptySet()
            assertEquals(c["name"]!!.jsonPrimitive.content, want(c, "want"), Season.bundleToOffer(shipped, on, at(c)) { false }?.id)
        }
    }

    /** Each case's steps against one store: an answer, then what the invite offers, or whether a package is silenced. */
    @Test
    fun everyAnswerCase() {
        for (case in golden["answers"]!!.jsonArray.map { it.jsonObject }) {
            val name = case["name"]!!.jsonPrimitive.content
            val store = HashSet<String>()
            val on = HashSet<String>()
            for (step in case["steps"]!!.jsonArray.map { it.jsonObject }) {
                val now = at(step)
                val silenced = { id: String -> Season.isSilenced(id, now) { it in store } }
                when {
                    "answer" in step -> {
                        val answer = when (step["answer"]!!.jsonPrimitive.content) {
                            "yes" -> Season.Answer.YES
                            "notNow" -> Season.Answer.NOT_NOW
                            else -> Season.Answer.NEVER
                        }
                        val id = step["bundle"]!!.jsonPrimitive.content
                        if (Season.record(answer, id, now) { store += it }) on += id
                    }
                    "silenced" in step -> assertEquals("$name: ${step["at"]}", step["want"]!!.jsonPrimitive.boolean, silenced(step["silenced"]!!.jsonPrimitive.content))
                    else -> assertEquals("$name: ${step["at"]}", want(step, "offer"), Season.bundleToOffer(shipped, on, now, silenced)?.id)
                }
            }
        }
    }

    @Test
    fun everyHeadlineCase() {
        for (c in golden["headline"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(c.toString(), c["want"]!!.jsonPrimitive.content, Season.headline(bundle(c), at(c)))
        }
    }
}
