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
        fun update(progress: ScanProgress)
    }

    /** Set when a server saved as Jellyfin answered as Emby (adoptMediaBrowserKind). */
    var adoptedEmby = false
        private set

    /**
     * The user's libraries (views). An Emby server still saved as Jellyfin answers /UserViews
     * with a 404. `includeHidden` asks Jellyfin for the libraries the user hides from the home
     * screen too; Emby's list has no such switch.
     */
    private fun views(includeHidden: Boolean = false): List<JsonObject> {
        var (status, views) = fetch.get(userViewsPath(backend, userId, includeHidden))
        if (status == 404 && backend == "jellyfin") {
            val emby = fetch.get(userViewsPath("emby", userId))
            if (emby.first in 200..299) {
                backend = "emby"
                adoptedEmby = true
                views = emby.second
            }
        }
        return (views as? JsonObject)?.arr("Items") ?: emptyList()
    }

    /**
     * Every library, for the library-selection screen and Settings (JellyfinAPIService.loadSections).
     * On Jellyfin two requests: the plain list, as always, then the list with the libraries the
     * user hides from the home screen; one only in the second is `hidden`. If the second fails
     * the answer is the plain list. The union keeps the second answer's order, so a second
     * answer that is somehow smaller can't take a library off the list.
     */
    fun sections(serverId: String, serverName: String): List<LibrarySection> {
        val shown = views()
        val everything = if (backend == "jellyfin") runCatching { views(includeHidden = true) }.getOrNull() ?: shown else shown
        val shownIds = shown.mapTo(HashSet()) { it.str("Id") }
        val everythingIds = everything.mapTo(HashSet()) { it.str("Id") }
        // A view with no videos in it (Playlists, Music, Collections...) is not offered (#206).
        return (everything + shown.filter { it.str("Id") !in everythingIds }).filter(::holdsVideos).map { view ->
            LibrarySection(serverId, serverName, view.str("Id") ?: "", view.str("Name") ?: "Library", sectionType(view.str("CollectionType")),
                hidden = view.str("Id") !in shownIds)
        }
    }

    /**
     * The libraries a scan reads: the plain list, plus those hidden on Jellyfin that the viewer
     * switched on (`includedHidden`, view ids). The hidden list is only asked for when one is
     * on, so by default the scan's requests are what they always were.
     */
    private fun scanViews(includedHidden: Set<String>): List<JsonObject> {
        val shown = views()
        if (backend != "jellyfin" || includedHidden.isEmpty()) return shown
        val everything = runCatching { views(includeHidden = true) }.getOrNull() ?: return shown
        val shownIds = shown.mapTo(HashSet()) { it.str("Id") }
        return everything.filter { it.str("Id") in shownIds || it.str("Id") in includedHidden } +
            shown.filter { s -> everything.none { it.str("Id") == s.str("Id") } }
    }

    /**
     * Every item in every library but those in `excluded` (view ids), which are skipped before
     * any request for their items goes out.
     */
    fun scan(
        progress: Progress = Progress { },
        excluded: Set<String> = emptySet(),
        /** Each library once it is read whole, so a scan abandoned later still has these (LibraryScanInterrupted). */
        onSection: (List<MediaItem>) -> Unit = {},
        /** Libraries hidden on Jellyfin that the viewer switched on (view ids); the rest of the hidden ones aren't read. */
        includedHidden: Set<String> = emptySet(),
        /** A movie or episode dropped for having no runtime, for the coverage line (skippedNoRuntimeCount). */
        onSkippedNoRuntime: () -> Unit = {},
    ): List<MediaItem> {
        // A view with no videos in it is never asked for items (#206).
        val viewList = scanViews(includedHidden).filter { (it.str("Id") ?: "") !in excluded && holdsVideos(it) }
        val out = ArrayList<MediaItem>()
        val tally = SectionTally()
        for ((index, view) in viewList.withIndex()) {
            val sectionStart = out.size
            val type = sectionType(view.str("CollectionType"))
            val isMusicVideoSection = type == "musicvideo"
            val name = view.str("Name") ?: "Library"
            progress.update(ScanProgress(index, viewList.size, name, type, out.size))
            try {
                if (type == "show") {
                    val shows = fetchItems(view.str("Id") ?: "", itemTypes(type)!!)
                    for ((done, show) in shows.withIndex()) {
                        val showGenres = show.strings("Genres")
                        val showTmdb = tmdbFromProviderIds(show.obj("ProviderIds"))
                        val episodes = try { fetchItems(show.str("Id") ?: "", "Episode") } catch (e: ScanCancelled) { throw e } catch (e: Exception) { emptyList() }
                        for (ep in episodes) {
                            val minutes = DailyManifest.minutesFromTicks(ep.long("RunTimeTicks"))
                            if (minutes <= 0) { onSkippedNoRuntime(); continue }
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
                                // The series, for a server collection of shows (plex-tuner.html showKey).
                                showKey = show.str("Id"),
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
                                audioStreams = mi.audioStreams,
                                videoWidth = mi.width,
                                videoHeight = mi.height,
                                partKey = mi.msid,
                                container = mi.container,
                                videoCodec = mi.videoCodec,
                                audioCodec = mi.audioCodec,
                                bitrate = mi.bitrate,
                            )
                        }
                        progress.update(ScanProgress(index, viewList.size, name, type, out.size, done + 1, shows.size))
                    }
                } else {
                    // A music video library also holds MusicVideo items, which a request for Movie
                    // never returns (I-067, #172); a clip filed as a film still loads.
                    val types = itemTypes(type)!!
                    // Each page goes in as it arrives, with its progress, as Plex does: a big library
                    // keeps the stall watch seeing it arrive, and a stopped scan keeps the pages
                    // read (EmbyAPIService and JellyfinAPIService, N-033).
                    fetchItems(view.str("Id") ?: "", types) { page ->
                        val pageStart = out.size
                        for (jf in page) {
                            val genres = jf.strings("Genres").toMutableList()
                            if (isMusicVideoSection && genres.none { MUSIC.containsMatchIn(it) }) genres += "Music Video"
                            val minutes = DailyManifest.minutesFromTicks(jf.long("RunTimeTicks"))
                            if (minutes <= 0) { onSkippedNoRuntime(); continue }
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
                                audioStreams = mi.audioStreams,
                                videoWidth = mi.width,
                                videoHeight = mi.height,
                                partKey = mi.msid,
                                container = mi.container,
                                videoCodec = mi.videoCodec,
                                audioCodec = mi.audioCodec,
                                bitrate = mi.bitrate,
                            )
                        }
                        onSection(out.subList(pageStart, out.size).toList())
                        progress.update(ScanProgress(index, viewList.size, name, type, out.size))
                    }
                    progress.update(ScanProgress(index, viewList.size, name, type, out.size))
                }
                // A TV library goes in whole; a movie library already went in page by page.
                if (type == "show") onSection(out.subList(sectionStart, out.size).toList())
                tally.read()
            } catch (e: ScanCancelled) {
                throw e
            } catch (e: Exception) {
                // One library that fails leaves the others, as the web tuner's per-view catch, and
                // leaves none of its own items: the web reads a library whole before it keeps any.
                // (Only a stop keeps a movie library's pages, through onSection.)
                while (out.size > sectionStart) out.removeAt(out.lastIndex)
                tally.failed(e)
            }
        }
        // Every library failing is a failed scan, not an empty library (#198).
        tally.check()
        return out
    }

    /**
     * Every item of a type (or a comma list of types) under a parent, 200 at a time, with the
     * fields the channel rules read. `onPage` sees each page as it arrives. OfficialRating and
     * CommunityRating are named because Emby 4.10 leaves both out unless asked (#204); Jellyfin
     * sends them regardless.
     */
    private fun fetchItems(parentId: String, types: String, onPage: (List<JsonObject>) -> Unit = {}): List<JsonObject> {
        val all = ArrayList<JsonObject>()
        var start = 0
        while (true) {
            val path = "/Items?userId=${enc(userId)}&ParentId=${enc(parentId)}&Recursive=true&IncludeItemTypes=$types" +
                "&Fields=ProviderIds,Overview,Genres,Studios,MediaSources,ProductionYear,PremiereDate,DateCreated,UserData,OfficialRating,CommunityRating" +
                "&StartIndex=$start&Limit=200&SortBy=SortName"
            val (status, body) = fetch.get(path)
            if (status !in 200..299) throw IllegalStateException("HTTP $status for items under $parentId")
            val d = body as? JsonObject ?: JsonObject(emptyMap())
            val raw = d.arr("Items")
            // Only the types asked for: a row of another type is dropped (#206).
            val items = raw.filter { hasAskedType(it.str("Type"), types) }
            all += items
            onPage(items)
            val total = d.long("TotalRecordCount")?.toInt() ?: (start + raw.size)
            start += raw.size
            if (raw.isEmpty() || start >= total) break
        }
        return all
    }

    private data class MediaInfo(
        val msid: String?, val container: String?, val videoCodec: String?, val audioCodec: String?, val doviProfile: Int?, val bitrate: Int,
        val audioStreams: List<AudioStream>, val width: Int?, val height: Int?,
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
            audioStreams = streams.filter { it.str("Type") == "Audio" }.map { s ->
                AudioStream(
                    index = s.long("Index")?.toInt() ?: 0,
                    lang = (s.str("Language") ?: "").lowercase(),
                    codec = (s.str("Codec") ?: "").lowercase(),
                    channels = s.long("Channels")?.toInt() ?: 0,
                    title = s.str("DisplayTitle")?.ifEmpty { null } ?: s.str("Title")?.ifEmpty { null } ?: s.str("Language")?.ifEmpty { null } ?: "Audio",
                    isDefault = (s["IsDefault"] as? JsonPrimitive)?.content == "true",
                )
            },
            width = v?.long("Width")?.toInt()?.takeIf { it > 0 },
            height = v?.long("Height")?.toInt()?.takeIf { it > 0 },
        )
    }

    companion object {
        private val MUSIC = Regex("music", RegexOption.IGNORE_CASE)
        private val DOVI = Regex("doviprofile(\\d{2,})", RegexOption.IGNORE_CASE)

        /**
         * CollectionTypes with no videos in them (#206): never asked for items and not offered
         * in library selection. nostalgex-jellyfin-urls.js NON_VIDEO_VIEWS and the Apple TV's
         * nonVideoCollectionTypes, pinned by `sections` in scripts/jellyfin-library-golden.json.
         */
        private val NON_VIDEO_VIEWS = setOf(
            "music", "playlists", "boxsets", "books", "audiobooks", "photos", "homevideos", "livetv", "trailers", "folders", "channels",
        )

        /**
         * A view's CollectionType as the section type the scan branches on: "show", "musicvideo",
         * "other" (a view that holds no videos, never read), or "movie". A Playlists view answers
         * any items request with its playlists, whatever IncludeItemTypes says (Jellyfin's
         * PlaylistsFolder overwrites it), so asking it for films filed a 33 minute workout mix as
         * a film on VHS VAULT. A view with no CollectionType, or one not known here, is mixed
         * content and still a film view.
         */
        fun sectionType(collectionType: String?): String {
            val kind = collectionType?.lowercase() ?: return "movie"
            return when {
                kind == "tvshows" -> "show"
                kind == "musicvideos" -> "musicvideo"
                kind in NON_VIDEO_VIEWS -> "other"
                else -> "movie"
            }
        }

        /**
         * IncludeItemTypes for a section, or null for one that is not read. A music video library
         * is asked for MusicVideo and for Movie, for a clip filed as a film (I-067).
         */
        fun itemTypes(sectionType: String): String? = when (sectionType) {
            "show" -> "Series"
            "musicvideo" -> "Movie,MusicVideo"
            "movie" -> "Movie"
            else -> null
        }

        /**
         * False for a row whose Type is not among the types asked for, for a view that answers
         * with more than it was asked (Playlists does). A row with no Type is kept. Case does
         * not matter. nostalgex-jellyfin-urls.js hasAskedType.
         */
        fun hasAskedType(type: String?, asked: String): Boolean {
            if (type.isNullOrEmpty()) return true
            return asked.lowercase().split(',').contains(type.lowercase())
        }

        /** True for a view the scan reads (one that holds videos). */
        private fun holdsVideos(view: JsonObject) = sectionType(view.str("CollectionType")) != "other"

        /**
         * The request that lists a user's libraries (nostalgex-jellyfin-urls.js userViewsPath),
         * held to `views` in scripts/jellyfin-library-golden.json. `includeHidden` adds Jellyfin's
         * includeHidden=true, which lifts only the home-screen hiding: a library the user has no
         * access to is still left out.
         */
        fun userViewsPath(backend: String, userId: String, includeHidden: Boolean = false) =
            if (backend == "emby") "/Users/${enc(userId)}/Views"
            else "/UserViews?userId=${enc(userId)}" + if (includeHidden) "&includeHidden=true" else ""

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
