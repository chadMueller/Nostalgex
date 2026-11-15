package com.muellhaus.nostalgex.engine

/**
 * GUIDE TEXT SIZE (Settings > PLAYBACK & PICTURE): three steps, SMALLER, DEFAULT and LARGER, for a couch nearer or
 * further from the screen. The Apple TV's `GuideTextSize.swift` (appletv/guide-text-three-steps). The step also sets
 * the bundle list and the Now Playing panel, so the whole guide screen moves together.
 *
 * Saved under [STORAGE_KEY] as "small", "normal" or "large". The middle step is labelled DEFAULT but keeps the raw
 * value "normal", and "large" is the raw value the old LARGE always had, so a saved choice and the other platforms
 * (which only know "normal" and "large") keep working. Nothing saved, or anything unknown, is DEFAULT. Case order is
 * the order the Settings row cycles in.
 */
enum class GuideTextSize(val raw: String, val label: String, val metrics: GuideTextMetrics) {
    SMALL("small", "SMALLER", GuideTextMetrics.SMALL),
    NORMAL("normal", "DEFAULT", GuideTextMetrics.NORMAL),
    LARGE("large", "LARGER", GuideTextMetrics.LARGE);

    /** SMALLER > DEFAULT > LARGER > SMALLER, what select does on the Settings row. */
    val next: GuideTextSize get() = entries[(ordinal + 1) % entries.size]

    companion object {
        const val STORAGE_KEY = "nostalgex_guide_text_size"

        fun fromStored(stored: String?): GuideTextSize = entries.firstOrNull { it.raw == stored } ?: NORMAL
    }
}

/**
 * Type sizes (Apple TV points on a 1920 x 1080 screen, drawn through `sp()` so they keep the same proportion of
 * the screen, DM Mono Medium) for the text the guide draws, one set per step. Only text changes with the setting:
 * rows stay 64 high, the header 58, the channel column 340, and blocks are laid out from times alone.
 */
data class GuideTextMetrics(
    /** A programme's title in its block. */
    val title: Int,
    /** The time labels across the header. */
    val timeLabel: Int,
    /** The CHANNEL heading over the channel column. */
    val channelHeading: Int,
    /** A row's channel number, and the right-aligned box it sits in. */
    val number: Int,
    val numberWidth: Int,
    /** The channel name after the number. */
    val name: Int,
    /** BROADCASTS RESUME AT 9 PM, on a row Watershed has emptied. */
    val placeholder: Int,
    /** The bundle list's row text and its BUNDLES heading. */
    val packageRowText: Int,
    val packageHeading: Int,
    /** The Now Playing panel: row labels and values, the channel line, UP NEXT and the hint line. */
    val panelText: Int,
    /** The item title, and the CH tag in VT323. */
    val panelTitle: Int,
    val panelTag: Int,
) {
    companion object {
        /**
         * SMALLER's two sizes, named so they are one edit: row text and the bundle list and panel text at 17, times, the
         * heading and the placeholder at 19. They await Chad's visual pick on the Apple TV; 18 and 20 are the fallback.
         */
        const val SMALL_ROW_TEXT = 17
        const val SMALL_TIMES = 19

        private const val BODY = 29
        private const val CAPTION = 25

        /** DEFAULT: row text 20, times, heading and placeholder 22; both below the 25 floor, an exception for the guide only. */
        val NORMAL = GuideTextMetrics(
            title = 20, timeLabel = 22, channelHeading = 22, number = 20, numberWidth = 36, name = 20, placeholder = 22,
            packageRowText = 20, packageHeading = 22, panelText = 20, panelTitle = BODY, panelTag = 28,
        )

        /** SMALLER: a visible step down. The box holds three digits at 17 (30.6 scaled, so 31). Panel title 25 and CH tag 24. */
        val SMALL = GuideTextMetrics(
            title = SMALL_ROW_TEXT, timeLabel = SMALL_TIMES, channelHeading = SMALL_TIMES,
            number = SMALL_ROW_TEXT, numberWidth = 31, name = SMALL_ROW_TEXT, placeholder = SMALL_TIMES,
            packageRowText = SMALL_ROW_TEXT, packageHeading = SMALL_TIMES, panelText = SMALL_ROW_TEXT, panelTitle = 25, panelTag = 24,
        )

        /** LARGER, what LARGE always was: the guide at body (29) everywhere; the bundle list and panel stay at 22. */
        val LARGE = GuideTextMetrics(
            title = BODY, timeLabel = BODY, channelHeading = BODY, number = BODY, numberWidth = 54, name = BODY, placeholder = BODY,
            packageRowText = 22, packageHeading = CAPTION, panelText = 22, panelTitle = BODY, panelTag = 28,
        )
    }
}
