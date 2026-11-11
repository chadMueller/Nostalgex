package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The last playback failures Settings keeps (PlaybackDiagnostics), and the words they use (diagnosticSummary). */
class PlaybackDiagnosticsTest {
    @Test fun aLineSaysWhatHappenedToWhichTitle() {
        assertEquals("Nov 9 14:02 direct play → server stream after 15s: \"Heat\", no picture",
            PlaybackDiagnostics.line("Nov 9 14:02", "direct play → server stream after 15s", "Heat", "no picture"))
    }

    @Test fun onlyTheLastFiveAreKept() {
        var rows = emptyList<String>()
        for (i in 1..7) rows = PlaybackDiagnostics.push(rows, "line $i")
        assertEquals(listOf("line 7", "line 6", "line 5", "line 4", "line 3"), rows)
    }

    /** URLs, tokens and credentials never reach Settings, encoded or not. */
    @Test fun secretsAreRedacted() {
        val line = PlaybackDiagnostics.redact("failed at https://10-0-0-2.abc.plex.direct:32400/video?X-Plex-Token=SECRET1 with api_key=SECRET2 and Authorization: Bearer SECRET3")
        assertFalse(line, line.contains("SECRET"))
        assertTrue(line, line.contains("[redacted]"))
        val encoded = PlaybackDiagnostics.redact("url http%3A%2F%2Fhost%2Fa%3Fapi_key%3DSECRET4")
        assertFalse(encoded, encoded.contains("SECRET4"))
    }

    @Test fun theSummariesAreTheAppleTvs() {
        assertEquals("Plex HTTP 500, refused before video", PlaybackFailure.ServerRefused("Plex", 500).diagnosticSummary)
        assertEquals("device could not decode hevc", PlaybackFailure.DeviceCannotRender("hevc").diagnosticSummary)
        assertEquals("device could not decode the stream", PlaybackFailure.DeviceCannotRender(null).diagnosticSummary)
        assertEquals("channel stopped after 5 failures in a row; last: Jellyfin unreachable",
            PlaybackFailure.ChannelStopped(PlaybackFailure.ServerUnreachable("Jellyfin")).diagnosticSummary)
    }
}
