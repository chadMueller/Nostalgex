package com.muellhaus.nostalgex.engine

import kotlinx.serialization.Serializable

/**
 * One programme as the loaders build it: the web tuner's item shape (plex-tuner.html
 * scanOnePlexServer), which is PlexMediaItem's on the Apple TV. `duration` is whole minutes,
 * truncated (DailyManifest.minutesFromPlexMs), and `title` is the show's name for an episode.
 */
@Serializable
data class MediaItem(
    val ratingKey: String,
    val title: String = "",
    val type: String = "movie",
    val duration: Int = 0,
    val addedAt: Long = 0,
    val episodeTitle: String? = null,
    /** "S01E04", as PlexMediaItem.seTag. */
    val seTag: String? = null,
    val artist: String? = null,
    val summary: String = "",
    val year: Int? = null,
    val originallyAvailableAt: String? = null,
    val contentRating: String? = null,
    val genres: List<String> = emptyList(),
    val rating: Double = 0.0,
    val userRating: Double = 0.0,
    val viewCount: Int = 0,
    val studio: String? = null,
    val librarySource: String = "movie",
    val tmdbID: Long? = null,
    val doviProfile: Int? = null,
    val enrichment: Enrichment? = null,
    // Playback, Plex only for now.
    val partKey: String? = null,
    val container: String? = null,
    val videoCodec: String? = null,
    val audioCodec: String? = null,
    /** The file's bitrate in kbps (Plex `Media.bitrate`), for the remote direct-play ceiling. */
    val bitrate: Int? = null,
    val serverUrl: String? = null,
    val serverToken: String? = null,
    /** Plex artwork path (`thumb`), for the Now Playing poster. */
    val thumb: String? = null,
    /**
     * An episode's show: Plex `grandparentRatingKey`, Jellyfin and Emby `SeriesId`, as the
     * web tuner's `showKey` and PlexMediaItem.showKey. A server collection that lists a
     * show resolves to every episode carrying its key (Collections.resolveMembers).
     */
    val showKey: String? = null,
    /** Which server the item came from, the web tuner's `serverID`. A ratingKey is unique on one server only. */
    val serverID: String? = null,
)

/**
 * TMDB and OMDb values, as MediaEnrichment on the Apple TV and the web tuner's record
 * (scripts/nostalgex-enrichment.js). Null on an item when TMDB has no record.
 */
@Serializable
data class Enrichment(
    val keywords: List<String> = emptyList(),
    val productionCompanies: List<String> = emptyList(),
    val networks: List<String> = emptyList(),
    val tmdbGenres: List<String> = emptyList(),
    val imdbRating: Double? = null,
    val imdbVotes: Double? = null,
    /** Rotten Tomatoes, the web record's `rottenTomatoesScore`. */
    val rtScore: Double? = null,
    val metacriticScore: Double? = null,
    val awards: String? = null,
    // What the caches and the write-backs carry beyond what the filter reads.
    val tmdbID: String? = null,
    val imdbID: String? = null,
    /** "movie" or "tv". */
    val mediaType: String? = null,
    val franchiseID: Double? = null,
    val franchiseName: String? = null,
    val fetchedAt: String? = null,
)
