package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Language matching held to scripts/nostalgex-language.js and its smoke
 * (scripts/nostalgex-language-match-smoke.mjs): the same ISO 639-2 table, character for
 * character, the same exact compare, and Norwegian as one language.
 */
class LanguageMatchTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")

    @Test
    fun theTableIsTheWebTunersAndTheRokusCharacterForCharacter() {
        val js = repoRoot.resolve("scripts/nostalgex-language.js").readText()
        val web = Regex("const ISO639_PAIRS = '([^']+)'").find(js)!!.groupValues[1]
        assertEquals(web, LanguageChoice.ISO639_PAIRS)
    }

    @Test
    fun threeLetterCodesReduceExactly() {
        assertEquals("de", LanguageChoice.primaryLanguage("ger"))
        assertEquals("de", LanguageChoice.primaryLanguage("deu"))
        assertEquals("en", LanguageChoice.primaryLanguage("en-US"))
        assertTrue(LanguageChoice.sameLanguage("ces", "cs-CZ"))
        // The first-letter compare's mistakes (N-014).
        assertFalse("Estonian is not Spanish", LanguageChoice.sameLanguage("est", "es"))
        assertFalse("Armenian is not Arabic", LanguageChoice.sameLanguage("arm", "ar"))
        assertFalse("Javanese is not Japanese", LanguageChoice.sameLanguage("jav", "ja"))
        assertFalse("Slovak is not Slovenian", LanguageChoice.sameLanguage("slo", "sl"))
        // A code the table lacks still matches itself; "no language" matches nothing.
        assertTrue(LanguageChoice.sameLanguage("yue", "yue"))
        assertFalse(LanguageChoice.sameLanguage("und", "und"))
        assertFalse(LanguageChoice.sameLanguage("mul", "en"))
    }

    @Test
    fun norwegianIsOneLanguageInEverySpelling() {
        assertTrue(LanguageChoice.sameLanguage("nor", "nb-NO"))
        assertTrue(LanguageChoice.sameLanguage("nno", "nob"))
        assertTrue(LanguageChoice.matches("nb", "no"))
        assertTrue(LanguageChoice.matches("nn", "nb"))
        assertTrue(LanguageChoice.matches("nb-no", "no"))
        assertEquals(1, LanguageChoice.preferredTrackIndex(listOf("en", "nb", "sv"), "no"))
        // Norwegian audio with a Norwegian setting is not foreign: no automatic subtitles.
        assertFalse(LanguageChoice.shouldAutoEnableSubtitles(listOf("nn"), "nb"))
    }

    @Test
    fun theTrackRuleIsUnchangedOtherwise() {
        assertTrue(LanguageChoice.matches("en-us", "en"))
        assertFalse(LanguageChoice.matches("en", "en-us"))
        assertFalse(LanguageChoice.matches("sv", "no"))
        assertTrue(LanguageChoice.shouldAutoEnableSubtitles(listOf("fr"), "en"))
        assertFalse(LanguageChoice.shouldAutoEnableSubtitles(listOf("fr", "und"), "en"))
    }
}
