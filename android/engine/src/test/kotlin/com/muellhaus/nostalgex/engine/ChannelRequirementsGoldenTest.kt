package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * scripts/channel-requirements-golden.json (#292): the plain-words lines for every channel in
 * channels.json, as ChannelRules.plainLanguageRequirements writes them on the Apple TV and
 * scripts/nostalgex-channel-requirements.js on the web.
 */
class ChannelRequirementsGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private fun read(path: String) = Json.parseToJsonElement(repoRoot.resolve(path).readText()).jsonObject

    @Test fun everyChannelReadsAsTheOtherAppsWriteIt() {
        val golden = read("scripts/channel-requirements-golden.json")["channels"]!!.jsonObject
        val config = ChannelConfig(read("channels.json"))
        assertEquals("a line for every channel", config.channels.size, golden.size)
        assertTrue(golden.size >= 142)
        val differ = config.channels.mapNotNull { ch ->
            val want = golden[ch.id.toString()]?.jsonArray?.map { it.jsonPrimitive.content }
            val got = ChannelRequirements.plainLanguage(ch.rules)
            if (want == got) null else "CH ${ch.id} ${ch.name}:\n  want $want\n  got  $got"
        }
        assertEquals("channels whose lines differ from the other apps'", "", differ.joinToString("\n"))
    }

    /** The Apple TV calls them bundles; no line says "package". */
    @Test fun noLineSaysPackage() {
        val config = ChannelConfig(read("channels.json"))
        val said = config.channels.flatMap { ch -> ChannelRequirements.plainLanguage(ch.rules).filter { "package" in it.lowercase() }.map { "CH ${ch.id}: $it" } }
        assertEquals(emptyList<String>(), said)
    }
}
