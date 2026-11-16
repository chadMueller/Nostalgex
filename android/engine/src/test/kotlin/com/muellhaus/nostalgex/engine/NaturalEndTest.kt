package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** #315: the Apple TV's natural-end rule (a file plays to its end; the next one catches up to the clock at 10 s or more). */
class NaturalEndTest {
    private fun item(k: String) = MediaItem(ratingKey = k, title = k)

    @Test fun theGuideHasMovedOnSoThePlayerJoinsAtTheClock() {
        val b = item("b")
        assertEquals(Pick(b, 51), NaturalEnd.pick("a", Pick(b, 0), Pick(b, 51)))
    }

    /** Less than the catch-up behind the guide: the next programme starts at 0, whole. */
    @Test fun underTheCatchUpTheNextStartsAtZero() {
        val next = Pick(item("b"), 0)
        assertSame(next, NaturalEnd.pick("a", next, Pick(item("b"), NaturalEnd.CATCH_UP_SECONDS - 1L)))
    }

    @Test fun atTheCatchUpThePlayerJoinsAtTheClock() {
        val b = item("b")
        assertEquals(Pick(b, 10), NaturalEnd.pick("a", Pick(b, 0), Pick(b, 10)))
    }

    /** The file ended inside its slot: the guide still shows it, and the next one starts at 0. */
    @Test fun endedInsideTheSlotStartsTheNextAtZero() {
        val next = Pick(item("b"), 0)
        assertSame(next, NaturalEnd.pick("a", next, Pick(item("a"), 115)))
    }

    /** The conflict rule picked another programme: it is left as the engine chose it. */
    @Test fun aDifferentPickIsLeftAlone() {
        val next = Pick(item("c"), 0)
        assertSame(next, NaturalEnd.pick("a", next, Pick(item("b"), 40)))
    }

    @Test fun nothingToHoldTo() {
        val next = Pick(item("b"), 0)
        assertSame(next, NaturalEnd.pick("a", next, null))
        assertEquals(null, NaturalEnd.pick("a", null, Pick(item("b"), 10)))
    }

    /**
     * A channel of 170 s files in 120 s slots, run across 20 natural ends. The guide's programme
     * at time t is slot floor(t / 120). Before, the player started each at 0 and fell up to a slot
     * behind (the SHIELD measured 15 to 102 s). Held to the clock, it is never behind at all.
     */
    @Test fun aModelChannelNeverDrifts() {
        val slot = 120L
        val file = 170L
        fun guideAt(t: Long) = Pick(item("p${t / slot}"), t % slot)

        fun run(hold: Boolean): List<Long> {
            var t = 0L
            var playing = guideAt(0)
            val behind = ArrayList<Long>()
            repeat(20) {
                t += file - playing.seekSeconds // the file plays out from where it started
                val now = guideAt(t)
                val moved = now.item.ratingKey != playing.item.ratingKey
                val engine = if (moved) Pick(now.item, 0) else Pick(item("p${t / slot + 1}"), 0)
                playing = if (hold) NaturalEnd.pick(playing.item.ratingKey, engine, now)!! else engine
                // How far the player is behind the guide's own position in that programme.
                behind += if (playing.item == now.item) now.seekSeconds - playing.seekSeconds else 0
            }
            return behind
        }

        val before = run(hold = false)
        assertTrue("the model drifts without the fix: $before", before.max() >= 50)
        val held = run(hold = true)
        assertTrue("never the catch-up behind: $held", held.all { it < NaturalEnd.CATCH_UP_SECONDS })
    }
}
