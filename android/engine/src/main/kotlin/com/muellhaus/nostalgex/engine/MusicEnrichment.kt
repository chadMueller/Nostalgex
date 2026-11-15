package com.muellhaus.nostalgex.engine

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URLEncoder

/**
 * What a music video's title and artist can be sent to MusicBrainz and Deezer for, and what comes back (#319): a port of the
 * Apple TV's `MusicBrainzService`, `DeezerService`, `MusicEnrichmentService` and `MusicVideoEnrichment`
 * (appletv/integration-1115), with the same order, ranking, genre vocabulary and cache rules.
 *
 * What is sent, and only this: for a music video that has no useful genre, its song title and artist (parsed from the
 * title, or the server's artist), to musicbrainz.org (the recording search, then the recording's tags by its MusicBrainz id) and,
 * if MusicBrainz gave no genre, to api.deezer.com (a track search, then the album's genres by its album id). Nothing else
 * from the library or the account goes with it: no server address, no token, no file path. The caller sends a User-Agent
 * of "Nostalgex/<version> (https://www.nostalgex.app)" and no other identity.
 */
@Serializable
data class MusicVideoEnrichment(
    val ratingKey: String,
    /** The song/recording title used for lookup (may differ from the server's title when parsed). */
    val recordingTitle: String,
    val artist: String? = null,
    /** MusicBrainz recording MBID when a match was found. */
    val musicBrainzID: String? = null,
    /** Genres for channel matching, mapped from MusicBrainz tags and Deezer's album genres. */
    val genres: List<String> = emptyList(),
    val releaseYear: Int? = null,
    val fetchedAtMs: Long,
    val deezerID: Int? = null,
    /** When Deezer was last consulted for this row, matched or not: it stops the same dead lookup repeating. */
    val deezerCheckedAtMs: Long? = null,
) {
    val hasUsefulGenres: Boolean get() = genres.any { MusicEnrichmentService.isUsefulGenre(it) }
}

/** The answer of a request, or an exception when it didn't give one (a non-200, a timeout). The caller owns the HTTP, the headers and the pacing. */
typealias MusicFetch = suspend (url: String) -> String

private val json = Json { ignoreUnknownKeys = true }

private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

private fun JsonElement?.obj(): JsonObject? = this as? JsonObject
private fun JsonElement?.arr(): JsonArray? = this as? JsonArray
private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
private fun JsonElement?.int(): Int? = (this as? JsonPrimitive)?.intOrNull

/** MusicBrainz recording search and lookup (free API, one request a second; the caller paces them). */
class MusicBrainzClient(private val fetch: MusicFetch) {
    data class RecordingMatch(val mbid: String, val recordingTitle: String, val artist: String?, val genres: List<String>, val releaseYear: Int?)

    private data class SearchHit(val mbid: String, val title: String, val artist: String?, val score: Int, val year: Int?)

    suspend fun resolveRecording(title: String, artist: String?, year: Int?): RecordingMatch? {
        val song = stripYearSuffix(title)
        if (song.isEmpty()) return null
        val hit = searchBestRecording(song, artist, year) ?: return null
        lookupRecording(hit.mbid)?.let { return it }
        return RecordingMatch(hit.mbid, hit.title, hit.artist, emptyList(), hit.year)
    }

