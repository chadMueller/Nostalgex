package com.muellhaus.nostalgex.engine

/**
 * The Now Playing panel's UP NEXT badge (#271, the Apple TV 1.0.32's UpNextLabel): minutes only,
 * never hours, whole minutes rounded down so it never promises sooner than it is, and under a
 * minute "LESS THAN 1 MIN".
 */
object UpNextLabel {
    /** How often the line re-reads the schedule; the rest of the panel doesn't tick. */
    const val REFRESH_MS = 15_000L

    fun text(secondsUntil: Double): String {
        val minutes = Math.floor(maxOf(0.0, secondsUntil) / 60.0).toLong()
        return if (minutes < 1) "UP NEXT IN LESS THAN 1 MIN" else "UP NEXT IN $minutes MIN"
    }
}
