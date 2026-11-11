package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * scripts/audio-pick-golden.json (#286), as scripts/nostalgex-audio-pick-smoke.mjs replays it:
 * the commentary titles, the Jellyfin and Emby track to pin, and the Plex stream to play.
 */
class AudioPickGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private val golden = Json.parseToJsonElement(repoRoot.resolve("scripts/audio-pick-golden.json").readText()).jsonObject

    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonObject.flag(k: String) = (this[k] as? JsonPrimitive)?.let { it.booleanOrNull ?: (it.intOrNull == 1) } ?: false

    @Test fun commentaryTitles() {
        val t = golden["commentaryTitles"]!!.jsonObject
        for (yes in t["yes"]!!.jsonArray.map { it.jsonPrimitive.content }) assertTrue(yes, AudioPick.isCommentary(yes))
        for (no in t["no"]!!.jsonArray.map { it.jsonPrimitive.content }) assertFalse(no, AudioPick.isCommentary(no))
    }

    /**
     * Android passes one language list: the viewer's AUDIO LANGUAGE when chosen, else the TV's
     * own (LanguageChoice.resolved), which is the case's `audioLanguage` or else its
     * `preferredLanguages`.
     */
    @Test fun everyJellyfinAndEmbyCase() {
        val failures = golden["jellyfinAndEmby"]!!.jsonArray.map { it.jsonObject }.mapNotNull { c ->
            val streams = c["streams"]!!.jsonArray.map { it.jsonObject }.map { s ->
                AudioStream(index = s["index"]!!.jsonPrimitive.intOrNull!!, lang = s.s("lang") ?: "", channels = (s["channels"] as? JsonPrimitive)?.intOrNull ?: 0,
                    isDefault = s.flag("isDefault"), title = s.s("displayTitle") ?: "", rawTitle = s.s("title") ?: "")
            }
            val languages = c.s("audioLanguage")?.let { listOf(it) } ?: c["preferredLanguages"]!!.jsonArray.map { it.jsonPrimitive.content }
            val got = LanguageChoice.preferredAudioIndex(streams, languages)
            val want = (c["expect"] as? JsonPrimitive)?.intOrNull
            if (got == want) null else "${c.s("name")}: got $got, want $want"
        }
        assertEquals("cases that differ from the web tuner", emptyList<String>(), failures)
    }

    @Test fun everyPlexCase() {
        val failures = golden["plex"]!!.jsonArray.map { it.jsonObject }.mapNotNull { c ->
            val streams = c["streams"]!!.jsonArray.map { it.jsonObject }.map { s ->
                AudioPick.PlexAudio(s["id"]!!.jsonPrimitive.longOrNull!!, s.flag("selected"), s.s("title"), s.s("displayTitle"))
            }
            val got = AudioPick.plexAudioStream(streams)?.id
            val want = (c["expect"] as? JsonPrimitive)?.longOrNull
            if (got == want) null else "${c.s("name")}: got $got, want $want"
        }
        assertEquals("cases that differ from the web tuner", emptyList<String>(), failures)
    }
}
