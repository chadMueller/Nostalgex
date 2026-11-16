package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.RatingNudgePolicy.Launch
import com.muellhaus.nostalgex.engine.RatingNudgePolicy.Persisted
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Apple TV's RatingNudgePolicy rules: three sessions of ten minutes, never on a first launch, a failure, or twice on a version. */
class RatingNudgePolicyTest {
    private val ready = Persisted(qualifyingSessions = 3)
    private val launch = Launch(appVersion = "1.0.0")

    @Test fun aSessionNeedsTenMinutes() {
        assertFalse(RatingNudgePolicy.countsAsViewingSession(599.9)); assertTrue(RatingNudgePolicy.countsAsViewingSession(600.0))
    }

    @Test fun threeSessionsShowIt() {
        assertTrue(RatingNudgePolicy.shouldShow(ready, launch))
        assertFalse(RatingNudgePolicy.shouldShow(Persisted(qualifyingSessions = 2), launch))
        assertEquals(3, RatingNudgePolicy.REQUIRED_SESSIONS)
    }

    @Test fun neverOnAFirstLaunchAfterRatingOrAfterAFailure() {
        assertFalse(RatingNudgePolicy.shouldShow(ready, launch.copy(isFirstLaunch = true)))
        assertFalse(RatingNudgePolicy.shouldShow(ready.copy(rated = true), launch))
        assertFalse(RatingNudgePolicy.shouldShow(ready, launch.copy(hadPlaybackFailure = true)))
        assertFalse(RatingNudgePolicy.shouldShow(ready, launch.copy(hadConnectError = true)))
    }

    @Test fun onceAVersionAndOnceALaunch() {
        assertFalse(RatingNudgePolicy.shouldShow(ready.copy(lastShownVersion = "1.0.0"), launch))
        assertTrue(RatingNudgePolicy.shouldShow(ready.copy(lastShownVersion = "0.9"), launch))
        assertFalse(RatingNudgePolicy.shouldShow(ready, launch.copy(shownThisLaunch = true)))
    }

    @Test fun forcedSkipsTheGatesButNotTheOncePerLaunch() {
        assertTrue(RatingNudgePolicy.shouldShow(Persisted(), launch.copy(forced = true, isFirstLaunch = true)))
        assertFalse(RatingNudgePolicy.shouldShow(Persisted(), launch.copy(forced = true, shownThisLaunch = true)))
    }
}
