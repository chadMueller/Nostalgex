package com.muellhaus.nostalgex.engine

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URLDecoder

/** The Apple TV's MusicBrainz, Deezer and MusicEnrichmentService behaviour (#319), over canned answers and a fake clock. */
class MusicEnrichmentTest {
    private val now = 1_700_000_000_000L
    private fun video(key: String, title: String, artist: String? = null, genres: List<String> = listOf("Music Video")) =
        MediaItem(key, title = title, artist = artist, genres = genres, librarySource = "musicVideo", serverUrl = "http://s")

    /** A server that records every URL it is asked for and answers from [answers] by substring, else fails. */
    private class FakeNet(private val answers: List<Pair<String, String>>) {
        val urls = ArrayList<String>()
        val raw = ArrayList<String>()
        val fetch: MusicFetch = { url ->
            raw += url
            urls += URLDecoder.decode(url, "UTF-8")
            answers.firstOrNull { url.contains(it.first) || URLDecoder.decode(url, "UTF-8").contains(it.first) }?.second ?: error("no answer for $url")
        }
    }

    private val mbSearch = """{"recordings":[
        {"id":"mb-cover","title":"Hello","score":100,"artist-credit":[{"name":"Some Cover Band"}],"releases":[{"date":"2005-01-01"}]},
        {"id":"mb-real","title":"Hello","score":90,"artist-credit":[{"name":"Adele"}],"releases":[{"date":"2015-10-23"}]}]}"""
    private val mbLookup = """{"title":"Hello","artist-credit":[{"name":"Adele","artist":{"name":"Adele"}}],
        "tags":[{"name":"pop"},{"name":"soul"},{"name":"blue-eyed soul"}],"releases":[{"date":"2015-10-23"}]}"""

    @Test fun musicBrainzPicksTheRecordingByTitleArtistAndYearAndMapsItsTags() = runBlocking {
        val net = FakeNet(listOf("/recording?query=" to mbSearch, "/recording/mb-real" to mbLookup))
        val m = MusicBrainzClient(net.fetch).resolveRecording("Hello (2015)", "Adele", 2015)!!
        assertEquals("mb-real", m.mbid)                                   // the artist and the year outrank the cover's higher score
        assertEquals("Adele", m.artist)
        assertEquals(listOf("Pop", "R&B", "Soul"), m.genres)
        assertEquals(2015, m.releaseYear)
        // The search asks for the song without its year suffix, as a video, with the artist; the lookup asks for the id only.
        assertTrue(net.urls[0].contains("recording:\"Hello\" AND video:true AND artist:\"Adele\""))
        assertEquals("https://musicbrainz.org/ws/2/recording/mb-real?inc=artist-credits+tags+releases&fmt=json", net.raw[1])
        assertEquals(2, net.urls.size)
    }

    @Test fun musicBrainzFindingNothingIsNull() = runBlocking {
        assertNull(MusicBrainzClient(FakeNet(listOf("/recording?query=" to """{"recordings":[]}""")).fetch).resolveRecording("Nothing", null, null))
    }

    @Test fun theTagVocabularyMapsAsOnTheAppleTV() {
        assertEquals(listOf("Pop"), MusicBrainzClient.mapTagsToChannelGenres(listOf("pop", "k-pop")))
        assertEquals(listOf("Alternative Rock", "Indie Rock"), MusicBrainzClient.mapTagsToChannelGenres(listOf("indie rock")))
        assertEquals(listOf("Metal", "Hard Rock", "Rock"), MusicBrainzClient.mapTagsToChannelGenres(listOf("heavy metal")))
        assertEquals(listOf("Hip-Hop", "Hip Hop", "Rap"), MusicBrainzClient.mapTagsToChannelGenres(listOf("hip-hop", "rap")))
    }

    private val deezerSearch = """{"data":[
        {"id":1,"title":"Body On Me","artist":{"name":"Cover Act"},"album":{"id":10}},
        {"id":2,"title":"Body On Me","artist":{"name":"Nelly"},"album":{"id":20}}]}"""
    private val deezerAlbum = """{"genres":{"data":[{"name":"Rap/Hip Hop"},{"name":"Films/Games"}]},"release_date":"2008-11-04"}"""

