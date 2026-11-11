package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Test

/** #284's three values, as the Apple TV's PINRequestRetryTests and the Roku's cases. */
class PlexPinWaitTest {
    @Test fun aNormalCodeWaitsFifteenMinutes() = assertEquals(900L, PlexPinWait.seconds(900))
    @Test fun aLongLifetimeIsCappedAtHalfAnHour() = assertEquals(1800L, PlexPinWait.seconds(5000))
    @Test fun noLifetimeFallsBackToFiveMinutes() {
        assertEquals(300L, PlexPinWait.seconds(null))
        assertEquals(300L, PlexPinWait.seconds(0))
        assertEquals(300L, PlexPinWait.seconds(-1))
    }
}
