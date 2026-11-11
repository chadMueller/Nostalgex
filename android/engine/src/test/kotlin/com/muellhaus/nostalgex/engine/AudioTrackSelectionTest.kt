package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The cases of the Apple TV's AudioTrackSelectionTests.swift: a retro TV guide has no audio
 * picker, so a Jellyfin or Emby transcode has to carry the right track by itself.
 */
class AudioTrackSelectionTest {
    private fun audio(index: Int, lang: String?, isDefault: Boolean = false, channels: Int = 0) =
        AudioStream(index, lang ?: "", "aac", channels, lang ?: "Audio", isDefault)

    /** The exact Joe Dirt layout. */
    @Test fun englishBeatsADefaultFlaggedSpanishTrack() {
        val streams = listOf(audio(1, "spa", isDefault = true, channels = 2), audio(2, "eng", channels = 6))
        assertEquals(2, LanguageChoice.preferredAudioIndex(streams, listOf("en-US")))
    }

    @Test fun moreChannelsWinsAmongTracksInTheViewersLanguage() {
        val streams = listOf(audio(1, "eng", isDefault = true, channels = 2), audio(2, "eng", channels = 6))
        assertEquals("a 5.1 English mix beats a stereo English default", 2, LanguageChoice.preferredAudioIndex(streams, listOf("en")))
    }

    /** "en-GB" must match a track tagged "eng"; three-letter and two-letter codes both occur. */
    @Test fun localeIdentifiersMatchThreeLetterTags() {
        val streams = listOf(audio(1, "fre", isDefault = true), audio(2, "eng"))
        assertEquals(2, LanguageChoice.preferredAudioIndex(streams, listOf("en-GB")))
        assertEquals("a French viewer keeps the French track", 1, LanguageChoice.preferredAudioIndex(streams, listOf("fr-CA")))
    }

    @Test fun fallsBackToTheFilesDefaultWhenNoTrackIsInTheViewersLanguage() {
        val streams = listOf(audio(1, "jpn"), audio(2, "kor", isDefault = true))
        assertEquals(2, LanguageChoice.preferredAudioIndex(streams, listOf("de")))
    }

    /** The Roku's rule (NxMbChosenAudioIndex, issue #62): AUDIO LANGUAGE before English, more channels or not. */
    @Test fun aGermanViewerGetsGermanStereoOverAnEnglishFiveOne() {
        val streams = listOf(audio(1, "eng", isDefault = true, channels = 6), audio(2, "ger", channels = 2))
        assertEquals(2, LanguageChoice.preferredAudioIndex(streams, listOf("de")))
    }

    /** Measured on the emulator: the viewer's language beats English when they tie. */
    @Test fun theViewersLanguageBeatsEnglishOnATie() {
        val konTiki = listOf(audio(1, "eng", isDefault = true, channels = 1), audio(2, "nor", channels = 1))
        assertEquals(2, LanguageChoice.preferredAudioIndex(konTiki, listOf("nb")))
        // No Norwegian track: English is the fallback, ahead of the file's default.
        val steps = listOf(audio(1, "fra", isDefault = true, channels = 1), audio(2, "eng", channels = 1))
        assertEquals(2, LanguageChoice.preferredAudioIndex(steps, listOf("nb")))
    }

    /** One track is not a choice: the server's URL stays untouched. */
    @Test fun aSingleAudioTrackIsLeftToTheServer() {
        assertNull(LanguageChoice.preferredAudioIndex(listOf(audio(1, "eng")), listOf("en")))
        assertNull(LanguageChoice.preferredAudioIndex(null, listOf("en")))
    }

    // ── LanguageCodeMatchingTests.swift: codes compared through the ISO 639-2 table, never by first letters ──

    private fun pick(streams: List<AudioStream>, viewer: String) = LanguageChoice.preferredAudioIndex(streams, listOf(viewer))

    @Test fun estonianIsNotSpanish() {
        val streams = listOf(audio(1, "est", channels = 6), audio(2, "spa", channels = 2))
        assertEquals(2, pick(streams, "es-MX"))
        assertEquals("an Estonian viewer still gets Estonian", 1, pick(streams, "et"))
    }

    @Test fun armenianIsNotArabic() {
        val streams = listOf(audio(1, "arm", channels = 6), audio(2, "ara", channels = 2))
        assertEquals(2, pick(streams, "ar"))
        assertEquals(1, pick(streams, "hy"))
    }

    @Test fun javaneseIsNotJapanese() {
        val streams = listOf(audio(1, "jav", channels = 6), audio(2, "jpn", channels = 2))
        assertEquals(2, pick(streams, "ja-JP"))
        assertEquals(1, pick(streams, "jv"))
    }

    @Test fun czechMatchesInBothForms() {
        for (code in listOf("cze", "ces")) {
            val streams = listOf(audio(1, "hun", isDefault = true, channels = 2), audio(2, code, channels = 2))
            assertEquals(code, 2, pick(streams, "cs-CZ"))
        }
    }

    @Test fun slovakIsNotSlovenian() {
        val streams = listOf(audio(1, "slo", channels = 6), audio(2, "slv", channels = 2))
        assertEquals(2, pick(streams, "sl"))
        assertEquals(1, pick(streams, "sk"))
    }

    @Test fun romanianIsNotRussianAndSwedishIsNotSwahili() {
        val ro = listOf(audio(1, "rum", channels = 6), audio(2, "rus", channels = 2))
        assertEquals(2, pick(ro, "ru"))
        assertEquals(1, pick(ro, "ro"))
        val sv = listOf(audio(1, "swe", channels = 6), audio(2, "swa", channels = 2))
        assertEquals(2, pick(sv, "sw"))
        assertEquals(1, pick(sv, "sv"))
    }
}