    private suspend fun searchBestRecording(songTitle: String, artist: String?, year: Int?): SearchHit? {
        val parts = mutableListOf("recording:\"${escapeQuery(songTitle)}\"", "video:true")
        if (!artist.isNullOrEmpty()) parts += "artist:\"${escapeQuery(artist)}\""
        val query = parts.joinToString(" AND ")
        val body = json.parseToJsonElement(fetch("$BASE/recording?query=${enc(query)}&fmt=json&limit=10")).obj() ?: return null
        val recordings = body["recordings"].arr()?.takeIf { it.isNotEmpty() } ?: return null
        val songLower = songTitle.lowercase()
        var best: Pair<SearchHit, Int>? = null
        for (recEl in recordings) {
            val rec = recEl.obj() ?: continue
            val mbid = rec["id"].str() ?: continue
            val title = rec["title"].str() ?: continue
            val score = rec["score"].int() ?: 0
            val artistName = primaryArtistName(rec)
            val recYear = firstReleaseYear(rec)
            var rank = score
            val titleLower = title.lowercase()
            if (titleLower == songLower) rank += 40
            else if (titleLower.contains(songLower) || songLower.contains(titleLower)) rank += 20
            if (artist != null && artistName != null && artistName.lowercase().contains(artist.lowercase())) rank += 25
            if (year != null && recYear != null && year == recYear) rank += 15
            else if (year != null && recYear != null && kotlin.math.abs(year - recYear) <= 1) rank += 8
            val hit = SearchHit(mbid, title, artistName, score, recYear)
            if (best == null || rank > best.second) best = hit to rank
        }
        return best?.first
    }

    private suspend fun lookupRecording(mbid: String): RecordingMatch? {
        val body = json.parseToJsonElement(fetch("$BASE/recording/${enc(mbid)}?inc=artist-credits+tags+releases&fmt=json")).obj() ?: return null
        val title = body["title"].str() ?: return null
        val tags = body["tags"].arr()?.mapNotNull { it.obj()?.get("name").str() }?.filter { it.isNotEmpty() } ?: emptyList()
        return RecordingMatch(mbid, title, primaryArtistName(body), mapTagsToChannelGenres(tags), firstReleaseYear(body))
    }

    private fun primaryArtistName(o: JsonObject): String? {
        for (credit in o["artist-credit"].arr() ?: return null) {
            val c = credit.obj() ?: continue
            c["name"].str()?.takeIf { it.isNotEmpty() }?.let { return it }
            c["artist"].obj()?.get("name").str()?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        return null
    }

    private fun firstReleaseYear(o: JsonObject): Int? {
        for (release in o["releases"].arr() ?: return null) {
            val date = release.obj()?.get("date").str() ?: continue
            if (date.length >= 4) date.take(4).toIntOrNull()?.let { return it }
        }
        return null
    }

    private fun escapeQuery(s: String) = s.replace("\"", "")

    companion object {
        private const val BASE = "https://musicbrainz.org/ws/2"
        const val HOST = "musicbrainz.org"

        /** Strips a trailing " (YYYY)" a server often appends. */
        fun stripYearSuffix(title: String) = title.replace(Regex(" \\(\\d{4}\\)$"), "").trim()

        /** MusicBrainz's tag vocabulary mapped to the genres channels.json rules match on. */
        fun mapTagsToChannelGenres(tags: List<String>): List<String> {
            val out = mutableListOf<String>()
            fun add(g: String) { if (out.none { it.equals(g, ignoreCase = true) }) out += g }
            for (tag in tags) {
                val t = tag.lowercase()
                if (t.contains("pop") && !t.contains("k-pop")) add("Pop")
                if (t.contains("rock")) {
                    if (t.contains("alternative") || t.contains("indie")) { add("Alternative Rock"); add("Indie Rock") }
                    else if (t.contains("hard rock") || t.contains("hard-rock")) add("Hard Rock")
                    else if (t.contains("classic rock")) add("Classic Rock")
                    else add("Rock")
                }
                if (t.contains("country")) { add("Country"); if (t.contains("rock")) add("Country Rock") }
                if (t.contains("hip hop") || t.contains("hip-hop")) { add("Hip-Hop"); add("Hip Hop") }
                if (t == "rap" || t.contains("gangsta")) add("Rap")
                if (t.contains("r&b") || t.contains("rhythm and blues") || t == "soul") { add("R&B"); add("Soul") }
                if (t.contains("acoustic")) add("Acoustic")
                if (t.contains("electronic") || t.contains("dance") || t.contains("edm") || t.contains("house") || t.contains("techno") || t.contains("trance")) add("Dance")
                if (t.contains("metal")) { add("Metal"); add("Hard Rock"); add("Rock") }
                if (t.contains("punk")) { add("Rock"); add("Alternative") }
                if (t.contains("folk")) add("Acoustic")
                if (t.contains("latin") || t.contains("reggaeton") || t.contains("reggaetón")) add("Latin")
                if (t.contains("funk")) add("Funk")
                if (t.contains("disco")) add("Disco")
            }
            return out
        }
    }
}

/** Deezer track search and album lookup (free, no key). Genres come from the album, which is what Deezer tags. */
class DeezerClient(private val fetch: MusicFetch) {
    data class TrackMatch(val trackID: Int, val albumID: Int, val title: String, val artist: String, val rawGenres: List<String>, val genres: List<String>, val releaseYear: Int?)
    data class SearchHit(val trackID: Int, val albumID: Int, val title: String, val artist: String)

