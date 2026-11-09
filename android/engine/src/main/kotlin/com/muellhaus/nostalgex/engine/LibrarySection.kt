package com.muellhaus.nostalgex.engine

/**
 * One library on one server, as LibrarySectionRef on the Apple TV: what the library-selection
 * screen and Settings' LIBRARIES list show, and what a viewer switches off so it is never
 * scanned. `key` is only unique per server, so `id` scopes it by the server's id.
 */
data class LibrarySection(
    val serverId: String,
    val serverName: String,
    val key: String,
    val title: String,
    /** "movie", "show", "musicvideo", or whatever else the server calls it ("artist", "photo"). */
    val type: String,
    /**
     * Jellyfin only: the user hides this library from the home screen on the server
     * (`MyMediaExcludes`). Listed only with INCLUDE LIBRARIES HIDDEN ON JELLYFIN on, and then
     * on like any other library unless switched off.
     */
    val hidden: Boolean = false,
) {
    val id: String get() = storageKey(serverId, key)

    /** The line under the library's name (LibrarySectionRef.subtitle): its kind, the server when more than one is in play, and [HIDDEN_MARK]. */
    fun subtitle(multiServer: Boolean): String {
        val base = if (multiServer) "$serverName · $typeLabel" else typeLabel
        return if (hidden) "$base · $HIDDEN_MARK" else base
    }

    /** The kind of library, for the row's subtitle (LibrarySectionRef.typeLabel). */
    val typeLabel: String
        get() = when (type) {
            "show" -> "TV Shows"
            "musicvideo" -> "Music Videos"
            "artist" -> "Music"
            "photo" -> "Photos"
            "movie" -> if (MUSIC_VIDEO_TITLE.containsMatchIn(title)) "Music Videos" else "Movies"
            else -> "Library"
        }

    companion object {
        /** The Apple TV's UserDefaults key for the libraries switched off. */
        const val STORAGE_KEY = "nostalgex_deselected_library_sections"

        /** What Settings and the library picker call such a library. */
        const val HIDDEN_MARK = "HIDDEN ON JELLYFIN"

        fun storageKey(serverId: String, key: String) = "$serverId::$key"

        /** The library keys on one server among the stored ids switched off. */
        fun excludedKeys(deselected: Set<String>, serverId: String): Set<String> {
            val prefix = storageKey(serverId, "")
            return deselected.filter { it.startsWith(prefix) }.map { it.removePrefix(prefix) }.toSet()
        }

        private val MUSIC_VIDEO_TITLE = Regex("music.?video|^music$|^mvs?$", RegexOption.IGNORE_CASE)
    }
}

/**
 * Where a library scan has got to, for the loading screen (AppState+Library's scan events):
 * which library of how many, and the items read so far, with shows done for a TV library.
 */
data class ScanProgress(
    val section: Int,
    val sections: Int,
    val title: String,
    val type: String,
    val itemsSoFar: Int,
    val showsDone: Int? = null,
    val showsTotal: Int? = null,
)
