package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Test

/** #271's wording for the UP NEXT badge. */
class UpNextLabelTest {
    @Test fun minutesOnlyNeverHours() {
        assertEquals("UP NEXT IN 84 MIN", UpNextLabel.text(84 * 60.0))
        assertEquals("UP NEXT IN 120 MIN", UpNextLabel.text(120 * 60.0))
    }

    @Test fun roundedDownSoItNeverPromisesSooner() {
        assertEquals("UP NEXT IN 84 MIN", UpNextLabel.text(84 * 60.0 + 59))
        assertEquals("UP NEXT IN 1 MIN", UpNextLabel.text(119.0))
    }

    @Test fun underAMinute() {
        assertEquals("UP NEXT IN LESS THAN 1 MIN", UpNextLabel.text(59.9))
        assertEquals("UP NEXT IN LESS THAN 1 MIN", UpNextLabel.text(0.0))
        assertEquals("UP NEXT IN LESS THAN 1 MIN", UpNextLabel.text(-5.0))
    }
}