    /** Search with the artist first, then the bare song when that finds nothing; one album fetch for genres. */
    suspend fun resolve(song: String, artist: String?): TrackMatch? {
        val s = song.trim()
        if (s.isEmpty()) return null
        val queries = buildList { if (!artist.isNullOrEmpty()) add("$artist $s"); add(s) }
        for (query in queries) {
            val pick = bestHit(search(query), artist) ?: continue
            val (genres, year) = album(pick.albumID)
            return TrackMatch(pick.trackID, pick.albumID, pick.title, pick.artist, genres, mapGenres(genres), year)
        }
        return null
    }

    private suspend fun search(query: String): List<SearchHit> {
        val rows = json.parseToJsonElement(fetch("$BASE/search?q=${enc(query)}&limit=5")).obj()?.get("data").arr() ?: return emptyList()
        return rows.mapNotNull { row ->
            val o = row.obj() ?: return@mapNotNull null
            val id = o["id"].int() ?: return@mapNotNull null
            val title = o["title"].str() ?: return@mapNotNull null
            val artist = o["artist"].obj()?.get("name").str() ?: return@mapNotNull null
            val albumID = o["album"].obj()?.get("id").int() ?: return@mapNotNull null
            SearchHit(id, albumID, title, artist)
        }
    }

    private suspend fun album(id: Int): Pair<List<String>, Int?> {
        val o = json.parseToJsonElement(fetch("$BASE/album/$id")).obj() ?: throw IllegalStateException("Deezer album $id did not decode")
        val genres = o["genres"].obj()?.get("data").arr()?.mapNotNull { it.obj()?.get("name").str() } ?: emptyList()
        val year = o["release_date"].str()?.take(4)?.toIntOrNull()
        return genres to year
    }

    companion object {
        private const val BASE = "https://api.deezer.com"
        const val HOST = "api.deezer.com"

        /** Deezer ranks by popularity; with an artist hint, prefer the first hit whose artist shares a word with it. */
        fun bestHit(hits: List<SearchHit>, artistHint: String?): SearchHit? {
            val first = hits.firstOrNull() ?: return null
            val hint = artistHint?.lowercase()?.takeIf { it.isNotEmpty() } ?: return first
            val words = hint.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.length > 2 }.toSet()
            if (words.isEmpty()) return first
            return hits.firstOrNull { hit -> hit.artist.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.any { it in words } } ?: first
        }

