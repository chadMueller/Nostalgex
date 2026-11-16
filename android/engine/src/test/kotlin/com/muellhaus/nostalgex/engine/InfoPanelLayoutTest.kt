package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.InfoPanelSection.*
import org.junit.Assert.assertEquals
import org.junit.Test

/** Held to the Apple TV's InfoPanelLayout order (InfoPanelLayoutTests, 106e8dda). */
class InfoPanelLayoutTest {
    private fun s(artist: Boolean = false, genres: Boolean = false, episode: Boolean = false, badges: Boolean = false, upNext: Boolean = false) =
        InfoPanelLayout.sections(artist, genres, episode, badges, upNext)

    @Test fun aBareProgrammeIsTitleDividerDescriptionProgress() =
        assertEquals(listOf(TITLE, DIVIDER, DESCRIPTION, PROGRESS), s())

    @Test fun theDescriptionComesAfterTheBadgesAndBeforeTheProgress() =
        assertEquals(listOf(TITLE, DIVIDER, BADGES, DESCRIPTION, PROGRESS, UP_NEXT), s(badges = true, upNext = true))

    @Test fun anEpisodeHasItsLineUnderTheTitle() =
        assertEquals(listOf(TITLE, EPISODE, DIVIDER, BADGES, DESCRIPTION, PROGRESS), s(episode = true, badges = true))

    @Test fun aMusicVideoHasArtistThenGenresThenTheRest() =
        assertEquals(listOf(TITLE, ARTIST, GENRES, DIVIDER, BADGES, DESCRIPTION, PROGRESS, UP_NEXT),
            s(artist = true, genres = true, badges = true, upNext = true))

    @Test fun theDescriptionIsAlwaysThere() {
        for (badges in listOf(false, true)) for (upNext in listOf(false, true)) {
            val sections = s(badges = badges, upNext = upNext)
            assertEquals(1, sections.count { it == DESCRIPTION })
            assertEquals(sections.indexOf(DESCRIPTION) + 1, sections.indexOf(PROGRESS))
        }
    }

    @Test fun theDescriptionHoldsTwoLines() = assertEquals(2, InfoPanelLayout.DESCRIPTION_LINES)
}
