package com.muellhaus.nostalgex.plex

import com.muellhaus.nostalgex.engine.DailyManifest
import com.muellhaus.nostalgex.engine.MediaItem
import com.muellhaus.nostalgex.plex.PlexClient.Companion.long
import com.muellhaus.nostalgex.plex.PlexClient.Companion.str
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import android.util.Log

/**
 * Reads a Plex server into programmes, in library order: a port of plex-tuner.html
 * scanOnePlexServer and fetchPlexSectionPaged. The order is the server's, never shuffled, since
 * the schedule's running order depends on it.
 *
 * Not yet ported: the Windows-1252 repair of bad title bytes (PlexUTF8Repair) and the
 * MusicBrainz "Artist - Title" split for music videos.
 */
class PlexLibrary(private val client: PlexClient) {
    fun interface Progress {
        fun update(text: String, itemsSoFar: Int)
    }

    suspend fun scan(server: PlexServer, progress: Progress, baseCount: Int = 0): List<MediaItem> {
        val sections = client.get(server, "/library/sections")["MediaContainer"]?.jsonObject?.array("Directory") ?: emptyList()
        val out = ArrayList<MediaItem>()
        for (section in sections) {
            val title = section.str("title") ?: ""
            val type = section.str("type") ?: ""
            try {
                val items = fetchSectionPaged(server, section.str("key")!!) { loaded, total ->
                    progress.update("$title ($loaded${total?.let { "/$it" } ?: ""})", baseCount + out.size + loaded)
                }
                val isMusicVideoSection = MUSIC_VIDEO_SECTION.containsMatchIn(title.trim())
                if (type == "show") {
                    var episodes = 0
                    for (batch in items.chunked(5)) {
                        val results = coroutineScope { batch.map { show -> async { showEpisodes(server, show, isMusicVideoSection) } }.awaitAll() }
                        results.forEach { out.addAll(it); episodes += it.size }
                        progress.update("$title · $episodes eps", baseCount + out.size)
                    }
                } else {
                    items.mapNotNullTo(out) { movieItem(server, it, type, isMusicVideoSection) }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to fetch section $title", e)
            }
        }
        return out
    }

    private suspend fun fetchSectionPaged(server: PlexServer, key: String, onPage: (Int, Int?) -> Unit): List<JsonObject> {
        val all = ArrayList<JsonObject>()
        var start = 0
        while (true) {
            // includeGuids=1 puts tmdb:// ids on each item, for the membership manifest.
            val container = client.get(server, "/library/sections/$key/all?includeGuids=1&X-Plex-Container-Start=$start&X-Plex-Container-Size=$PAGE_SIZE")["MediaContainer"]?.jsonObject
                ?: JsonObject(emptyMap())
            val page = container.array("Metadata")
            all.addAll(page)
            val total = container.long("totalSize")?.toInt()
            onPage(all.size, total)
            if (page.isEmpty()) break
            if (total != null && all.size >= total) break
            if (total == null && page.size < PAGE_SIZE) break
            start += PAGE_SIZE
        }
        return all
    }

    private suspend fun showEpisodes(server: PlexServer, show: JsonObject, isMusicVideoSection: Boolean): List<MediaItem> {
        val showGenres = show.array("Genre").mapNotNull { it.str("tag") }
        // Episodes take the show's TMDB id, as PlexMediaItem does on tvOS.
        val showTmdb = tmdbId(show, false)
        return try {
            val episodes = client.get(server, "/library/metadata/${show.str("ratingKey")}/allLeaves")["MediaContainer"]?.jsonObject?.array("Metadata") ?: emptyList()
            episodes.mapNotNull { ep ->
                val minutes = DailyManifest.minutesFromPlexMs(ep.long("duration"))
                if (minutes <= 0) return@mapNotNull null
                val media = pickBestVersion(ep.array("Media"))
                MediaItem(
                    ratingKey = ep.str("ratingKey")!!,
                    title = show.str("title") ?: "Unknown",
                    type = "episode",
                    duration = minutes,
                    addedAt = ep.long("addedAt") ?: 0,
                    episodeTitle = ep.str("title") ?: "",
                    seTag = seTag(ep),
                    summary = ep.str("summary")?.ifEmpty { null } ?: show.str("summary") ?: "",
                    year = show.long("year")?.toInt(),
                    originallyAvailableAt = ep.str("originallyAvailableAt") ?: show.str("originallyAvailableAt"),
                    contentRating = show.str("contentRating")?.ifEmpty { null } ?: ep.str("contentRating") ?: "",
                    genres = showGenres,
                    rating = show.num("rating"),
                    userRating = show.num("userRating"),
                    viewCount = ep.long("viewCount")?.toInt() ?: 0,
                    studio = show.str("studio") ?: "",
                    librarySource = if (isMusicVideoSection) "musicVideo" else "tv",
                    tmdbID = showTmdb ?: tmdbId(ep, true),
                    partKey = media?.array("Part")?.firstOrNull()?.str("key"),
                    container = media?.str("container"),
                    videoCodec = media?.str("videoCodec")?.lowercase(),
                    audioCodec = media?.str("audioCodec")?.lowercase(),
                    bitrate = media?.long("bitrate")?.toInt()?.takeIf { it > 0 },
                    serverUrl = server.url,
                    serverToken = server.token,
                    thumb = ep.str("thumb") ?: show.str("thumb"),
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to fetch episodes for ${show.str("title")}", e)
            emptyList()
        }
    }

    private fun movieItem(server: PlexServer, item: JsonObject, sectionType: String, isMusicVideoSection: Boolean): MediaItem? {
        val genres = item.array("Genre").mapNotNull { it.str("tag") }.toMutableList()
        if (isMusicVideoSection && genres.none { MUSIC.containsMatchIn(it) }) genres.add("Music Video")
        val minutes = DailyManifest.minutesFromPlexMs(item.long("duration"))
        if (minutes <= 0) return null
        // A dedicated music-video library, or a short item tagged Music (10-minute cap keeps out musicals).
        val isMusicVideo = isMusicVideoSection || (minutes <= 10 && genres.any { MUSIC.containsMatchIn(it) })
        val media = pickBestVersion(item.array("Media"))
        return MediaItem(
            ratingKey = item.str("ratingKey")!!,
            title = item.str("title") ?: "Unknown",
            type = if (sectionType == "show") "episode" else sectionType,
            duration = minutes,
            addedAt = item.long("addedAt") ?: 0,
            summary = item.str("summary") ?: "",
            year = item.long("year")?.toInt(),
            originallyAvailableAt = item.str("originallyAvailableAt"),
            contentRating = item.str("contentRating") ?: "",
            genres = genres,
            rating = item.num("rating"),
            userRating = item.num("userRating"),
            viewCount = item.long("viewCount")?.toInt() ?: 0,
            studio = item.str("studio") ?: "",
            librarySource = if (isMusicVideo) "musicVideo" else if (sectionType == "movie") "movie" else sectionType,
            tmdbID = tmdbId(item, false),
            partKey = media?.array("Part")?.firstOrNull()?.str("key"),
            container = media?.str("container"),
            videoCodec = media?.str("videoCodec")?.lowercase(),
            audioCodec = media?.str("audioCodec")?.lowercase(),
            bitrate = media?.long("bitrate")?.toInt()?.takeIf { it > 0 },
            serverUrl = server.url,
            serverToken = server.token,
            thumb = item.str("thumb"),
        )
    }

    companion object {
        private const val TAG = "Nostalgex"
        private const val PAGE_SIZE = 300
        private val MUSIC_VIDEO_SECTION = Regex("music.?video|^music$|^mvs?$", RegexOption.IGNORE_CASE)
        private val MUSIC = Regex("music", RegexOption.IGNORE_CASE)
        private val TMDB = Regex("tmdb://(\\d+)")

        private fun JsonObject.array(key: String): List<JsonObject> =
            (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

        private fun JsonObject.num(key: String): Double = (this[key] as? JsonPrimitive)?.doubleOrNull ?: 0.0

        /** "S01E04" from the season and episode numbers, as the web tuner's `sNum + eNum`. */
        private fun seTag(ep: JsonObject): String? {
            val s = ep.long("parentIndex")?.takeIf { it > 0 }?.let { "S%02d".format(it) } ?: ""
            val e = ep.long("index")?.takeIf { it > 0 }?.let { "E%02d".format(it) } ?: ""
            return (s + e).ifEmpty { null }
        }

        /** `tmdb://456` in the Guid array or an agent guid, as parseTmdbIdFromPlex. */
        fun tmdbId(raw: JsonObject, isEpisode: Boolean): Long? {
            val candidates = ArrayList<String>()
            raw.array("Guid").mapNotNullTo(candidates) { it.str("id") }
            raw.str("guid")?.let(candidates::add)
            if (isEpisode) {
                raw.str("grandparentGuid")?.let(candidates::add)
                raw.str("parentGuid")?.let(candidates::add)
            }
            return candidates.firstNotNullOfOrNull { TMDB.find(it)?.groupValues?.get(1)?.toLongOrNull() }
        }

        /** The highest bitrate version, then the tallest; the first when none has a bitrate. */
        fun pickBestVersion(versions: List<JsonObject>): JsonObject? {
            if (versions.isEmpty()) return null
            if (versions.none { it.long("bitrate") != null }) return versions[0]
            return versions.reduce { best, v ->
                val bb = best.long("bitrate") ?: -1
                val bv = v.long("bitrate") ?: -1
                if (bv != bb) (if (bv > bb) v else best)
                else if (resolutionHeight(v.str("videoResolution")) > resolutionHeight(best.str("videoResolution"))) v else best
            }
        }

        private fun resolutionHeight(res: String?): Int {
            if (res.isNullOrEmpty()) return 0
            val s = res.lowercase()
            s.substringAfterLast('x').takeWhile { it.isDigit() }.toIntOrNull()?.let { return it }
            return when {
                "4k" in s -> 2160
                "1080" in s -> 1080
                "720" in s -> 720
                else -> 0
            }
        }
    }
}
