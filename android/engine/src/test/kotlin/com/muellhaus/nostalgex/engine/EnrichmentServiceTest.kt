package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger

/**
 * The enrichment's orchestration: caches, batching, the relay, the OMDb budget and backoff.
 * The cases are upstream's own (scripts/nostalgex-enrichment-smoke.mjs), with the same stub
 * backends and the same expected numbers, plus the Android port's 403 stop.
 */
class EnrichmentServiceTest {
    private val now = Instant.parse("2026-10-11T12:00:00.000Z").toEpochMilli()
    private val cfg = EnrichmentService.Config("https://example.supabase.co", "anon", "https://nostalgex.app/api/tmdb")

    data class Call(val url: String, val headers: Map<String, String>, val body: String?) {
        val isPost get() = body != null
    }

    private class StubNet(val handler: (url: String, body: String?, n: Int) -> EnrichmentService.Response) : EnrichmentService.Net {
        val calls: MutableList<Call> = Collections.synchronizedList(ArrayList())
        val active = AtomicInteger()
        val peak = AtomicInteger()
        private fun call(url: String, headers: Map<String, String>, body: String?): EnrichmentService.Response {
            calls += Call(url, headers, body)
            val a = active.incrementAndGet()
            peak.accumulateAndGet(a, ::maxOf)
            try {
                Thread.sleep(2)
                return handler(url, body, calls.size)
            } finally {
                active.decrementAndGet()
            }
        }
        override fun get(url: String, headers: Map<String, String>) = call(url, headers, null)
        override fun post(url: String, headers: Map<String, String>, body: String) = call(url, headers, body)
    }

    private class MemoryCache : EnrichmentService.Cache {
        val rows = HashMap<String, EnrichmentService.CacheRow>()
        override fun getMany(ids: List<String>) = synchronized(rows) { ids.mapNotNull { rows[it] }.associateBy { it.tmdbID } }
        override fun putMany(rows: List<EnrichmentService.CacheRow>) = synchronized(this.rows) { rows.forEach { this.rows[it.tmdbID] = it } }
    }

    private class MemoryBackoff : EnrichmentService.OmdbBackoff {
        var until = 0L
        override fun blockedUntilMs() = until
        override fun mark(nowMs: Long) { until = EnrichmentService.nextUTCMidnight(nowMs) }
    }

    private fun ok(body: String) = EnrichmentService.Response(200, body)
    private fun status(s: Int) = EnrichmentService.Response(s, "{}")
    private fun idsIn(url: String) = Regex("in\\.\\(([^)]*)\\)").find(url)!!.groupValues[1].split(",")
    private fun service(net: StubNet, cache: EnrichmentService.Cache = MemoryCache(), backoff: EnrichmentService.OmdbBackoff = MemoryBackoff(), config: EnrichmentService.Config = cfg) =
        EnrichmentService(config, net, cache, backoff)

    // ── Supabase batching ───────────────────────────────────────────────────

    @Test fun supabaseIsReadInChunksOf200() {
        val net = StubNet { url, _, _ ->
            if (url.contains("/rest/v1/")) ok(Json.encodeToString(kotlinx.serialization.json.JsonArray.serializer(),
                kotlinx.serialization.json.JsonArray(idsIn(url).filter { it.toInt() % 2 == 0 }.map { Json.parseToJsonElement("""{"tmdb_id":"$it","media_type":"movie","keywords":[]}""") })))
            else status(404)
        }
        val items = (1..450).map { MediaItem("k$it", tmdbID = it.toLong()) }
        val progress = ArrayList<String>()
        val r = service(net).enrich(items, nowMs = now) { d, t, phase -> if (phase == "cache" && d > 0) progress += "$d/$t" }
        val reads = net.calls.filter { it.url.contains("/rest/v1/") && !it.isPost }
        assertEquals(listOf(200, 200, 50), reads.map { idsIn(it.url).size })
        assertTrue(reads[0].url.startsWith("https://example.supabase.co/rest/v1/media_enrichments?tmdb_id=in.(1,2,3,"))
        assertTrue(reads[0].url.endsWith(")&select=*"))
        assertEquals(mapOf("apikey" to "anon", "Authorization" to "Bearer anon", "Content-Type" to "application/json"), reads[0].headers)
        assertEquals(225, r.stats.supabase)
        assertEquals(listOf("1/3", "2/3", "3/3"), progress)
    }

