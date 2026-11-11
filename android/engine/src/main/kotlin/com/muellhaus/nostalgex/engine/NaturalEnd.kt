package com.muellhaus.nostalgex.engine

/**
 * What plays when a file ends by itself (#293, the Apple TV 1.0.32's natural-end fix). The guide
 * gives each programme whole minutes; a real file runs 0 to 59 s past its slot, so by its end the
 * guide is already into the next programme. Starting that one at 0 s left the player behind the
 * guide (measured on a SHIELD: 15 to 102 s behind across five boundaries of 2-minute slots), and
 * Now Playing named one programme while the guide showed the next.
 */
object NaturalEnd {
    /**
     * `next` is the engine's pick at a natural end (`advancePick(..., fromNaturalEnd = true)`,
     * always at 0 s), `guideNow` the programme the guide has on now and how far into it, as a
     * tune-in would play it. When the guide has moved on to the programme `next` names, join it
     * where the clock says. Otherwise (the file ended inside its slot, so `next` is the one up
     * next, or the conflict rule picked another) start `next` as it is.
     */
    fun pick(endedRatingKey: String?, next: Pick?, guideNow: Pick?): Pick? {
        if (next == null || guideNow == null) return next
        val moved = guideNow.item.ratingKey != endedRatingKey
        return if (moved && guideNow.item.ratingKey == next.item.ratingKey) Pick(next.item, guideNow.seekSeconds) else next
    }
}