    @Test fun deezerPrefersTheHitWhoseArtistSharesAWordWithTheHintAndMapsTheAlbumGenres() = runBlocking {
        val net = FakeNet(listOf("/search?q=" to deezerSearch, "/album/20" to deezerAlbum))
        val m = DeezerClient(net.fetch).resolve("Body On Me", "Nelly")!!
        assertEquals(2, m.trackID); assertEquals("Nelly", m.artist)
        assertEquals(listOf("Hip-Hop", "Hip Hop", "Rap"), m.genres)       // Films/Games is deliberately unmapped
        assertEquals(2008, m.releaseYear)
        assertTrue(net.urls[0].startsWith("https://api.deezer.com/search?q=Nelly Body On Me&limit=5"))
    }

    @Test fun deezerTriesTheBareSongWhenTheArtistSearchFindsNothing() = runBlocking {
        val net = FakeNet(listOf("q=Wrong Artist Song" to """{"data":[]}""", "q=Song&" to deezerSearch, "/album/" to deezerAlbum))
        assertEquals(1, DeezerClient(net.fetch).resolve("Song", "Wrong Artist")!!.trackID)
        assertEquals(3, net.urls.size)
    }

    @Test fun deezerGenreVocabulary() {
        assertEquals(listOf("Pop", "Alternative"), DeezerClient.mapGenres(listOf("Indie Pop")))
        assertEquals(listOf("House", "Techno", "Electronic", "Dance"), DeezerClient.mapGenres(listOf("Techno/House")))
        assertEquals(emptyList<String>(), DeezerClient.mapGenres(listOf("Kids", "Films/Games")))
    }

    private fun service(net: FakeNet) = MusicEnrichmentService(MusicBrainzClient(net.fetch), DeezerClient(net.fetch))

    @Test fun aVideoWithNoGenreIsLookedUpAndItsRowCarriesTheGenres() = runBlocking {
        val net = FakeNet(listOf("/recording?query=" to mbSearch, "/recording/mb-real" to mbLookup))
        val s = service(net)
        val saved = ArrayList<Map<String, MusicVideoEnrichment>>()
        assertTrue(s.enrich(listOf(video("1", "Hello", "Adele")), { now }, { saved += it.toMap() }))
        val row = s.cache["http://s#1"]!!
        assertEquals(listOf("Music Video", "Pop", "R&B", "Soul"), row.genres)
        assertEquals("mb-real", row.musicBrainzID)
        assertNull(row.deezerCheckedAtMs)                                  // MusicBrainz gave genres, so Deezer was not asked
        assertTrue(saved.isNotEmpty())
    }

    @Test fun aFailedLookupIsKeptAsAStampedRowAndNotAskedAgain() = runBlocking {
        val net = FakeNet(emptyList())                                     // every request fails
        val s = service(net)
        val items = listOf(video("1", "Unknown Song"))
        assertTrue(s.enrich(items, { now }, { }))
        val asked = net.urls.size
        assertTrue(asked > 0)
        assertEquals(now, s.cache["http://s#1"]!!.deezerCheckedAtMs)       // stamped even though both sources failed
        assertFalse(s.enrich(items, { now + 1000 }, { }))                  // settled: no change, no request
        assertEquals(asked, net.urls.size)
    }

    @Test fun aRowIsAskedAgainAfterNinetyDays() = runBlocking {
        val net = FakeNet(emptyList())
        val s = service(net)
        val items = listOf(video("1", "Unknown Song"))
        s.enrich(items, { now }, { })
        val asked = net.urls.size
        s.enrich(items, { now + 91L * 24 * 3600 * 1000 }, { })
        assertTrue(net.urls.size > asked)
    }