    @Test fun aFailedSupabaseChunkIsSkippedNotFatal() {
        val net = StubNet { url, _, _ ->
            when {
                url.contains("/rest/v1/") && idsIn(url).first() == "201" -> status(500)
                url.contains("/rest/v1/") -> ok("""[{"tmdb_id":"${idsIn(url).first()}","media_type":"movie"}]""")
                else -> status(404)
            }
        }
        val r = service(net).enrich((1..401).map { MediaItem("k$it", tmdbID = it.toLong()) }, nowMs = now)
        assertEquals(2, r.stats.supabase)
    }

    @Test fun upsertsGoInChunksOf200WithTheTmdbColumnsPinned() {
        val net = StubNet { url, body, _ ->
            when {
                url.contains("/rest/v1/") && body == null -> ok("[]")
                url.contains("/rest/v1/") -> EnrichmentService.Response(201, null)
                else -> ok("{}")
            }
        }
        val r = service(net).enrich((1..250).map { MediaItem("k$it", tmdbID = it.toLong()) }, nowMs = now)
        val ups = net.calls.filter { it.isPost }
        assertEquals(listOf(200, 50), ups.map { Json.parseToJsonElement(it.body!!).jsonArray.size })
        assertEquals("resolution=merge-duplicates,return=minimal", ups[0].headers["Prefer"])
        assertEquals("https://example.supabase.co/rest/v1/media_enrichments?columns=tmdb_id,media_type,keywords,networks,production_companies,tmdb_genres,franchise_id,franchise_name,fetched_at", ups[0].url)
        assertEquals(250, r.stats.upserted)
    }

    // ── The relay ───────────────────────────────────────────────────────────

    @Test fun theRelayIsAskedByTypeAsAndroidAtMostSixAtOnce() {
        val net = StubNet { url, body, _ -> if (url.contains("/rest/v1/")) (if (body == null) ok("[]") else status(201)) else ok("""{"id":1}""") }
        val items = listOf(MediaItem("a", type = "episode", tmdbID = 1399), MediaItem("b", tmdbID = 603)) +
            (1000..1039).map { MediaItem("m$it", tmdbID = it.toLong()) }
        service(net).enrich(items, nowMs = now)
        val relay = net.calls.filter { it.url.contains("path=") }
        assertTrue(relay.any { it.url == "https://nostalgex.app/api/tmdb?path=tv/1399" })
        assertTrue(relay.any { it.url == "https://nostalgex.app/api/tmdb?path=movie/603" })
        assertTrue(relay.all { it.headers["X-Nostalgex-Client"] == "android" })
        assertEquals(42, relay.size)
        assertTrue("peak ${net.peak.get()}", net.peak.get() <= 6)
    }

    /** The Android port's own: until the relay lists `android`, one 403 ends the TMDB step. */
    @Test fun aRelayThatRefusesTheClientIsNotAskedForEveryMiss() {
        val net = StubNet { url, body, _ -> if (url.contains("/rest/v1/")) (if (body == null) ok("[]") else status(201)) else status(403) }
        val r = service(net).enrich((1..500).map { MediaItem("k$it", tmdbID = it.toLong()) }, nowMs = now)
        assertTrue(r.stats.relayRefused)
        assertTrue("asked ${net.calls.count { it.url.contains("path=") }}", net.calls.count { it.url.contains("path=") } <= EnrichmentService.RELAY_CONCURRENCY)
        assertEquals(0, net.calls.count { it.isPost })
    }

    // ── enrichLibrary end to end ────────────────────────────────────────────

    private fun library() = listOf(
        MediaItem("a", title = "A", tmdbID = 1),
        MediaItem("b", title = "B", tmdbID = 2),
        MediaItem("s1", title = "Show", type = "episode", tmdbID = 3),
        MediaItem("s2", title = "Show", type = "episode", tmdbID = 3),
        MediaItem("g", title = "Gone", tmdbID = 4),
        MediaItem("f", title = "Flaky", tmdbID = 5),
        MediaItem("n", title = "No id", tmdbID = null),
    )

