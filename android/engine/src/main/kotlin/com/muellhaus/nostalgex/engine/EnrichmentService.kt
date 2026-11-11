package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * TMDB and OMDb enrichment: the keywords, networks, production companies and IMDb
 * rating and votes the channel filter reads from `item.enrichment`, so channels gated on
 * them (TEEN MOVIES, MUSICALS, TRUE CRIME, FOREIGN FILMS, CULT CLASSICS, ...) fill as they
 * do on the Apple TV and the web tuner.
 *
 * A port of scripts/nostalgex-enrichment.js, itself EnrichmentService.swift's mirror:
 *   1. one work item per TMDB id (the first item's media type wins)
 *   2. a local cache, then the shared Supabase cache (`media_enrichments`)
 *   3. the misses from TMDB through the site's relay (api/tmdb.js)
 *   4. OMDb, through the same relay, for at most 50 titles per load that could land on an
 *      IMDb-gated channel, none until the next UTC midnight once OMDb says the day's quota
 *      is gone
 *   5. what was fetched written back to Supabase, TMDB and OMDb columns apart
 * Only TMDB and IMDb ids leave the TV: no titles, no server details.
 *
 * What differs, and why:
 *   - The relay is asked as `X-Nostalgex-Client: android`. Until the relay lists it, it
 *     answers 403, and a 403 ends the TMDB step for that load, as the Roku port does,
 *     rather than asking for every miss to be refused.
 *   - The caller runs `enrich` twice: with `remote = false` to build the guide from the
 *     local cache at once, then in full behind it. The web tuner does the same through its
 *     onCacheReady callback.
 *   - Network, cache, clock and randomness come in through [Net], [Cache], `nowMs` and
 *     `random`, so the steps are tested without a server.
 */
class EnrichmentService(
    private val config: Config,
    private val net: Net,
    private val cache: Cache,
    private val backoff: OmdbBackoff,
) {
    data class Config(val supabaseURL: String, val anonKey: String, val relayURL: String = RELAY_URL, val clientValue: String = CLIENT_VALUE) {
        val isComplete get() = supabaseURL.isNotEmpty() && anonKey.isNotEmpty() && relayURL.isNotEmpty()
    }

    data class Response(val status: Int, val body: String?)

    /** HTTP, blocking; a network error is status 0. Called from several threads at once. */
    interface Net {
        fun get(url: String, headers: Map<String, String>): Response
        fun post(url: String, headers: Map<String, String>, body: String): Response
    }

    /** A cached answer: a record, or null for a title TMDB doesn't know (kept a day). */
    data class CacheRow(val tmdbID: String, val savedAtMs: Long, val record: Enrichment?)

    interface Cache {
        fun getMany(ids: List<String>): Map<String, CacheRow>
        fun putMany(rows: List<CacheRow>)
    }

    /** OMDBBackoff: after a daily-limit answer, no OMDb until the next UTC midnight. */
    interface OmdbBackoff {
        fun blockedUntilMs(): Long
        fun mark(nowMs: Long)
    }

    data class Stats(
        var ids: Int = 0, var local: Int = 0, var supabase: Int = 0, var fetched: Int = 0, var misses: Int = 0,
        var failed: Int = 0, var upserted: Int = 0, var relayRefused: Boolean = false,
        var omdbGates: Int = 0, var omdbCandidates: Int = 0, var omdbAsked: Int = 0, var omdbFetched: Int = 0,
        var omdbMisses: Int = 0, var omdbFailed: Int = 0, var omdbLimited: Boolean = false, var omdbPaused: Boolean = false,
        var omdbUpserted: Int = 0,
    ) {
        override fun toString() = "$ids TMDB ids: $local local, $supabase Supabase, $fetched fetched, $misses not on TMDB, $failed failed" +
            (if (relayRefused) " (relay refused this client)" else "") + ", $upserted saved" +
            if (omdbGates == 0) "" else if (omdbPaused) "; OMDb paused until UTC midnight" else
                "; OMDb: $omdbGates gated channels, $omdbCandidates candidates, $omdbAsked asked, $omdbFetched found, $omdbMisses unknown, $omdbFailed failed, $omdbUpserted saved" +
                    if (omdbLimited) ", daily limit hit" else ""
    }

    data class Result(val records: Map<String, Enrichment>, val stats: Stats)

    /**
     * enrichLibrary: the records for `items`' TMDB ids. Never throws. With `remote` false,
     * only the local cache is read. `channels` give the OMDb gates; none means no OMDb.
     * `onProgress(done, total, phase)` reports "cache" and "fetch".
     */
    fun enrich(
        items: List<MediaItem>,
        channels: List<JsonObject?> = emptyList(),
        remote: Boolean = true,
        nowMs: Long = System.currentTimeMillis(),
        random: () -> Double = Math::random,
        onProgress: (Int, Int, String) -> Unit = { _, _, _ -> },
    ): Result {
        val stats = Stats()
        val records = LinkedHashMap<String, Enrichment>()
        val work = workItems(items.map { it.tmdbID?.toString() to it.type })
        stats.ids = work.size
        if (work.isEmpty()) return Result(records, stats)

        // 1. Local cache.
        val local = runCatching { cache.getMany(work.map { it.tmdbID }) }.getOrDefault(emptyMap())
        val needRemote = ArrayList<WorkItem>()
        for (w in work) {
            val row = local[w.tmdbID]
            val ttl = if (row?.record != null) CACHE_TTL_MS else MISS_TTL_MS
            if (row != null && nowMs - row.savedAtMs < ttl) {
                if (row.record != null) {
                    records[w.tmdbID] = row.record
                    stats.local++
                } else {
                    stats.misses++
                }
            } else {
                needRemote += w
            }
        }
        if (!remote || !config.isComplete) return Result(records, stats)

        // 2. Shared Supabase cache.
        val toStore = ArrayList<CacheRow>()
        if (needRemote.isNotEmpty()) {
            onProgress(0, needRemote.size, "cache")
            for (e in readSupabase(needRemote.map { it.tmdbID }) { d, t -> onProgress(d, t, "cache") }) {
                val id = e.tmdbID ?: continue
                if (records.containsKey(id)) continue
                records[id] = e
                toStore += CacheRow(id, nowMs, e)
                stats.supabase++
            }
        }
        if (toStore.isNotEmpty()) runCatching { cache.putMany(toStore) }

        // 3. The relay, for whatever neither cache had.
        val toFetch = needRemote.filter { !records.containsKey(it.tmdbID) }
        val fresh = ArrayList<Enrichment>()
        val freshStore = ArrayList<CacheRow>()
        if (toFetch.isNotEmpty()) {
            val done = AtomicInteger()
            val refused = AtomicBoolean(false)
            onProgress(0, toFetch.size, "fetch")
            concurrently(toFetch, RELAY_CONCURRENCY) { w ->
                if (refused.get()) return@concurrently
                val res = fetchRelay(w)
                synchronized(records) {
                    when {
                        res.status == 200 -> {
                            val doc = parseOrNull(res.body)
                            val e = parseTMDBResponse(doc, w.tmdbID, null, w.mediaType, nowMs)
                            records[w.tmdbID] = e
                            fresh += e
                            freshStore += CacheRow(w.tmdbID, nowMs, e)
                            stats.fetched++
                        }
                        res.status == 404 -> {
                            freshStore += CacheRow(w.tmdbID, nowMs, null)
                            stats.misses++
                        }
                        else -> {
                            stats.failed++
                            // The relay doesn't take this client: the rest would be refused too.
                            if (res.status == 403) {
                                refused.set(true)
                                stats.relayRefused = true
                            }
                        }
                    }
                }
                val d = done.incrementAndGet()
                if (d % 10 == 0 || d == toFetch.size) onProgress(d, toFetch.size, "fetch")
            }
        }

        // 4. OMDb, for the titles that could land on an IMDb-gated channel.
        val omdbFresh = ArrayList<Enrichment>()
        val gates = omdbGates(channels)
        stats.omdbGates = gates.size
        if (gates.isNotEmpty() && !stats.relayRefused) {
            if (nowMs < backoff.blockedUntilMs()) {
                stats.omdbPaused = true
            } else {
                val candidates = omdbCandidates(work, records, genresByTMDB(items), gates)
                stats.omdbCandidates = candidates.size
                val picked = pickOMDbLookups(candidates, OMDB_PER_LOAD, random)
                val stop = AtomicBoolean(false)
                concurrently(picked, OMDB_CONCURRENCY) { c ->
                    if (stop.get()) return@concurrently
                    synchronized(records) { stats.omdbAsked++ }
                    val res = fetchOMDb(c.imdbID)
                    val json = parseOrNull(res.body)
                    synchronized(records) {
                        when {
                            res.status == 429 || isOMDbLimit(json) -> {
                                stop.set(true)
                                stats.omdbLimited = true
                                backoff.mark(nowMs)
                            }
                            res.status != 200 -> {
                                stats.omdbFailed++
                                // Bad key or relay down: stop for this load, as the app does.
                                if (res.status == 401 || res.status == 403 || res.status >= 500) stop.set(true)
                            }
                            else -> {
                                val parsed = parseOMDbResponse(json)
                                if (parsed == null) {
                                    stats.omdbMisses++
                                } else {
                                    val merged = mergeOMDb(c.record, parsed, c.imdbID)
                                    records[c.tmdbID] = merged
                                    omdbFresh += merged
                                    freshStore += CacheRow(c.tmdbID, nowMs, merged)
                                    stats.omdbFetched++
                                }
                            }
                        }
                    }
                }
            }
        }

        // 5. Keep what this TV fetched, locally and in the shared cache.
        if (freshStore.isNotEmpty()) runCatching { cache.putMany(freshStore) }
        if (fresh.isNotEmpty()) stats.upserted = upsertSupabase(fresh, TMDB_COLUMNS, ::toSupabaseRow)
        if (omdbFresh.isNotEmpty()) stats.omdbUpserted = upsertSupabase(omdbFresh, OMDB_COLUMNS, ::toOMDbRow)
        return Result(records, stats)
    }

    // ── Network ─────────────────────────────────────────────────────────────

    private fun supabaseHeaders() = mapOf("apikey" to config.anonKey, "Authorization" to "Bearer ${config.anonKey}", "Content-Type" to "application/json")

    /** SupabaseService.fetchEnrichments, in chunks of 200. A failed chunk is skipped, not fatal. */
    private fun readSupabase(ids: List<String>, onChunk: (Int, Int) -> Unit): List<Enrichment> {
        val out = ArrayList<Enrichment>()
        val chunks = ids.chunked(SUPABASE_CHUNK)
        for ((i, part) in chunks.withIndex()) {
            val res = net.get("${config.supabaseURL}/rest/v1/media_enrichments?tmdb_id=in.(${part.joinToString(",")})&select=*", supabaseHeaders())
            if (res.status == 200) {
                (parseOrNull(res.body) as? JsonArray)?.forEach { row -> fromSupabaseRow(row)?.let(out::add) }
            }
            onChunk(i + 1, chunks.size)
        }
        return out
    }

    /** upsertEnrichments: chunks of 200, merged, touching only `columns`. */
    private fun upsertSupabase(records: List<Enrichment>, columns: List<String>, toRow: (Enrichment) -> JsonObject): Int {
        var written = 0
        val url = "${config.supabaseURL}/rest/v1/media_enrichments?columns=${columns.joinToString(",")}"
        val headers = supabaseHeaders() + ("Prefer" to "resolution=merge-duplicates,return=minimal")
        for (part in records.chunked(SUPABASE_CHUNK)) {
            val res = net.post(url, headers, JsonArray(part.map(toRow)).toString())
            if (res.status in 1..299) written += part.size
        }
        return written
    }

    private fun relayHeaders() = mapOf("Accept" to "application/json", CLIENT_HEADER to config.clientValue)

    private fun fetchRelay(w: WorkItem) =
        net.get("${config.relayURL}?path=${if (w.mediaType == "tv") "tv" else "movie"}/${w.tmdbID}", relayHeaders())

    private fun fetchOMDb(imdbID: String): Response =
        if (!IMDB_ID.matches(imdbID)) Response(400, null) else net.get("${config.relayURL}?path=omdb/$imdbID", relayHeaders())

    data class WorkItem(val tmdbID: String, val mediaType: String)

    data class OmdbCandidate(val tmdbID: String, val imdbID: String, val record: Enrichment)

    /** An OMDb gate: one per channel with an OMDb rule (OMDBGate). */
    data class Gate(val mediaType: String?, val keywords: Set<String>, val genres: List<String>)

    companion object {
        const val SUPABASE_CHUNK = 200
        const val RELAY_CONCURRENCY = 6
        const val CACHE_TTL_MS = 7 * 86_400_000L
        const val MISS_TTL_MS = 86_400_000L
        const val OMDB_PER_LOAD = 50
        const val OMDB_CONCURRENCY = 4
        const val CLIENT_HEADER = "X-Nostalgex-Client"
        const val CLIENT_VALUE = "android"
        /** The apex answers with a redirect. */
        const val RELAY_URL = "https://www.nostalgex.app/api/tmdb"
        val TMDB_COLUMNS = listOf("tmdb_id", "media_type", "keywords", "networks", "production_companies", "tmdb_genres", "franchise_id", "franchise_name", "fetched_at")
        val OMDB_COLUMNS = listOf("tmdb_id", "media_type", "imdb_id", "imdb_rating", "imdb_votes", "rt_score", "metacritic_score", "awards")
        val IMDB_ID = Regex("^tt\\d{7,9}$")
        private val TMDB_ID = Regex("^\\d{1,10}$")
        private val ISO = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

        fun isoTime(ms: Long): String = ISO.format(Instant.ofEpochMilli(ms))

        // ── Pure: shapes ─────────────────────────────────────────────────────

        private fun parseOrNull(body: String?): JsonElement? =
            body?.let { runCatching { kotlinx.serialization.json.Json.parseToJsonElement(it) }.getOrNull() }

        private fun JsonElement?.obj() = this as? JsonObject
        private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        private fun JsonObject.num(k: String) = (this[k] as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.doubleOrNull?.takeIf { it.isFinite() }

        private fun names(list: JsonElement?): List<String> =
            (list as? JsonArray)?.mapNotNull { x -> x.obj()?.str("name") } ?: emptyList()

        private fun stringList(v: JsonElement?): List<String> =
            (v as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content } ?: emptyList()

        /** JavaScript's String() of a JSON value, for ids the server sends as numbers. */
        internal fun jsString(v: JsonElement?): String? = when (v) {
            null, JsonNull -> null
            is JsonPrimitive -> if (v.isString) v.content else v.doubleOrNull?.let { d -> if (d == Math.floor(d) && !d.isInfinite() && Math.abs(d) < 1e21) d.toLong().toString() else d.toString() } ?: v.content
            else -> v.toString()
        }

        /**
         * TMDBService.parseResponse. Movies carry keywords under `keywords.keywords`, TV under
         * `keywords.results`. Franchise from `belongs_to_collection` (movies only). A movie
         * document's `imdb_id` stands in when none was passed. OMDb fields stay empty.
         */
        fun parseTMDBResponse(json: JsonElement?, tmdbID: String, imdbID: String?, mediaType: String, nowMs: Long): Enrichment {
            val doc = json.obj() ?: JsonObject(emptyMap())
            val kw = doc["keywords"].obj()
            val collection = doc["belongs_to_collection"].obj()
            val franchiseID = (collection?.get("id") as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it == Math.floor(it) && it.isFinite() }
            return Enrichment(
                tmdbID = tmdbID,
                imdbID = imdbID ?: doc.str("imdb_id")?.takeIf { IMDB_ID.matches(it) },
                mediaType = mediaType,
                keywords = names(kw?.get(if (mediaType == "tv") "results" else "keywords")),
                networks = names(doc["networks"]),
                productionCompanies = names(doc["production_companies"]),
                tmdbGenres = names(doc["genres"]),
                franchiseID = franchiseID,
                franchiseName = collection?.str("name"),
                fetchedAt = isoTime(nowMs),
            )
        }

        /** A Supabase row as a record (MediaEnrichment's resilient decoder). */
        fun fromSupabaseRow(row: JsonElement?): Enrichment? {
            val r = row.obj() ?: return null
            val id = r["tmdb_id"]
            if (id == null || id is JsonNull) return null
            val mediaType = r.str("media_type") ?: return null
            return Enrichment(
                tmdbID = jsString(id),
                imdbID = r.str("imdb_id"),
                mediaType = mediaType,
                keywords = stringList(r["keywords"]),
                networks = stringList(r["networks"]),
                productionCompanies = stringList(r["production_companies"]),
                tmdbGenres = stringList(r["tmdb_genres"]),
                imdbRating = r.num("imdb_rating"),
                imdbVotes = r.num("imdb_votes"),
                rtScore = r.num("rt_score"),
                metacriticScore = r.num("metacritic_score"),
                awards = r.str("awards"),
                franchiseID = r.num("franchise_id"),
                franchiseName = r.str("franchise_name"),
                fetchedAt = r.str("fetched_at") ?: isoTime(System.currentTimeMillis()),
            )
        }

        private fun jsonNumber(d: Double?): JsonPrimitive = if (d == null) JsonNull else JsonPrimitive(d)

        /** The TMDB write: TMDB columns only, so it never touches what OMDb wrote. */
        fun toSupabaseRow(e: Enrichment): JsonObject = buildJsonObject {
            put("tmdb_id", e.tmdbID)
            put("media_type", e.mediaType)
            put("keywords", buildJsonArray { e.keywords.forEach { add(JsonPrimitive(it)) } })
            put("networks", buildJsonArray { e.networks.forEach { add(JsonPrimitive(it)) } })
            put("production_companies", buildJsonArray { e.productionCompanies.forEach { add(JsonPrimitive(it)) } })
            put("tmdb_genres", buildJsonArray { e.tmdbGenres.forEach { add(JsonPrimitive(it)) } })
            put("franchise_id", jsonNumber(e.franchiseID))
            put("franchise_name", e.franchiseName)
            put("fetched_at", e.fetchedAt)
        }

        /** The OMDb write: OMDb columns plus the key. */
        fun toOMDbRow(e: Enrichment): JsonObject = buildJsonObject {
            put("tmdb_id", e.tmdbID)
            put("media_type", e.mediaType)
            put("imdb_id", e.imdbID)
            put("imdb_rating", jsonNumber(e.imdbRating))
            put("imdb_votes", jsonNumber(e.imdbVotes))
            put("rt_score", jsonNumber(e.rtScore))
            put("metacritic_score", jsonNumber(e.metacriticScore))
            put("awards", e.awards)
        }

        // ── Pure: OMDb ───────────────────────────────────────────────────────

        private fun omdbValue(v: JsonElement?) = (v as? JsonPrimitive)?.takeIf { it.isString && it.content != "N/A" }?.content

        /** JavaScript's Number() of a string: whitespace trimmed, "" is 0, hex and Infinity read. NaN when it isn't a number. */
        internal fun jsNumber(raw: String): Double {
            val s = JsText.trim(raw)
            if (s.isEmpty()) return 0.0
            when (s) {
                "Infinity", "+Infinity" -> return Double.POSITIVE_INFINITY
                "-Infinity" -> return Double.NEGATIVE_INFINITY
            }
            val radix = when {
                s.startsWith("0x") || s.startsWith("0X") -> 16
                s.startsWith("0o") || s.startsWith("0O") -> 8
                s.startsWith("0b") || s.startsWith("0B") -> 2
                else -> 10
            }
            if (radix != 10) return s.substring(2).takeIf { it.isNotEmpty() }?.let { d -> d.toBigIntegerOrNull(radix)?.toDouble() } ?: Double.NaN
            return if (Regex("^[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?$").matches(s)) s.toDouble() else Double.NaN
        }

        /** JavaScript's parseInt(s, 10): leading whitespace, a sign, then as many digits as there are. */
        private fun jsParseInt(raw: String): Double {
            val s = JsText.trim(raw)
            val m = Regex("^[+-]?\\d+").find(s) ?: return Double.NaN
            return m.value.toBigInteger().toDouble()
        }

        /** OMDBService.parseResponse. Null for `{"Response":"False"}` (unknown id, or a quota error without the relay's 429). */
        fun parseOMDbResponse(json: JsonElement?): Enrichment? {
            val o = json.obj() ?: return null
            if ((o["Response"] as? JsonPrimitive)?.let { it.isString && it.content == "False" } == true) return null
            fun num(s: String?, f: (String) -> Double) = s?.let(f)?.takeIf { it.isFinite() }
            var rt: Double? = null
            for (r in (o["Ratings"] as? JsonArray) ?: JsonArray(emptyList())) {
                val ro = r.obj() ?: continue
                if (ro.str("Source") == "Rotten Tomatoes" && ro.str("Value") != null) {
                    rt = jsParseInt(ro.str("Value")!!.replaceFirst("%", "")).takeIf { it.isFinite() }
                    break
                }
            }
            return Enrichment(
                imdbRating = num(omdbValue(o["imdbRating"]), ::jsNumber),
                imdbVotes = num(omdbValue(o["imdbVotes"])) { jsNumber(it.replace(",", "")) },
                rtScore = rt,
                metacriticScore = num(omdbValue(o["Metascore"]), ::jsNumber),
                awards = omdbValue(o["Awards"]),
            )
        }

        fun isOMDbLimit(json: JsonElement?): Boolean =
            json.obj()?.str("Error")?.lowercase()?.contains("limit reached") == true

        /** MediaEnrichment.merging(omdb:): OMDb's five values over the TMDB record. */
        fun mergeOMDb(record: Enrichment, omdb: Enrichment, imdbID: String?) = record.copy(
            imdbID = record.imdbID ?: imdbID,
            imdbRating = omdb.imdbRating, imdbVotes = omdb.imdbVotes, rtScore = omdb.rtScore,
            metacriticScore = omdb.metacriticScore, awards = omdb.awards,
        )

        private fun needsOMDb(r: JsonObject?): Boolean {
            if (r == null) return false
            fun isNum(k: String) = (r[k] as? JsonPrimitive)?.let { !it.isString && it.doubleOrNull != null } == true
            return isNum("imdbRatingMin") || isNum("imdbVotesMin") || isNum("rtScoreMin") || isNum("metacriticMin") ||
                (r["wonOscar"] as? JsonPrimitive)?.let { !it.isString && it.booleanOrNull == true } == true
        }

        /** OMDBGate.gates(from:): one gate per channel with an OMDb rule, from its rules. */
        fun omdbGates(channelRules: List<JsonObject?>): List<Gate> = channelRules.filter(::needsOMDb).map { r ->
            fun lower(v: JsonElement?) = stringList(v).map { it.lowercase() }
            val type = (r!!["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            Gate(
                mediaType = when (type) { "movie" -> "movie"; "episode" -> "tv"; else -> null },
                keywords = LinkedHashSet(lower(r["keywords"]) + lower(r["keywordsRequireAll"])),
                genres = lower(r["genres"].obj()?.get("include")),
            )
        }

        /** OMDBQuota.isCandidate: some gate admits the media type plus a keyword or a genre. */
        fun isOMDbCandidate(mediaType: String?, keywords: List<String>, genres: List<String>, gates: List<Gate>): Boolean {
            val kw = keywords.map { it.lowercase() }
            val gs = genres.map { it.lowercase() }
            return gates.any { gate ->
                when {
                    gate.mediaType != null && gate.mediaType != mediaType -> false
                    gate.keywords.isEmpty() && gate.genres.isEmpty() -> true
                    kw.any { it in gate.keywords } -> true
                    else -> gate.genres.any { g -> gs.any { it.contains(g) } }
                }
            }
        }

        /** The server's genres per TMDB id, across the id's items. */
        fun genresByTMDB(items: List<MediaItem>): Map<String, Set<String>> {
            val out = LinkedHashMap<String, LinkedHashSet<String>>()
            for (item in items) {
                val id = item.tmdbID?.toString() ?: continue
                out.getOrPut(id) { LinkedHashSet() }.addAll(item.genres)
            }
            return out
        }

        /** omdbCandidates: unrated, with a valid IMDb id, and admitted by a gate. */
        fun omdbCandidates(work: List<WorkItem>, records: Map<String, Enrichment>, genresByID: Map<String, Set<String>>, gates: List<Gate>): List<OmdbCandidate> {
            if (gates.isEmpty()) return emptyList()
            val out = ArrayList<OmdbCandidate>()
            for (w in work) {
                val e = records[w.tmdbID] ?: continue
                if (e.imdbRating != null) continue
                val imdb = e.imdbID?.takeIf { IMDB_ID.matches(it) } ?: continue
                val genres = e.tmdbGenres + (genresByID[w.tmdbID] ?: emptySet())
                if (!isOMDbCandidate(e.mediaType, e.keywords, genres, gates)) continue
                out += OmdbCandidate(w.tmdbID, imdb, e)
            }
            return out
        }

        /** OMDBQuota.pick: at most `limit`, in random order (Fisher-Yates on a copy). */
        fun <T> pickOMDbLookups(list: List<T>, limit: Int, random: () -> Double): List<T> {
            val a = list.toMutableList()
            for (i in a.size - 1 downTo 1) {
                val j = Math.floor(random() * (i + 1)).toInt()
                val t = a[i]; a[i] = a[j]; a[j] = t
            }
            return a.take(maxOf(0, limit))
        }

        /** OMDb's daily quota resets at midnight UTC. */
        fun nextUTCMidnight(ms: Long): Long = Math.floorDiv(ms, 86_400_000L) * 86_400_000L + 86_400_000L

        /** One work item per TMDB id: episodes are tv, everything else movie; the first item wins. */
        fun workItems(items: List<Pair<String?, String>>): List<WorkItem> {
            val byId = LinkedHashMap<String, WorkItem>()
            for ((raw, type) in items) {
                val id = raw?.takeIf { it.isNotEmpty() && TMDB_ID.matches(it) } ?: continue
                byId.putIfAbsent(id, WorkItem(id, if (type == "episode") "tv" else "movie"))
            }
            return byId.values.toList()
        }

        /** Each item with its TMDB id's record attached (or left as it was). */
        fun attach(items: List<MediaItem>, records: Map<String, Enrichment>): List<MediaItem> =
            items.map { item -> item.tmdbID?.toString()?.let(records::get)?.let { item.copy(enrichment = it) } ?: item }

        /** Runs `fn` over `list`, at most `limit` at once. */
        private fun <T> concurrently(list: List<T>, limit: Int, fn: (T) -> Unit) {
            if (list.isEmpty()) return
            val pool = Executors.newFixedThreadPool(minOf(limit, list.size))
            try {
                pool.invokeAll(list.map { item -> Callable { runCatching { fn(item) } } }).forEach { it.get() }
            } finally {
                pool.shutdown()
            }
        }
    }
}
