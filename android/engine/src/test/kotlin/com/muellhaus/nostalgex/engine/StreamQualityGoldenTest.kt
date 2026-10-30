package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Locale

/**
 * scripts/stream-quality-golden.json, read by the Apple TV and the web too: same levels,
 * same order, same numbers. And the language and address rules beside it.
 */
class StreamQualityGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private val golden = Json.parseToJsonElement(repoRoot.resolve("scripts/stream-quality-golden.json").readText()).jsonObject

    @Test
    fun everyLevelMatchesTheAppleTv() {
        assertEquals(golden["storageKey"]!!.jsonPrimitive.content, StreamQuality.STORAGE_KEY)
        assertEquals(golden["default"]!!.jsonPrimitive.content, StreamQuality.fromId(null).id)
        val levels = golden["levels"]!!.jsonArray.map { it.jsonObject }
        assertEquals(levels.map { it["id"]!!.jsonPrimitive.content }, StreamQuality.entries.map { it.id })
        for ((level, q) in levels.zip(StreamQuality.entries)) {
            assertEquals(level["displayName"]!!.jsonPrimitive.content, q.displayName)
            assertEquals(level["maxBitrateKbps"]!!.jsonPrimitive.int, q.maxBitrateKbps)
            assertEquals(level["width"]!!.jsonPrimitive.int, q.width)
            assertEquals(level["height"]!!.jsonPrimitive.int, q.height)
            assertEquals(level["videoQualityIndex"]!!.jsonPrimitive.int, q.videoQualityIndex)
        }
    }

    @Test
    fun homeAddressesAreLocal() {
        assertTrue(StreamQuality.isLikelyLocalServer("https://192-168-1-50.abc123.plex.direct:32400"))
        assertTrue(StreamQuality.isLikelyLocalServer("http://10.0.0.5:32400"))
        assertTrue(StreamQuality.isLikelyLocalServer("http://172.20.1.1:32400"))
        assertFalse(StreamQuality.isLikelyLocalServer("https://81-2-3-4.abc123.plex.direct:32400"))
        assertFalse(StreamQuality.isLikelyLocalServer("http://172.32.1.1:32400"))
        assertFalse(StreamQuality.isLikelyLocalServer(null))
    }

    @Test
    fun languageRules() {
        assertEquals("de", LanguageChoice.resolved(LanguageChoice.SYSTEM, Locale.GERMANY))
        assertEquals("pt-BR", LanguageChoice.resolved("pt-BR", Locale.GERMANY))
        assertEquals(1, LanguageChoice.preferredTrackIndex(listOf("fr", "en-us", "en"), "en"))
        assertEquals(0, LanguageChoice.preferredTrackIndex(listOf("fr", "de"), "en"))
        assertTrue(LanguageChoice.shouldAutoEnableSubtitles(listOf("ja", "fr"), "en"))
        assertFalse(LanguageChoice.shouldAutoEnableSubtitles(listOf("ja", "en-gb"), "en"))
        assertFalse(LanguageChoice.shouldAutoEnableSubtitles(listOf("ja", "und"), "en"))
        assertFalse(LanguageChoice.shouldAutoEnableSubtitles(listOf("ja", null), "en"))
        assertFalse(LanguageChoice.shouldAutoEnableSubtitles(emptyList(), "en"))
        assertEquals(16, LanguageChoice.presets.size)
    }
}