    private fun backend() = StubNet { url, body, _ ->
        when {
            url.contains("/rest/v1/") && body == null -> ok("""[{"tmdb_id":"1","media_type":"movie","keywords":["cached"]}]""")
            url.contains("/rest/v1/") -> status(201)
            url.endsWith("path=movie/2") -> ok("""{"keywords":{"keywords":[{"name":"fresh"}]}}""")
            url.endsWith("path=tv/3") -> ok("""{"keywords":{"results":[{"name":"sitcom"}]},"networks":[{"name":"NBC"}]}""")
            url.endsWith("path=movie/4") -> status(404)
            else -> status(429)
        }
    }

    @Test fun endToEndAsTheWebTuner() {
        val cache = MemoryCache()
        val f = backend()
        val svc = service(f, cache)
        val early = svc.enrich(library(), remote = false, nowMs = now)
        assertEquals(emptyList<String>(), early.records.keys.toList())
        assertEquals(0, f.calls.size)

        val r = svc.enrich(library(), nowMs = now)
        with(r.stats) { assertEquals(listOf(5, 0, 1, 2, 1, 1, 2), listOf(ids, local, supabase, fetched, misses, failed, upserted)) }
        assertEquals(listOf("1", "2", "3"), r.records.keys.sorted())
        val items = EnrichmentService.attach(library(), r.records)
        assertEquals(listOf("A", "B", "Show", "Show"), items.filter { it.enrichment != null }.map { it.title })
        assertEquals(listOf("sitcom"), items[2].enrichment!!.keywords)
        val supa = f.calls.filter { it.url.contains("/rest/v1/") }
        assertEquals(listOf(false, true), supa.map { it.isPost })
        assertEquals(listOf("2", "3"), Json.parseToJsonElement(supa[1].body!!).jsonArray.map { it.jsonObject["tmdb_id"]!!.jsonPrimitive.content }.sorted())
        val sent = f.calls.joinToString(" ") { it.url + " " + (it.body ?: "") }
        assertFalse(Regex("title|Show|Gone|tt\\d").containsMatchIn(sent))
        assertNull(cache.rows["4"]!!.record)
        assertFalse(cache.rows.containsKey("5"))

        // Reload inside the TTL: nothing leaves the TV except the id that failed.
        val f2 = backend()
        val second = service(f2, cache).enrich(library(), nowMs = now + 3_600_000)
        assertEquals(3, second.stats.local)
        assertEquals(listOf("/rest/v1/media_enrichments?tmdb_id=in.(5)&select=*", "/api/tmdb?path=movie/5"),
            f2.calls.map { it.url.replace(Regex("^https://[^/]+"), "") })
        assertEquals(listOf("fresh"), EnrichmentService.attach(library(), second.records)[1].enrichment!!.keywords)

        // And the local-only pass now builds from what the first load kept.
        assertEquals(listOf("1", "2", "3"), service(backend(), cache).enrich(library(), remote = false, nowMs = now + 3_600_000).records.keys.sorted())

        // Past the TTL: Supabase is asked again.
        val f3 = backend()
        service(f3, cache).enrich(library(), nowMs = now + EnrichmentService.CACHE_TTL_MS + 1)
        assertTrue(f3.calls[0].url.contains("tmdb_id=in.(1,2,3,4,5)"))
    }

    @Test fun withoutConfigurationNothingIsAsked() {
        val f = backend()
        service(f, config = EnrichmentService.Config("", "")).enrich(library(), nowMs = now)
        assertEquals(0, f.calls.size)
    }

    // ── OMDb ────────────────────────────────────────────────────────────────

    private val channels = listOf(
        """{"type":"movie","keywords":["French Cinema","subtitled"],"imdbRatingMin":6.5,"imdbVotesMin":5000}""",
        """{"type":"movie","keywords":["cult film"],"genres":{"include":["Horror"]},"imdbVotesMin":30000}""",
        """{"type":"movie","keywords":["spy"]}""",
        null,
    ).map { it?.let { s -> Json.parseToJsonElement(s) as JsonObject } }

    private fun omdbLibrary(n: Int) = (1..n).map { MediaItem("k$it", title = "Film $it", tmdbID = it.toLong(), genres = listOf(if (it % 2 == 1) "Horror" else "Drama")) }

