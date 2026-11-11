package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.LibraryDiagnostics.Coverage
import com.muellhaus.nostalgex.engine.LibraryDiagnostics.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The coverage line under RESCAN LIBRARY: the Apple TV's LibraryCoverageTests wording, case for case. */
class LibraryDiagnosticsTest {
    private fun cov(loaded: Map<Kind, Int>, on: Map<Kind, Int>) = Coverage(loaded, on)

    @Test fun theWording() {
        assertEquals("412 OF 484 ON CHANNELS · 72 ON NO CHANNEL",
            LibraryDiagnostics.coverageLine(cov(mapOf(Kind.MOVIE to 484), mapOf(Kind.MOVIE to 412)), 0))
        assertEquals("484 OF 484 ON CHANNELS",
            LibraryDiagnostics.coverageLine(cov(mapOf(Kind.MOVIE to 484), mapOf(Kind.MOVIE to 484)), 0))
        assertEquals("484 OF 484 ON CHANNELS · 12 SKIPPED (NO RUNTIME)",
            LibraryDiagnostics.coverageLine(cov(mapOf(Kind.MOVIE to 484), mapOf(Kind.MOVIE to 484)), 12))
        assertEquals("11,633 OF 11,809 ON CHANNELS · 176 ON NO CHANNEL (4 MOVIES, 172 EPISODES)",
            LibraryDiagnostics.coverageLine(cov(
                mapOf(Kind.MOVIE to 1_792, Kind.EPISODE to 8_891, Kind.MUSIC_VIDEO to 1_126),
                mapOf(Kind.MOVIE to 1_788, Kind.EPISODE to 8_719, Kind.MUSIC_VIDEO to 1_126)), 0))
        assertEquals("13 OF 15 ON CHANNELS · 2 ON NO CHANNEL",
            LibraryDiagnostics.coverageLine(cov(mapOf(Kind.MOVIE to 10, Kind.EPISODE to 5), mapOf(Kind.MOVIE to 8, Kind.EPISODE to 5)), 0))
        assertEquals("3 SKIPPED (NO RUNTIME)", LibraryDiagnostics.coverageLine(null, 3))
        assertNull(LibraryDiagnostics.coverageLine(null, 0))
        assertNull(LibraryDiagnostics.coverageLine(cov(emptyMap(), emptyMap()), 0))
    }

    private fun item(key: String, type: String = "movie", source: String = "movie") =
        MediaItem(ratingKey = key, title = key, type = type, duration = 90, librarySource = source)

    /** Each title once, however many channels take it; kinds from type and library source. */
    @Test fun countsEachTitleOnceByKind() {
        val a = item("a"); val b = item("b"); val c = item("c", type = "episode", source = "tv"); val d = item("d", source = "musicVideo")
        val got = LibraryDiagnostics.coverage(listOf(a, b, c, d), listOf(listOf(a, c), listOf(a)))
        assertEquals(mapOf(Kind.MOVIE to 2, Kind.EPISODE to 1, Kind.MUSIC_VIDEO to 1), got.loaded)
        assertEquals(2, got.totalOnChannels)
        assertEquals(1, got.orphans(Kind.MOVIE))
        assertEquals(1, got.orphans(Kind.MUSIC_VIDEO))
    }
}