        /** Deezer's album genres mapped to the names channels.json rules match on ("Films/Games" and "Kids" are deliberately unmapped). */
        fun mapGenres(raw: List<String>): List<String> {
            val out = mutableListOf<String>()
            fun add(vararg names: String) { for (g in names) if (out.none { it.equals(g, ignoreCase = true) }) out += g }
            for (name in raw) {
                val g = name.lowercase()
                when (g) {
                    "pop", "international pop", "indie pop", "k-pop", "j-pop", "latin pop" -> {
                        add("Pop"); if (g == "indie pop") add("Alternative"); if (g == "latin pop") add("Latin")
                    }
                    "rock" -> add("Rock")
                    "hard rock" -> add("Hard Rock", "Rock")
                    "classic rock" -> add("Classic Rock", "Rock")
                    "indie rock", "indie rock/rock pop" -> add("Indie Rock", "Alternative", "Rock")
                    "alternative" -> add("Alternative")
                    "punk" -> add("Punk", "Rock", "Alternative")
                    "metal" -> add("Metal", "Hard Rock", "Rock")
                    "rap/hip hop" -> add("Hip-Hop", "Hip Hop", "Rap")
                    "r&b" -> add("R&B")
                    "soul & funk" -> add("Soul", "Funk")
                    "disco" -> add("Disco", "Funk")
                    "dance", "dancefloor" -> add("Dance", "Electronic")
                    "electro", "dubstep", "chill out/trip-hop/lounge", "electro pop/electro rock" -> {
                        add("Electronic", "Dance"); if (g == "electro pop/electro rock") add("Pop")
                    }
                    "techno/house" -> add("House", "Techno", "Electronic", "Dance")
                    "country" -> add("Country")
                    "latin music", "brazilian music" -> add("Latin")
                    "reggaeton" -> add("Reggaeton", "Latin")
                    "reggae" -> add("Reggae")
                    "folk" -> add("Acoustic", "Folk")
                    "jazz" -> add("Jazz")
                    "blues" -> add("Blues")
                    else -> Unit
                }
            }
            return out
        }
    }
}

