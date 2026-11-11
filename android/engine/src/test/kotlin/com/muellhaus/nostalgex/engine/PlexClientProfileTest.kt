package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Roku's PlexAudioTests.brs cases, plus the HEVC half. */
class PlexClientProfileTest {
    private val ac3 = "add-transcode-target-audio-codec(type=videoProfile&context=streaming&protocol=hls&audioCodec=ac3)"
    private val eac3 = "add-transcode-target-audio-codec(type=videoProfile&context=streaming&protocol=hls&audioCodec=eac3)"
    private val cap = "add-limitation(scope=videoAudioCodec&scopeName=eac3&type=upperBound&name=audio.channels&value=6)"
    private val hevc = "add-transcode-target-codec(type=videoProfile&context=streaming&protocol=hls&videoCodec=hevc)"

    @Test fun aStereoTvWithoutHevcOffersNothing() = assertEquals("", PlexClientProfile.extra(false, false, false, false))

    @Test fun ac3Only() = assertEquals(ac3, PlexClientProfile.extra(false, false, true, false))

    @Test fun bothWithEac3CappedAtSix() = assertEquals("$ac3+$eac3+$cap", PlexClientProfile.extra(false, false, true, true))

    @Test fun eac3Only() = assertEquals("$eac3+$cap", PlexClientProfile.extra(false, false, false, true))

    @Test fun theCapIsTheApplesScope() {
        // `audioCodec` is silently ignored; the Apple TV measured that only `videoAudioCodec` works.
        assertTrue(PlexClientProfile.EAC3_CHANNEL_CAP.contains("scope=videoAudioCodec"))
    }

    @Test fun hevcWithoutFourK() = assertEquals(hevc, PlexClientProfile.extra(true, false, false, false))

    @Test fun hevcFourKTenBitLiftsPlexsBaseLimits() {
        val x = PlexClientProfile.extra(true, true, true, true)
        assertTrue(x.startsWith(hevc))
        for (limit in listOf("video.width&value=3840", "video.height&value=2160", "video.bitDepth&value=10")) {
            assertTrue(limit, x.contains("scopeName=hevc&type=upperBound&name=$limit&replace=true"))
        }
        assertTrue(x.endsWith("$ac3+$eac3+$cap"))
    }

    @Test fun theFourKLimitsNeedHevc() = assertFalse(PlexClientProfile.extra(false, true, false, false).contains("hevc"))

    @Test fun neverALosslessTarget() {
        val x = PlexClientProfile.extra(true, true, true, true).lowercase()
        for (lossless in listOf("alac", "flac", "truehd", "dts", "pcm")) assertFalse(lossless, x.contains(lossless))
    }

    /** The codecs Media3 reported on a Google TV emulator with no Dolby Vision decoder. */
    @Test fun hevcIsWithheldForProfileFiveOnly() {
        assertTrue(PlexClientProfile.withholdHevcFor(listOf("dvhe.05.06")))
        assertTrue(PlexClientProfile.withholdHevcFor(listOf("dvh1.05.06")))
        assertFalse(PlexClientProfile.withholdHevcFor(listOf("dvhe.08.06")))
        assertFalse(PlexClientProfile.withholdHevcFor(listOf("hvc1.2.4.L153.B0")))
        assertFalse(PlexClientProfile.withholdHevcFor(listOf("dvhe.050.06")))
        assertFalse(PlexClientProfile.withholdHevcFor(emptyList()))
    }
}
