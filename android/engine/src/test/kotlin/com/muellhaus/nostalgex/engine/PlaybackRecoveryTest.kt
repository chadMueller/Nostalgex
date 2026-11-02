package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The startup watchdog and the starvation monitor against the Apple TV's own cases
 * (PlaybackStarvationTests.swift and PlaybackDecisionTests.swift's watchdog section), which
 * replay a 4K HEVC transcode at 0.72x real time on a basement Apple TV, 2026-10-06.
 */
class PlaybackRecoveryTest {
    private fun feed(m: PlaybackStarvation, playheads: List<Double>, remaining: Double? = 3000.0): PlaybackStarvation.Starving? {
        for ((i, p) in playheads.withIndex()) m.observe(p, i.toDouble(), false, remaining)?.let { return it }
        return null
    }

    private fun playing(from: Double, seconds: Int) = (0 until seconds).map { from + it }
    private fun frozen(at: Double, seconds: Int) = List(seconds) { at }

    @Test fun aHealthyStreamNeverStarves() {
        val m = PlaybackStarvation()
        assertNull(feed(m, playing(0.0, 600)))
        assertTrue(m.armed)
    }

    @Test fun threeStallsInsideTheWindowIsStarving() {
        val trace = ArrayList<Double>()
        var head = 0.0
        repeat(3) {
            trace += playing(head, 25); head += 25
            trace += frozen(head, 10)
        }
        trace += playing(head, 5)
        val v = feed(PlaybackStarvation(), trace)
        assertNotNull(v)
        assertEquals(3, v!!.stalls)
        assertTrue(v.longestStallSeconds >= 9)
    }

    @Test fun oneLongFreezeIsStarvingOnItsOwn() {
        val v = feed(PlaybackStarvation(), playing(100.0, 30) + frozen(130.0, 25))
        assertEquals(1, v!!.stalls)
        assertTrue(v.longestStallSeconds >= PlaybackStarvation.HARD_STALL_SECONDS)
    }

    @Test fun startupIsNotAStall() {
        val m = PlaybackStarvation()
        assertNull(feed(m, frozen(0.0, 60)))
        assertFalse(m.armed)
    }

    @Test fun briefHlsSegmentPausesAreNotStalls() {
        val trace = ArrayList<Double>()
        var head = 0.0
        repeat(40) {
            trace += playing(head, 8); head += 8
            trace += frozen(head, 2)
        }
        assertNull(feed(PlaybackStarvation(), trace))
    }

    @Test fun stallsSpreadWiderThanTheWindowDoNotAddUp() {
        val trace = ArrayList<Double>()
        var head = 0.0
        repeat(3) {
            trace += playing(head, 90); head += 90
            trace += frozen(head, 5)
        }
        trace += playing(head, 5)
        assertNull(feed(PlaybackStarvation(), trace))
    }

    @Test fun pausedSamplesAreIgnored() {
        val m = PlaybackStarvation()
        for (i in 0 until 10) m.observe(i.toDouble(), i.toDouble(), false, 3000.0)
        for (i in 10 until 60) assertNull(m.observe(10.0, i.toDouble(), true, 3000.0))
    }

    @Test fun theTailOfAnItemBelongsToTheEndFallback() {
        val m = PlaybackStarvation()
        for (i in 0 until 10) m.observe(i.toDouble(), i.toDouble(), false, 3000.0)
        for (i in 10 until 60) assertNull(m.observe(10.0, i.toDouble(), false, 2.0))
    }

    @Test fun twoStallsThenRecoveryStaysQuiet() {
        val trace = playing(0.0, 20) + frozen(20.0, 5) + playing(20.0, 20) + frozen(40.0, 5) + playing(40.0, 200)
        assertNull(feed(PlaybackStarvation(), trace))
    }

    // ── Android's stall length, from the emulator harness (2026-11-02) ──────

    /**
     * A playhead that runs at real time but stops for `freeze` seconds every `every` seconds,
     * sampled once a second starting `phase` into the second, as the app samples it.
     */
    private fun sampled(freeze: Double, every: Double, phase: Double, seconds: Int): List<Pair<Double, Double>> {
        fun playhead(t: Double): Double {
            val cycles = Math.floor(t / every)
            val into = t - cycles * every
            return cycles * (every - freeze) + minOf(into, every - freeze)
        }
        return (0 until seconds).map { val t = phase + it; t to playhead(t) }
    }

    private fun starves(stallSeconds: Double, samples: List<Pair<Double, Double>>): Boolean {
        val m = PlaybackStarvation(stallSeconds)
        return samples.any { (wall, head) -> m.observe(head, wall, false, 3000.0) != null }
    }

    /** Direct play at 0.67x real time: ExoPlayer stopped for 2.6 to 2.9 s every 8 to 9 s. */
    @Test fun exoPlayersStarvingFreezesAreCaughtAtTwoSecondsButNotThree() {
        for (k in 0 until 10) {
            val trace = sampled(freeze = 2.6, every = 8.5, phase = k / 10.0, seconds = 120)
            assertTrue("phase ${k / 10.0}", starves(2.0, trace))
        }
        // The Apple TV's 3 s misses most of them: AVPlayer froze for good where ExoPlayer stops and starts.
        assertTrue((0 until 10).count { starves(3.0, sampled(2.6, 8.5, it / 10.0, 120)) } < 10)
    }

    /** Healthy direct play on the emulator: 31 rebuffers in 200 s, the longest 511 ms. */
    @Test fun healthyRebuffersNeverCount() {
        for (k in 0 until 10) assertNull("phase ${k / 10.0}", PlaybackStarvation(2.0).let { m ->
            sampled(freeze = 0.6, every = 6.0, phase = k / 10.0, seconds = 600).firstNotNullOfOrNull { (w, h) -> m.observe(h, w, false, 3000.0) }
        })
    }

    // ── Watchdog ─────────────────────────────────────────────────────────

    @Test fun deadlinesScaleWithTheWork() {
        assertEquals(15, PlaybackWatchdog.deadlineSeconds(true, 3840, 2160))
        assertEquals(20, PlaybackWatchdog.deadlineSeconds(false, 1920, 1080))
        assertEquals(40, PlaybackWatchdog.deadlineSeconds(false, 3840, 2160))
        assertEquals("scope films are wide, not tall", 40, PlaybackWatchdog.deadlineSeconds(false, 3840, 1606))
        assertEquals(20, PlaybackWatchdog.deadlineSeconds(false, null, null))
    }

    @Test fun skipIsDecidedByThePlayheadNotBufferFlags() {
        assertTrue(PlaybackWatchdog.shouldSkip(false, 0.0))
        assertTrue("ready but nothing decoding", PlaybackWatchdog.shouldSkip(true, 0.0))
        assertTrue(PlaybackWatchdog.shouldSkip(true, Double.NaN))
        assertFalse(PlaybackWatchdog.shouldSkip(true, 1.9))
        assertFalse("buffering for most of the window but decoding is alive", PlaybackWatchdog.shouldSkip(true, 0.3))
        assertTrue(PlaybackWatchdog.shouldSkip(true, 0.1))
    }

    @Test fun hlsBaseOffsetFollowsWhereTheClockStarts() {
        assertEquals("clock rebased to zero: add the offset back", 2000.0, PlaybackWatchdog.hlsBaseOffset(2000, 0.4), 0.0)
        assertEquals("copyts kept source time: nothing to add", 0.0, PlaybackWatchdog.hlsBaseOffset(2000, 2000.3), 0.0)
        assertEquals(0.0, PlaybackWatchdog.hlsBaseOffset(0, 0.0), 0.0)
        assertEquals(0.0, PlaybackWatchdog.hlsBaseOffset(2000, Double.NaN), 0.0)
    }

    @Test fun soundOverBlackIsNotPicture() {
        assertFalse(PlaybackWatchdog.hasPicture(true, 1.9, false))
        assertTrue(PlaybackWatchdog.hasPicture(true, 1.9, true))
        assertFalse(PlaybackWatchdog.hasPicture(true, 0.0, true))
    }
}
