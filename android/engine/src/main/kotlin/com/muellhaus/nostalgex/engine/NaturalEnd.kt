package com.muellhaus.nostalgex.engine

/**
 * What plays when a file ends by itself (#315, the Apple TV's natural-end rule). The guide gives each programme its
 * real runtime ([MediaItem.slotSeconds]), so a file and its slot end together and the next programme starts at 0,
 * at the moment the clock says it should. What is left over is the time the next file takes to load, a second or two
 * a programme, which adds up. Once the guide is [CATCH_UP_SECONDS] or more into the programme this starts, the player
 * joins it where the clock is instead (its opening seconds go, never the end of anything), so the headline cannot
 * lag the guide by more than that and a little. This replaces #293's fix, which joined where the clock was
 * whenever the guide had moved on.
 */
object NaturalEnd {
    /** How far behind the guide the player may fall at a natural end before the next programme joins where the clock is. */
    const val CATCH_UP_SECONDS = 10

    /**
     * `next` is the engine's pick at a natural end (`advancePick(..., fromNaturalEnd = true)`, always at 0 s),
     * `guideNow` the programme the guide has on now and how far into it, as a tune-in would play it. When the
     * guide has moved on to the programme `next` names and is [CATCH_UP_SECONDS] or more into it, join it where the
     * clock says. Otherwise start `next` as it is.
     */
    fun pick(endedRatingKey: String?, next: Pick?, guideNow: Pick?): Pick? {
        if (next == null || guideNow == null) return next
        val moved = guideNow.item.ratingKey != endedRatingKey
        return if (moved && guideNow.item.ratingKey == next.item.ratingKey && guideNow.seekSeconds >= CATCH_UP_SECONDS) {
            Pick(next.item, guideNow.seekSeconds)
        } else next
    }
}