    private fun omdbBackend(limitAfter: Int = Int.MAX_VALUE): StubNet {
        val omdbCalls = AtomicInteger()
        return StubNet { url, body, _ ->
            when {
                url.contains("/rest/v1/") && body == null ->
                    ok(idsIn(url).joinToString(",", "[", "]") { """{"tmdb_id":"$it","media_type":"movie","imdb_id":"tt${it.padStart(7, '0')}","keywords":[]}""" })
                url.contains("/rest/v1/") -> status(201)
                url.contains("path=omdb/") ->
                    if (omdbCalls.incrementAndGet() > limitAfter) EnrichmentService.Response(429, """{"Response":"False","Error":"Request limit reached!"}""")
                    else ok("""{"imdbRating":"7.4","imdbVotes":"45,000","Response":"True"}""")
                else -> status(404)
            }
        }
    }

    @Test fun omdbAsksFiftyGatedCandidatesAndSavesTheirColumns() {
        val f = omdbBackend()
        val r = service(f).enrich(omdbLibrary(200), channels, nowMs = now)
        val asked = f.calls.filter { it.url.contains("path=omdb/") }
        assertEquals(100, r.stats.omdbCandidates)
        assertEquals(50, asked.size)
        assertTrue(asked.all { Regex("tt(\\d+)").find(it.url)!!.groupValues[1].toInt() % 2 == 1 })
        assertEquals(50, r.stats.omdbFetched)
        val ups = f.calls.filter { it.isPost }
        assertEquals(1, ups.size)
        assertTrue(ups[0].url.endsWith("columns=${EnrichmentService.OMDB_COLUMNS.joinToString(",")}"))
        val rows = Json.parseToJsonElement(ups[0].body!!).jsonArray
        assertEquals(50, rows.size)
        assertEquals(45000.0, rows[0].jsonObject["imdb_votes"]!!.jsonPrimitive.content.toDouble(), 0.0)
        val rated = EnrichmentService.attach(omdbLibrary(200), r.records).filter { it.enrichment?.imdbRating == 7.4 }
        assertEquals(50, rated.size)
        assertFalse(f.calls.any { it.url.contains("Film") || (it.body ?: "").contains("Film") })
    }

    @Test fun omdbsDailyLimitHoldsUntilUtcMidnight() {
        val backoff = MemoryBackoff()
        val f = omdbBackend(limitAfter = 3)
        val r = service(f, backoff = backoff).enrich(omdbLibrary(200), channels, nowMs = now)
        assertTrue(r.stats.omdbLimited)
        assertTrue(f.calls.count { it.url.contains("path=omdb/") } <= 3 + EnrichmentService.OMDB_CONCURRENCY)
        assertEquals(Instant.parse("2026-10-12T00:00:00Z").toEpochMilli(), backoff.until)

        val f2 = omdbBackend()
        val second = service(f2, backoff = backoff).enrich(omdbLibrary(200), channels, nowMs = now + 3_600_000)
        assertEquals(0, f2.calls.count { it.url.contains("path=omdb/") })
        assertTrue(second.stats.omdbPaused)

        val f3 = omdbBackend()
        service(f3, backoff = backoff).enrich(omdbLibrary(200), channels, nowMs = Instant.parse("2026-10-12T00:00:01Z").toEpochMilli())
        assertEquals(50, f3.calls.count { it.url.contains("path=omdb/") })
    }

    @Test fun withoutGatedChannelsThereIsNoOmdb() {
        val f = omdbBackend()
        val r = service(f).enrich(omdbLibrary(20), nowMs = now)
        assertEquals(0, r.stats.omdbGates)
        assertEquals(0, f.calls.count { it.url.contains("path=omdb/") })
    }

    @Test fun pickingTakesFiftyWithoutRepeatsAndLeavesTheInputAlone() {
        val list = (0 until 300).toList()
        val rnd = java.util.Random(7)
        val picked = EnrichmentService.pickOMDbLookups(list, 50) { rnd.nextDouble() }
        assertEquals(50, picked.size)
        assertEquals(50, picked.toSet().size)
        assertTrue(picked != list.take(50))
        assertEquals(listOf(1, 2, 3), EnrichmentService.pickOMDbLookups(listOf(1, 2, 3), 50) { rnd.nextDouble() }.sorted())
        assertEquals(listOf(0, 1, 2), list.take(3))
    }
}
