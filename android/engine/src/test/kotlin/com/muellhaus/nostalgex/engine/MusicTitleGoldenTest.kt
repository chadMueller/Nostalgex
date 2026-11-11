package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * scripts/music-title-golden.json (N-034), as scripts/nostalgex-music-title-smoke.mjs reads it:
 * "Song (Official Music Video)" is "Song", not "Song ( Music )".
 */
class MusicTitleGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private val golden = Json.parseToJsonElement(repoRoot.resolve("scripts/music-title-golden.json").readText()).jsonObject

    private fun str(e: Any?) = (e as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    @Test fun everyCleanCase() {
        val cases = golden["clean"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 37)
        val failures = cases.mapNotNull { c ->
            val got = MusicTitle.cleanTitle(str(c["in"]))
            if (got == str(c["out"])) null else "${c["in"]}: got \"$got\", want ${c["out"]}"
        }
        assertEquals("cases that differ from the web tuner", emptyList<String>(), failures)
    }

    @Test fun everyParseCase() {
        val cases = golden["parse"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 8)
        val failures = cases.mapNotNull { c ->
            val got = MusicTitle.parseTitle(str(c["in"]))
            if (got.artist == str(c["artist"]) && got.song == str(c["song"])) null
            else "${c["in"]}: got ${got.artist} / ${got.song}, want ${c["artist"]} / ${c["song"]}"
        }
        assertEquals("cases that differ from the web tuner", emptyList<String>(), failures)
    }

    /** Nothing in a cleaned title is left empty or half-open. */
    @Test fun noEmptyOrPaddedParentheses() {
        for (c in golden["clean"]!!.jsonArray.map { it.jsonObject }) {
            val out = MusicTitle.cleanTitle(str(c["in"]))
            assertTrue(out, !Regex("\\(\\s*\\)|\\(\\s|\\s\\)").containsMatchIn(out))
        }
    }
}
