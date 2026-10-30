package com.muellhaus.nostalgex.engine

import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.temporal.TemporalAdjusters

/**
 * Seasonal packages: scripts/nostalgex-season.js (ChannelBundle.isInSeason and spotlightLabel
 * on the Apple TV), held to scripts/season-golden.json by SeasonGoldenTest. Times are local
 * wall-clock times, as the golden file gives them.
 */
object Season {
    private const val US_THANKSGIVING = "usThanksgiving"
    private val MONTHS = listOf("JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC")

    fun isSeasonal(bundle: ChannelConfig.Bundle) = bundle.activeMonths != null

    /** The fourth Thursday of November. */
    fun usThanksgiving(year: Int): LocalDate =
        LocalDate.of(year, 11, 1).with(TemporalAdjusters.dayOfWeekInMonth(4, DayOfWeek.THURSDAY))

    /** The day an early-starting season begins in `year`, or null (none, or an unknown anchor). */
    fun seasonStart(bundle: ChannelConfig.Bundle, year: Int): LocalDate? {
        if (!isSeasonal(bundle)) return null
        val (anchor, days) = bundle.seasonStart ?: return null
        if (anchor != US_THANKSGIVING) return null
        return usThanksgiving(year).plusDays(days.toLong())
    }

    /** A package without activeMonths always is. September counts from the 15th. */
    fun isInSeason(bundle: ChannelConfig.Bundle, now: LocalDateTime): Boolean {
        val months = bundle.activeMonths ?: return true
        val month = now.monthValue
        if (month in months) return month != 9 || now.dayOfMonth >= 15
        // A season that starts early runs from its start to the end of that month.
        val start = seasonStart(bundle, now.year) ?: return false
        return !now.isBefore(start.atStartOfDay()) && now.monthValue == start.monthValue
    }

    /**
     * Settings' note for a seasonal package: "SPOTLIGHTED OCT", or "SPOTLIGHTED NOV 19 TO DEC 31"
     * for one that starts early. Empty for a package without activeMonths.
     */
    fun spotlightLabel(bundle: ChannelConfig.Bundle, now: LocalDateTime): String {
        val months = bundle.activeMonths?.takeIf { it.isNotEmpty() } ?: return ""
        val start = seasonStart(bundle, now.year)
        val last = months.last()
        if (start != null && last in 1..12) {
            val endYear = if (last < start.monthValue) start.year + 1 else start.year
            val lastDay = LocalDate.of(endYear, last, 1).lengthOfMonth()
            return "SPOTLIGHTED ${MONTHS[start.monthValue - 1]} ${start.dayOfMonth} TO ${MONTHS[last - 1]} $lastDay"
        }
        val names = months.filter { it in 1..12 }.map { MONTHS[it - 1] }
        return if (names.isEmpty()) "" else "SPOTLIGHTED ${names.joinToString(", ")}"
    }
}
