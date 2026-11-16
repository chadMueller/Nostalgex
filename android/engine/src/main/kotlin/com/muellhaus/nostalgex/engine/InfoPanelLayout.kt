package com.muellhaus.nostalgex.engine

/**
 * The lines of the guide's info panel, top to bottom, as the Apple TV's `InfoPanelLayout` lists them (106e8dda):
 * the channel line above everything (drawn first, not listed), the title as the lead line, then artist, genres and
 * episode subtitle where the programme has them, a divider, the badges (year, rating, star rating), the
 * description, the progress bar and UP NEXT as one line.
 *
 * The description comes after the badges and always holds [DESCRIPTION_LINES] lines, empty or not, so the progress
 * bar and UP NEXT stay where they are from one programme to the next.
 */
enum class InfoPanelSection { TITLE, ARTIST, GENRES, EPISODE, DIVIDER, BADGES, DESCRIPTION, PROGRESS, UP_NEXT }

object InfoPanelLayout {
    /** Lines the description area always holds. A longer description ends in an ellipsis. */
    const val DESCRIPTION_LINES = 2

    fun sections(
        hasArtist: Boolean,
        hasGenres: Boolean,
        hasEpisodeLine: Boolean,
        hasBadges: Boolean,
        hasUpNext: Boolean,
    ): List<InfoPanelSection> = buildList {
        add(InfoPanelSection.TITLE)
        if (hasArtist) add(InfoPanelSection.ARTIST)
        if (hasGenres) add(InfoPanelSection.GENRES)
        if (hasEpisodeLine) add(InfoPanelSection.EPISODE)
        add(InfoPanelSection.DIVIDER)
        if (hasBadges) add(InfoPanelSection.BADGES)
        add(InfoPanelSection.DESCRIPTION)
        add(InfoPanelSection.PROGRESS)
        if (hasUpNext) add(InfoPanelSection.UP_NEXT)
    }
}
