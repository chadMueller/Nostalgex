package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.PlaybackFailure.Evidence
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** PlaybackFailure.classify's order and wording, as PlaybackFailureTests.swift reads the Apple TV's. */
class PlaybackFailureTest {
    private fun classify(e: Evidence) = PlaybackFailure.classify("Plex", e)

    @Test
    fun theServersAnswerOutranksTheDevice() {
        assertEquals(PlaybackFailure.ServerTooSlow("Plex"), classify(Evidence(starvedAfterCappedRetry = true, httpStatuses = listOf(500))))
        assertEquals(PlaybackFailure.NotAuthorised("Plex"), classify(Evidence(httpStatuses = listOf(404, 401))))
        assertEquals(PlaybackFailure.FileMissing("Plex"), classify(Evidence(httpStatuses = listOf(404), decoderFailed = true)))
        assertEquals(PlaybackFailure.ServerRefused("Plex", 500), classify(Evidence(httpStatuses = listOf(200, 500))))
        assertEquals(PlaybackFailure.ServerUnreachable("Plex"), classify(Evidence(unreachable = true, decoderFailed = true)))
        assertEquals(PlaybackFailure.ServerTooSlow("Plex"), classify(Evidence(deliveryTooSlow = true, decoderFailed = true)))
    }

    @Test
    fun aDecodedFrameVetoesTheDevice() {
        assertEquals(PlaybackFailure.DeviceCannotRender("hevc"), classify(Evidence(decoderFailed = true, sourceCodec = "hevc")))
        assertEquals(PlaybackFailure.Unknown("Plex"), classify(Evidence(decoderFailed = true, decodedAFrame = true)))
        assertEquals(PlaybackFailure.ServerTooSlow("Plex"), classify(Evidence(serverDeliveredBytes = true)))
        assertEquals(PlaybackFailure.Unknown("Plex"), classify(Evidence()))
    }

    @Test
    fun wordingAndColour() {
        assertEquals("Your server wouldn't start this one", PlaybackFailure.ServerRefused("Plex", 500).headline)
        assertTrue(PlaybackFailure.ServerRefused("Plex", 500).detail.startsWith("Plex answered HTTP 500 before it started sending video."))
        assertEquals("This HEVC file arrived, but this TV couldn't turn it into a picture. The server sent it in a format this device can't decode.",
            PlaybackFailure.DeviceCannotRender("hevc").detail)
        val stopped = PlaybackFailure.ChannelStopped(PlaybackFailure.FileMissing("Plex"))
        assertEquals("5 programmes in a row wouldn't play, so this channel has stopped trying. Last reason: Your server can't find this file.", stopped.detail)
        assertEquals("Try another channel, or select this one again to retry.", stopped.nextStep)
        assertTrue(stopped.isServerSide)
        assertFalse(PlaybackFailure.DeviceCannotRender(null).isServerSide)
    }

    @Test
    fun theRunStopsAtFiveOnOneChannel() {
        val run = ChannelFailureRun()
        repeat(4) { assertFalse(run.recordFailure(7)) }
        assertFalse(run.recordFailure(8))
        repeat(3) { run.recordFailure(8) }
        assertTrue(run.recordFailure(8))
        run.reset()
        assertFalse(run.isStopped)
    }
}
