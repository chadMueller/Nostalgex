package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.net.URLEncoder

/**
 * A Jellyfin or Emby library read into programmes, in library order: plex-tuner.html's
 * fetchJellyfinLibraryFromServer (JellyfinAPIService and EmbyAPIService on the Apple TV), held
 * to its answers by MediaBrowserScanTest over roku/tests/fixtures/mediabrowser-server.json.
 * Both servers speak the MediaBrowser API; where they differ, `backend` says which.
 */
class MediaBrowserLibrary(
    private val fetch: Fetch,
    private val userId: String,
    /** "jellyfin" or "emby". */
    var backend: String,
) {
    /** One GET relative to the server, answered with its status and JSON (null on an error status). */
    fun interface Fetch {
        fun get(path: String): Pair<Int, JsonElement?>
    }

    fun interface Progress {
        fun update(text: String, itemsSoFar: Int)
    }

    /** Set when a server saved as Jellyfin answered as Emby (adoptMediaBrowserKind). */
    var adoptedEmby = false
        private set

    fun scan(progress: Progress = Progress { _, _ -> }): List<MediaItem> {
        var (status, views) = fetch.get(userViewsPath(backend, userId))
        // An Emby server still saved as Jellyfin: Emby answers /UserViews with a 404.
        if (status == 404 && backend == "jellyfin") {
            val emby = fetch.get(userViewsPath("emby", userId))
            if (emby.first in 200..299) {
                backend = "emby"
                adoptedEmby = true
                views = emby.second
            }
        }
        val viewList = (views as? JsonObject)?.arr("Items") ?: emptyList()
        val out = ArrayList<MediaItem>()
        for (view in viewList) {
            val ct = view.str("CollectionType")?.lowercase() ?: ""
            val type = when (ct) {
                "tvshows" -> "show"
                "musicvideos" -> "musicvideo"
                else -> "movie"
            }
            val isMusicVideoSection = type == "musicvideo"
            val name = view.str("Name") ?: "Library"
            progress.update(name, out.size)
            try {
                if (type == "show") {
                    for (show in fetchItems(view.str("Id") ?: "", "Series")) {
                        val showGenres = show.strings("Genres")
                        val showTmdb = tmdbFromProviderIds(show.obj("ProviderIds"))
                        val episodes = try { fetchItems(show.str("Id") ?: "", "Episode") } catch (e: Exception) { emptyList() }
                        for (ep in episodes) {
                            val minutes = DailyManifest.minutesFromTicks(ep.long("RunTimeTicks"))
                            if (minutes <= 0) continue
                            val mi = mediaInfo(ep)
                            val s = ep.long("ParentIndexNumber")?.takeIf { it != 0L }?.let { "S%02d".format(it) } ?: ""
                            val e = ep.long("IndexNumber")?.takeIf { it != 0L }?.let { "E%02d".format(it) } ?: ""
                            out += MediaItem(
                                ratingKey = ep.str("Id") ?: "",
                                title = show.str("Name")?.ifEmpty { null } ?: "Unknown",
                                type = "episode",
                                duration = minutes,
                                addedAt = DailyManifest.unixSecondsFromISO(ep.str("DateCreated")),
                                episodeTitle = ep.str("Name") ?: "",
                                seTag = (s + e).ifEmpty { null },
                                summary = ep.str("Overview")?.ifEmpty { null } ?: show.str("Overview") ?: "",
                                year = show.long("ProductionYear")?.toInt()?.takeIf { it != 0 },
                                originallyAvailableAt = (ep.str("PremiereDate")?.ifEmpty { null } ?: show.str("PremiereDate")?.ifEmpty { null })?.take(10),
                                contentRating = show.str("OfficialRating")?.ifEmpty { null } ?: ep.str("OfficialRating") ?: "",
                                genres = showGenres,
                                rating = show.num("CommunityRating"),
                                viewCount = ep.obj("UserData")?.long("PlayCount")?.toInt() ?: 0,
                                studio = show.arr("Studios").firstOrNull()?.str("Name") ?: "",
                                librarySource = if (isMusicVideoSection) "musicVideo" else "tv",
                                tmdbID = showTmdb,
                                doviProfile = mi.doviProfile,
                                partKey = mi.msid,
                                container = mi.container,
                                videoCodec = mi.videoCodec,
                                audioCodec = mi.audioCodec,
                                bitrate = mi.bitrate,
                            )
                        }
                        progress.update("$name · ${out.size}", out.size)
                    }
                } else {
                    for (jf in fetchItems(view.str("Id") ?: "", "Movie")) {
                        val genres = jf.strings("Genres").toMutableList()
                        if (isMusicVideoSection && genres.none { MUSIC.containsMatchIn(it) }) genres += "Music Video"
                        val minutes = DailyManifest.minutesFromTicks(jf.long("RunTimeTicks"))
                        if (minutes <= 0) continue
                        // A music-video library, or a short item tagged Music (10 minutes keeps musicals out).
                        val isMusicVideo = isMusicVideoSection || (minutes <= 10 && genres.any { MUSIC.containsMatchIn(it) })
                        val mi = mediaInfo(jf)
                        var title = jf.str("Name")?.ifEmpty { null } ?: "Unknown"
                        var artist: String? = null
                        if (isMusicVideo) {
                            val (song, a) = MusicTitle.musicVideo(title, jf.str("parentTitle"), jf.str("grandparentTitle"))
                            title = song
                            artist = a
                        }
                        out += MediaItem(
                            ratingKey = jf.str("Id") ?: "",
                            title = title,
                            type = "movie",
                            duration = minutes,
                            addedAt = DailyManifest.unixSecondsFromISO(jf.str("DateCreated")),
                            artist = artist,
                            summary = jf.str("Overview") ?: "",
                            year = jf.long("ProductionYear")?.toInt()?.takeIf { it != 0 },
                            contentRating = jf.str("OfficialRating") ?: "",
                            genres = genres,
                            rating = jf.num("CommunityRating"),
                            viewCount = jf.obj("UserData")?.long("PlayCount")?.toInt() ?: 0,
                            studio = jf.arr("Studios").firstOrNull()?.str("Name") ?: "",
                            librarySource = if (isMusicVideo) "musicVideo" else "movie",
                            tmdbID = tmdbFromProviderIds(jf.obj("ProviderIds")),
                            doviProfile = mi.doviProfile,
                            partKey = mi.msid,
                            container = mi.container,
                            videoCodec = mi.videoCodec,
                            audioCodec = mi.audioCodec,
                            bitrate = mi.bitrate,
                        )
                    }
                    progress.update(name, out.size)
                }
            } catch (e: Exception) {
                // One library that fails leaves the others, as the web tuner's per-view catch.
            }
        }
        return out
    }

    /** Every item of a type under a parent, 200 at a time, with the fields the channel rules read. */
    private fun fetchItems(parentId: String, types: String): List<JsonObject> {
        val all = ArrayList<JsonObject>()
        var start = 0
        while (true) {
            val path = "/Items?userId=${enc(userId)}&ParentId=${enc(parentId)}&Recursive=true&IncludeItemTypes=$types" +
                "&Fields=ProviderIds,Overview,Genres,Studios,MediaSources,ProductionYear,PremiereDate,DateCreated,UserData" +
                "&StartIndex=$start&Limit=200&SortBy=SortName"
            val (status, body) = fetch.get(path)
            if (status !in 200..299) throw IllegalStateException("HTTP $status for items under $parentId")
            val d = body as? JsonObject ?: JsonObject(emptyMap())
            val items = d.arr("Items")
            all += items
            val total = d.long("TotalRecordCount")?.toInt() ?: all.size
            start += items.size
            if (items.isEmpty() || all.size >= total) break
        }
        return all
    }

    private data class MediaInfo(
        val msid: String?, val container: String?, val videoCodec: String?, val audioCodec: String?, val doviProfile: Int?, val bitrate: Int,
    )

    /** The best source (highest bitrate, then tallest) and what plays from it. */
    private fun mediaInfo(jf: JsonObject): MediaInfo {
        val sources = jf.arr("MediaSources")
        val src = pickBestVersion(sources)
        val streams = src?.arr("MediaStreams") ?: emptyList()
        val v = streams.firstOrNull { it.str("Type") == "Video" }
        val a = streams.firstOrNull { it.str("Type") == "Audio" }
        return MediaInfo(
            msid = src?.str("Id"),
            container = src?.str("Container")?.ifEmpty { null },
            videoCodec = v?.str("Codec")?.ifEmpty { null }?.lowercase(),
            audioCodec = a?.str("Codec")?.ifEmpty { null }?.lowercase(),
            // Emby only: Jellyfin has no ExtendedVideoSubType.
            doviProfile = v?.let { embyDoviProfile(it.str("ExtendedVideoSubType")) },
            bitrate = src?.num("Bitrate")?.takeIf { it > 0 }?.let { Math.round(it / 1000).toInt() } ?: 0,
        )
    }

    companion object {
        private val MUSIC = Regex("music", RegexOption.IGNORE_CASE)
        private val DOVI = Regex("doviprofile(\\d{2,})", RegexOption.IGNORE_CASE)

        /** /UserViews on Jellyfin, /Users/{id}/Views on Emby (nostalgex-jellyfin-urls.js userViewsPath). */
        fun userViewsPath(backend: String, userId: String) =
            if (backend == "emby") "/Users/${enc(userId)}/Views" else "/UserViews?userId=${enc(userId)}"

        /** "DoviProfile50" is profile 5, "DoviProfile81" profile 8. */
        fun embyDoviProfile(subtype: String?): Int? =
            DOVI.matchEntire(subtype ?: "")?.groupValues?.get(1)?.dropLast(1)?.toIntOrNull()

        private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

        private fun tmdbFromProviderIds(ids: JsonObject?): Long? =
            ids?.entries?.firstOrNull { it.key.lowercase() == "tmdb" }?.value?.let { (it as? JsonPrimitive)?.content?.toLongOrNull() }

        /** pickBestVersion: highest bitrate; equal ones by height; the first when none has a bitrate. */
        private fun pickBestVersion(sources: List<JsonObject>): JsonObject? {
            if (sources.isEmpty()) return null
            if (sources.none { it["Bitrate"].let { b -> b != null && b !is JsonNull } }) return sources[0]
            fun height(s: JsonObject) = s.arr("MediaStreams").firstOrNull { it.str("Type") == "Video" }?.num("Height") ?: 0.0
            return sources.reduce { best, s ->
                val bb = best.num("Bitrate", -1.0)
                val bs = s.num("Bitrate", -1.0)
                if (bs != bb) (if (bs > bb) s else best) else if (height(s) > height(best)) s else best
            }
        }

        private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
        private fun JsonObject.long(k: String) = (this[k] as? JsonPrimitive)?.longOrNull
        private fun JsonObject.num(k: String, default: Double = 0.0) = (this[k] as? JsonPrimitive)?.doubleOrNull ?: default
        private fun JsonObject.obj(k: String) = this[k] as? JsonObject
        private fun JsonObject.arr(k: String) = (this[k] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
        private fun JsonObject.strings(k: String) = (this[k] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: emptyList()
        @Suppress("unused") private fun JsonObject.bool(k: String) = (this[k] as? JsonPrimitive)?.booleanOrNull
    }
}