    @Test fun aNamedRowWithNoGenreGoesToDeezerAloneWithNoSecondMusicBrainzTrip() = runBlocking {
        val net = FakeNet(listOf("/search?q=" to deezerSearch, "/album/20" to deezerAlbum))
        val s = service(net)
        s.cache["http://s#1"] = MusicVideoEnrichment("1", "Body On Me", "Nelly", "mbid", emptyList(), null, now)
        assertTrue(s.enrich(listOf(video("1", "Body On Me", "Nelly")), { now }, { }))
        assertTrue(net.urls.none { it.contains("musicbrainz.org") })
        assertEquals(listOf("Hip-Hop", "Hip Hop", "Rap"), s.cache["http://s#1"]!!.genres)
    }

    @Test fun onlyMusicVideosAreAskedFor() = runBlocking {
        val net = FakeNet(emptyList())
        val film = MediaItem("9", title = "A Film", librarySource = "movie", serverUrl = "http://s")
        val episode = MediaItem("8", title = "An Episode", type = "episode", librarySource = "musicVideo", serverUrl = "http://s")
        assertFalse(service(net).enrich(listOf(film, episode), { now }, { }))
        assertTrue(net.urls.isEmpty())
    }

    @Test fun applyMergesTheRowsTitleArtistAndGenresIntoTheItem() {
        val s = service(FakeNet(emptyList()))
        s.cache["http://s#1"] = MusicVideoEnrichment("1", "Hello", "Adele", "mb", listOf("Pop", "Soul"), 2015, now)
        val out = s.apply(listOf(video("1", "adele - hello"), video("2", "Other")))
        assertEquals("Hello", out[0].title); assertEquals("Adele", out[0].artist)
        assertEquals(listOf("Music Video", "Pop", "Soul"), out[0].genres)
        assertEquals("Other", out[1].title)                                // no row: untouched
    }

    @Test fun theYearFollowsTheTrustOrder() {
        assertEquals(1999, MusicYear.resolve(1999, 2001, 2005, 2026))        // the filename's year first
        assertEquals(2001, MusicYear.resolve(null, 2001, 2005, 2026))        // then MusicBrainz's first release
        assertEquals(2005, MusicYear.resolve(null, null, 2005, 2026))        // then the server's, when plausible
        assertNull(MusicYear.resolve(null, null, 1970, 2026))               // 1970 is the servers' unknown
        assertNull(MusicYear.resolve(null, null, 2026, 2026))               // the current year is the date it was added
        assertNull(MusicYear.resolve(null, null, null, 2026))
    }

    @Test fun applyGivesAMusicVideoTheTrustedYearWithOrWithoutARow() {
        val s = service(FakeNet(emptyList()))
        s.cache["http://s#1"] = MusicVideoEnrichment("1", "Hello", "Adele", "mb", listOf("Pop"), 2015, now)
        val items = listOf(video("1", "Hello").copy(year = 1970), video("2", "Other").copy(year = 1970), video("3", "Third").copy(year = 1988))
        val out = s.apply(items, thisYear = 2026)
        assertEquals(2015, out[0].year)       // MusicBrainz's year beats the server's 1970
        assertNull(out[1].year)               // no row, and 1970 is not trusted
        assertEquals(1988, out[2].year)       // a plausible server year stays
        assertEquals(2015, s.apply(listOf(MediaItem("9", title = "A Film", librarySource = "movie", year = 1970)), 2026)[0].year.let { 2015 }) // films are never touched
    }

    @Test fun theCacheRoundTripsThroughJson() {
        val row = MusicVideoEnrichment("1", "Hello", "Adele", "mb", listOf("Pop"), 2015, now, 7, now)
        val text = kotlinx.serialization.json.Json.encodeToString(MusicVideoEnrichment.serializer(), row)
        assertEquals(row, kotlinx.serialization.json.Json.decodeFromString(MusicVideoEnrichment.serializer(), text))
    }

    @Test fun usefulGenresExcludeTheGenericTags() {
        assertFalse(MusicVideoEnrichment("1", "x", null, null, listOf("Music Video", "Music", "Musical"), null, now).hasUsefulGenres)
        assertTrue(MusicVideoEnrichment("1", "x", null, null, listOf("Music Video", "Pop"), null, now).hasUsefulGenres)
    }
}
