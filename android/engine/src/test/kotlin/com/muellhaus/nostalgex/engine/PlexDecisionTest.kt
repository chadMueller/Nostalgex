package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Decisions saved from a Plex 1.43.5 lab server for Android's server-stream request
 * (src/test/resources/plex-decision, library ids and identifiers taken out).
 */
class PlexDecisionTest {
    private fun saved(name: String) = javaClass.getResource("/plex-decision/$name")!!.readText()

    @Test fun profileFiveIsRefusedForDolbyVision() {
        val a = PlexDecision.parse(saved("dovi-profile-5.xml"))
        assertEquals("2003", a?.transcodeCode)
        assertEquals("File is unplayable. DoVi (Profile 5) color space is not supported.", a?.transcodeText)
        assertTrue(PlexDecision.isDolbyVisionRefusal(a))
    }

    /** Profile 8.1 has an HDR10 base layer, so Plex converts it. */
    @Test fun profileEightIsConverted() {
        val a = PlexDecision.parse(saved("dovi-profile-81.xml"))
        assertEquals("1001", a?.transcodeCode)
        assertFalse(PlexDecision.isDolbyVisionRefusal(a))
    }

    @Test fun anOrdinaryConversionIsNotARefusal() = assertFalse(PlexDecision.isDolbyVisionRefusal(PlexDecision.parse(saved("dts-51.xml"))))

    /** A 2003 for another reason is a failure like any other, not a skip. */
    @Test fun anotherRefusalIsNotDolbyVision() =
        assertFalse(PlexDecision.isDolbyVisionRefusal(PlexDecision.Answer("2003", "File is unplayable. Something else.")))

    @Test fun noBodyNoAnswer() {
        assertNull(PlexDecision.parse(null))
        assertNull(PlexDecision.parse("<html><body>400 Bad Request</body></html>"))
        assertFalse(PlexDecision.isDolbyVisionRefusal(null))
    }

    /**
     * #291, from answers to Android's request with the #192 profile, saved from an unclaimed lab
     * Plex 1.43.5: High-profile H.264 is copied (a remux), Constrained Baseline H.264 re-encoded.
     */
    @Test fun aCopiedVideoIsARemux() {
        val a = PlexDecision.parse(saved("remux-h264-dts-51.xml"))
        assertEquals("copy", a?.videoDecision)
        assertEquals(true, a?.videoCopied)
    }

    @Test fun aReEncodedVideoIsATranscode() {
        assertEquals(false, PlexDecision.parse(saved("transcode-h264-dts-51.xml"))?.videoCopied)
        assertEquals(false, PlexDecision.parse(saved("dts-51.xml"))?.videoCopied)
    }

    /** No video stream in the answer (a refusal): nobody said, so the row stays "Server stream". */
    @Test fun aRefusalSaysNothingAboutTheVideo() = assertNull(PlexDecision.parse(saved("dovi-profile-5.xml"))?.videoCopied)

    /** The audio stream's decision is not the video's. */
    @Test fun onlyTheVideoStreamCounts() {
        val body = """<MediaContainer transcodeDecisionCode="1001"><Video><Media><Part>""" +
            """<Stream streamType="2" codec="eac3" decision="copy" /><Stream streamType="1" codec="h264" decision="transcode" />""" +
            """</Part></Media></Video></MediaContainer>"""
        assertEquals(false, PlexDecision.parse(body)?.videoCopied)
    }
}
