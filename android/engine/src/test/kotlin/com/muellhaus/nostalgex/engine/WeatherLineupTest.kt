package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneId
import java.time.ZonedDateTime

/** LOCAL WEATHER (CH 299) as a guest in the guide: where it sits, what its row says, and that it never disturbs the library's schedule. */
class WeatherLineupTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private fun read(path: String) = Json.parseToJsonElement(repoRoot.resolve(path).readText()).jsonObject
    private val config = ChannelConfig(read("channels.json"))
    private val memberships = read("channels-memberships.json")
    private val zone = ZoneId.of("America/Toronto")
    private val now = ZonedDateTime.of(2026, 11, 15, 13, 20, 0, 0, zone)

    private val genres = listOf("Comedy", "Drama", "Action", "Adventure", "Thriller", "Romance", "Crime", "Science Fiction", "Family", "Fantasy")
    private fun library(): List<MediaItem> = (0 until 300).map { i ->
        MediaItem(
            ratingKey = "m$i", title = "Film $i", type = "movie", duration = 85 + i % 60, year = 1975 + i % 30,
            genres = listOf(genres[i % genres.size], genres[(i * 7 + 3) % genres.size]), contentRating = listOf("G", "PG", "PG-13", "R")[i % 4], librarySource = "movie",
        )
    }

    private val channel = GuideChannel(
        ChannelConfig.StockChannel(Weather.CHANNEL_ID, Weather.CHANNEL_NUMBER, Weather.CHANNEL_NAME, Weather.CHANNEL_COLOR, "weather", 0, null, null, false),
        emptyList(), weather = true,
    )
    private fun row(place: String = "TORONTO, ON, CA", summary: String = "Cloudy, 6°C.") = Lineup.WeatherRow(channel, { place }, { summary })
    private fun lineup() = Lineup(config, memberships, DailyManifest(zone, InMemoryManifestStore()), "test")

    @Test fun theChannelSitsAtItsNumberAndHasAnHourLongRow() {
        val l = lineup()
        l.setWeather(row())
        l.build(library(), setOf("nostalgex"))
        l.rebuildSchedules(now)
        val numbers = l.channels.map { it.number }
        assertTrue("CH 299 is in the guide", 299 in numbers)
        assertEquals("sorted by number with the rest", numbers.sorted(), numbers)
        val wx = l.channels.first { it.weather }
        val s = l.schedules[wx.id]
        assertNotNull(s)
        s!!
        assertTrue(s.entries.size >= 24)
        assertTrue(s.entries.all { it.endSec - it.startSec == 3600L })
        val np = s.nowPlaying!!
        val nowSec = now.toEpochSecond()
        assertTrue(nowSec >= np.startSec && nowSec < np.endSec)
        assertEquals("LOCAL WEATHER", np.item.title)
        // The info panel reads the place under the title, then the line.
        assertEquals("episode", np.item.type)
        assertEquals("TORONTO, ON, CA", np.item.episodeTitle)
        assertEquals("Cloudy, 6°C.", np.item.summary)
        assertNull("the loop has no up next", s.upNext)
        assertTrue(s.progress in 0.0..1.0)
        // Entries are contiguous: a guide block follows the one before.
        s.entries.zipWithNext().forEach { (a, b) -> assertEquals(a.endSec, b.startSec) }
    }

    @Test fun theLibrarysScheduleIsTheSameWithOrWithoutIt() {
        val without = lineup().also { it.build(library(), setOf("nostalgex")); it.rebuildSchedules(now) }
        val with = lineup().also { it.setWeather(row()); it.build(library(), setOf("nostalgex")); it.rebuildSchedules(now) }
        for ((id, s) in without.schedules) {
            assertEquals("channel $id", s.entries.map { it.item.ratingKey to it.startSec }, with.schedules.getValue(id).entries.map { it.item.ratingKey to it.startSec })
        }
        assertEquals(without.schedules.size + 1, with.schedules.size)
    }

    @Test fun theSwitchTakesItOutAndBack() {
        val l = lineup()
        l.setWeather(row())
        l.build(library(), setOf("nostalgex"))
        l.rebuildSchedules(now)
        l.setWeather(null)
        l.rebuildSchedules(now)
        assertFalse(l.channels.any { it.weather })
        assertFalse(l.schedules.containsKey(Weather.CHANNEL_ID))
        l.setWeather(row("LONDON, ENGLAND, GB"))
        l.rebuildSchedules(now)
        assertEquals("LONDON, ENGLAND, GB", l.schedules.getValue(Weather.CHANNEL_ID).nowPlaying!!.item.episodeTitle)
        // A package switched on or off keeps it.
        l.setBundles(setOf("nostalgex", "essentials"))
        assertTrue(l.channels.any { it.weather })
    }

    @Test fun itNeverMakesAGuideOfItsOwn() {
        val l = lineup()
        l.setWeather(row())
        l.build(emptyList(), setOf("nostalgex"))
        assertTrue("a library that fills nothing has no channels, weather or not", l.channels.isEmpty())
    }
}
