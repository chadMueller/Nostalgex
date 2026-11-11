package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** ChannelEmptyExplainerTests.swift's plain-language cases, on the same rules as JSON. */
class ChannelRequirementsTest {
    private fun lines(rules: String) = ChannelRequirements.plainLanguage(Json.parseToJsonElement(rules).jsonObject)

    @Test
    fun emptyRulesFallBackToOneLine() {
        assertEquals(listOf("A specific, curated list of titles rather than a general rule"), lines("{}"))
        assertEquals(listOf("A specific, curated list of titles rather than a general rule"), ChannelRequirements.plainLanguage(null))
    }

    @Test
    fun genreYearRatingAndStudioReadAsPlainSentences() {
        val l = lines("""{"genres":{"include":["Horror","Thriller"],"exclude":["Comedy"]},"yearRange":{"min":1980,"max":1999},"contentRatings":["R","NC-17"],"studios":["A24"]}""")
        for (want in listOf("Genre: Horror or Thriller", "Not genre: Comedy", "Released 1980 to 1999", "Rated: R, NC-17", "Studio: A24")) {
            assertTrue("$l", want in l)
        }
        assertFalse("never leak a raw null", l.any { "null" in it })
    }

    @Test
    fun openEndedYearRangeReadsEitherDirection() {
        assertEquals(listOf("Released 2000 or later"), lines("""{"yearRange":{"min":2000}}"""))
        assertEquals(listOf("Released before 1989"), lines("""{"yearRange":{"max":1989}}"""))
    }

    @Test
    fun musicVideoSourceAndKeywordsReadPlainly() {
        val l = lines("""{"source":"musicVideo","keywords":["christmas","holiday","snow","santa","winter"]}""")
        assertTrue("$l", "Music videos only" in l)
        // Keyword lists are capped at four so the card never runs long.
        assertTrue("$l", "About: christmas, holiday, snow, santa" in l)
    }

    @Test
    fun watchedFlagsReadPlainly() {
        assertEquals(listOf("Watched three times or more"), lines("""{"rewatched":true}"""))
        assertEquals(listOf("Unwatched titles only"), lines("""{"unwatchedOnly":true}"""))
    }

    @Test
    fun ratingsKeepOneDecimal() {
        assertEquals(listOf("Plex star rating 7.0 or higher"), lines("""{"ratingMin":7}"""))
        assertEquals(listOf("IMDb rating 6.5 or higher"), lines("""{"imdbRatingMin":6.5}"""))
    }
}
