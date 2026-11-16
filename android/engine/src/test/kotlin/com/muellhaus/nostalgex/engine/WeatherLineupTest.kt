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
    private fun row(place: String = "TORONTO, ON, CA", summary: String = "Cloudy, 6°C.") = Lineup.WeatherRow(channel, { place }, { summary }, { "6\u00B0C" })
    private fun lineup() = Lineup(config, memberships, DailyManifest(zone, InMemoryManifestStore()), "test")

    @Test fun theChannelSitsAtItsNumberAndIsOneBarThatIsAlwaysLive() {
        val l = lineup()
        l.setWeather(row())
        l.build(library(), setOf("nostalgex"))
        l.rebuildSchedules(now)
        val numbers = l.channels.map { it.number }
        assertTrue("CH 299 is in the guide", 299 in numbers)
        assertEquals("sorted by number with the rest", numbers.sorted(), numbers)
        val wx = l.channels.first { it.weather }
        val s = l.schedules[wx.id]!!
        // One entry for the whole loop: not 30-minute or hour blocks, and no start or end that means anything.
        assertEquals(1, s.entries.size)
        val e = s.entries.single()
        assertEquals(Weather.LOOP_START_SEC, e.startSec)
        assertEquals(Weather.LOOP_END_SEC, e.endSec)
        assertTrue(e.isNowPlaying)
        assertEquals(e, s.nowPlaying)
        assertEquals("LOCAL WEATHER", e.item.title)
        // The info panel reads the place under the title, then the line; the bar shows the temperature.
        assertEquals("TORONTO, ON, CA", e.item.episodeTitle)
        assertEquals("6\u00B0C", e.item.seTag)
        assertEquals("Cloudy, 6\u00B0C.", e.item.summary)
        assertNull("the loop has no up next", s.upNext)
    }

    @Test fun theCursorHasNowhereToStepOnTheBarAndItIsOnAtEveryTimePosition() {
        val l = lineup()
        l.setWeather(row())
        l.build(library(), setOf("nostalgex"))
        l.rebuildSchedules(now)
        val entries = l.schedules.getValue(Weather.CHANNEL_ID).entries
        val nowSec = now.toEpochSecond().toDouble()
        // Live, and a cursor held at a time hours on, or days on, from another row: always the one entry, never a preview, no neighbour.
        for (cursor in listOf(null, nowSec.toLong() + 3600, nowSec.toLong() + 5 * 3600, nowSec.toLong() + 40 * 3600)) {
            assertEquals("cursor $cursor", entries.single(), GuideCursor.current(entries, cursor, nowSec))
            assertNull("no Right from it ($cursor)", GuideCursor.next(entries, cursor, nowSec))
            assertNull("no Left from it ($cursor): the guide goes to the stripe", GuideCursor.previous(entries, cursor, nowSec))
            assertNull("the info panel shows it as live, not as a preview ($cursor)", GuideCursor.preview(entries, cursor, nowSec))
        }
        assertNull(GuideCursor.after(entries, entries.single()))
        // Its cursor is "live" at any time: no cursor is kept for it.
        assertEquals(null, GuideCursor.cursorFor(entries.single(), nowSec))
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
