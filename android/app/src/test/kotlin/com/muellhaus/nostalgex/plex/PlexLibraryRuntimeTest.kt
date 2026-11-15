package com.muellhaus.nostalgex.plex

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.net.InetSocketAddress

/**
 * What a Plex scan keeps of a runtime (#315): the floored minutes in `duration` and the real runtime in seconds in
 * `exactDurationSeconds`, which the schedule gives a programme as its slot (`slotSeconds`). The real PlexLibrary against
 * a local server with canned answers.
 */
class PlexLibraryRuntimeTest {
    private lateinit var server: HttpServer
    private lateinit var plex: PlexServer

    private fun movie(key: String, ms: Long?) =
        """{"ratingKey":"$key","type":"movie","title":"Movie $key","addedAt":1700000000""" + (if (ms != null) ""","duration":$ms""" else "") + "}"

    @Before fun start() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { ex ->
            val path = ex.requestURI.path
            val body = when {
                path == "/library/sections" ->
                    """{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"},{"key":"2","type":"show","title":"Shows"}]}}"""
                path == "/library/sections/1/all" -> """{"MediaContainer":{"totalSize":4,"Metadata":[""" + listOf(
                    movie("a", 5_460_400),   // 91 minutes floored, 0.4 s past: slot 5461
                    movie("b", 3_600_000),   // a whole hour
                    movie("c", 5_390_000),   // 89 minutes floored, 50 s past: still in range
                    movie("d", null),        // no runtime: dropped, as before
                ).joinToString(",") + "]}}"
                path == "/library/sections/2/all" -> """{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"s1","type":"show","title":"A Show"}]}}"""
                path == "/library/metadata/s1/allLeaves" ->
                    """{"MediaContainer":{"Metadata":[{"ratingKey":"e1","type":"episode","title":"Episode 1","index":1,"parentIndex":1,"duration":1500200}]}}"""
                else -> """{"MediaContainer":{}}"""
            }.toByteArray()
            ex.responseHeaders.add("Content-Type", "application/json")
            ex.sendResponseHeaders(200, body.size.toLong())
            ex.responseBody.use { it.write(body) }
        }
        server.start()
        plex = PlexServer("Test", "machine1", "http://127.0.0.1:${server.address.port}", "token")
    }

    @After fun stop() = server.stop(0)

    private val items by lazy {
        runBlocking { PlexLibrary(PlexClient("client", "1.0.0")).scan(plex, PlexLibrary.Progress { }) }
    }

    private fun item(key: String) = items.first { it.ratingKey == key }

    @Test fun aMovieKeepsItsRealRuntimeBesideTheFlooredMinutes() {
        assertEquals(91, item("a").duration)
        assertEquals(5460.4, item("a").exactDurationSeconds!!, 1e-6)
        assertEquals(5461, item("a").slotSeconds)
    }

    @Test fun aWholeHourIsExact() {
        assertEquals(60, item("b").duration)
        assertEquals(3600, item("b").slotSeconds)
    }

    @Test fun aRuntimeUnderTheNextMinuteKeepsItsLength() {
        assertEquals(89, item("c").duration)
        assertEquals(5390, item("c").slotSeconds)
    }

    @Test fun anEpisodeKeepsItsRuntimeToo() {
        assertEquals(25, item("e1").duration)
        assertEquals(1500.2, item("e1").exactDurationSeconds!!, 1e-6)
        assertEquals(1501, item("e1").slotSeconds)
    }

    @Test fun anItemWithNoRuntimeIsStillDropped() {
        assertEquals(listOf("a", "b", "c", "e1"), items.map { it.ratingKey }.sorted())
        assertNull(items.firstOrNull { it.ratingKey == "d" })
    }
}