/** Resolves music videos through MusicBrainz and then Deezer and keeps what they said (the Apple TV's MusicEnrichmentService). */
class MusicEnrichmentService(
    private val musicBrainz: MusicBrainzClient,
    private val deezer: DeezerClient,
    private val log: (String) -> Unit = {},
) {
    val cache = LinkedHashMap<String, MusicVideoEnrichment>()

    /**
     * Reads every music video that isn't settled and asks for it, in the Apple TV's order: rows MusicBrainz already named but
     * that never got a genre go to Deezer alone (no second MusicBrainz round trip), the rest to MusicBrainz and then, for
     * a row with no useful genre, Deezer. A lookup that fails or finds nothing is kept as a row stamped with the time Deezer
     * was asked, so the same dead lookup is not made again for 90 days. [onSave] is called with the cache as it grows, every
     * [SAVE_EVERY] rows and at the end, so a killed app keeps what it did. Returns whether the cache changed.
     */
    suspend fun enrich(items: List<MediaItem>, now: () -> Long, onSave: (Map<String, MusicVideoEnrichment>) -> Unit, isActive: () -> Boolean = { true }): Boolean {
        val candidates = items.filter(::isMusicVideo)
        if (candidates.isEmpty()) return false
        val work = ArrayList<MediaItem>()
        val genrePass = ArrayList<MediaItem>()
        for (item in candidates) {
            val cached = cache[key(item)]
            if (cached != null && isSettled(cached, now())) continue
            if (cached != null && needsOnlyGenres(cached)) { genrePass += item; continue }
            work += item
        }
        var changed = false
        var sinceSave = 0
        fun touched() { changed = true; if (++sinceSave >= SAVE_EVERY) { sinceSave = 0; onSave(cache) } }
        if (genrePass.isNotEmpty()) {
            log("MUSIC genre pass for ${genrePass.size} cached music videos via Deezer")
            for (item in genrePass) {
                if (!isActive()) return changed.also { if (it) onSave(cache) }
                cache[key(item)]?.let { cache[key(item)] = withDeezerGenres(it, item, now()); touched() }
            }
        }
        if (work.isNotEmpty()) {
            log("MUSIC resolving ${work.size} music videos via MusicBrainz, Deezer for genres")
            for (item in work) {
                if (!isActive()) break
                resolve(item, now())?.let { cache[key(item)] = it; touched() }
            }
        }
        if (changed) onSave(cache)
        return changed
    }

    private suspend fun resolve(item: MediaItem, now: Long): MusicVideoEnrichment? {
        val parsed = MusicTitle.parseTitle(item.title)
        val song = parsed.song
        val artistHint = item.artist ?: parsed.artist
        var row: MusicVideoEnrichment? = null
        try {
            musicBrainz.resolveRecording(song, artistHint, item.year)?.let { m ->
                row = MusicVideoEnrichment(item.ratingKey, m.recordingTitle, m.artist ?: artistHint, m.mbid, mergeGenres(item.genres, m.genres), m.releaseYear, now)
            }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
            log("MUSIC MusicBrainz failed for one video: ${e.message}")
        }
        var current = row ?: MusicVideoEnrichment(item.ratingKey, song, artistHint, null, item.genres, null, now)
        if (!current.hasUsefulGenres) current = withDeezerGenres(current, item, now)
        return current
    }

    /** One Deezer round trip for a row that has a name but no genre. Fills genres (and the artist when the row had none); always stamps the time. */
    private suspend fun withDeezerGenres(row: MusicVideoEnrichment, item: MediaItem, now: Long): MusicVideoEnrichment {
        val parsed = MusicTitle.parseTitle(item.title)
        val song = row.recordingTitle.ifEmpty { parsed.song }
        val artist = row.artist ?: parsed.artist
        var genres = row.genres
        var deezerID = row.deezerID
        var resolvedArtist = row.artist
        try {
            deezer.resolve(song, artist)?.let { m ->
                genres = mergeGenres(genres, m.genres)
                deezerID = m.trackID
                if (resolvedArtist == null) resolvedArtist = m.artist
            }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
            log("MUSIC Deezer failed for one video: ${e.message}")
        }
        // Deezer's year is the album's (remasters, compilations), wrong by years: it never becomes the release year.
        return row.copy(artist = resolvedArtist, genres = genres, deezerID = deezerID, deezerCheckedAtMs = now)
    }

    /**
     * The items with their cached rows merged in, for the guide and the channel rules: the recording's title, the artist, the
     * genres, and the year by [MusicYear]'s trust order (MusicBrainz's first release, then the server's year when it is
     * plausible). A music video with no row yet still gets the trusted year, so a 1970 or date-added year from the server never
     * decides a decade channel.
     */
    fun apply(items: List<MediaItem>, thisYear: Int = java.time.Year.now().value): List<MediaItem> = items.map { item ->
        if (!isMusicVideo(item)) return@map item
        val row = cache[key(item)]
        val year = MusicYear.resolve(null, row?.releaseYear, item.year, thisYear)
        if (row == null) return@map if (year == item.year) item else item.copy(year = year)
        item.copy(
            title = row.recordingTitle.trim().ifEmpty { item.title },
            artist = row.artist ?: item.artist,
            genres = mergeGenres(item.genres, row.genres),
            year = year,
        )
    }

    companion object {
        const val SAVE_EVERY = 20
        private const val NINETY_DAYS_MS = 90L * 24 * 3600 * 1000

        fun isMusicVideo(item: MediaItem) = item.type != "episode" && item.librarySource == "musicVideo"

        /** A server key is only unique on one server, so the row's key carries the server's address. */
        fun key(item: MediaItem) = "${item.serverUrl.orEmpty()}#${item.ratingKey}"

        fun isUsefulGenre(g: String): Boolean {
            val l = g.lowercase()
            return !l.contains("music video") && l != "music" && l != "musical"
        }

        /** Nothing left to ask anyone: it has genres, or Deezer was already consulted. */
        fun isSettled(row: MusicVideoEnrichment, nowMs: Long): Boolean {
            if (nowMs - row.fetchedAtMs >= NINETY_DAYS_MS) return false
            return row.hasUsefulGenres || row.deezerCheckedAtMs != null
        }

        /** Named (by MusicBrainz or the title parser) but genreless and never shown to Deezer. */
        fun needsOnlyGenres(row: MusicVideoEnrichment) = !row.hasUsefulGenres && row.deezerCheckedAtMs == null && (row.artist != null || row.musicBrainzID != null)

        fun mergeGenres(a: List<String>, b: List<String>): List<String> {
            val out = a.toMutableList()
            for (g in b) if (out.none { it.equals(g, ignoreCase = true) }) out += g
            return out
        }
    }
}
