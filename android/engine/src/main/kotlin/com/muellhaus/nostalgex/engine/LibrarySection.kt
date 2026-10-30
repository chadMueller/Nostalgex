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
) {
    val id: String get() = storageKey(serverId, key)

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

        fun storageKey(serverId: String, key: String) = "$serverId::$key"

        /** The library keys switched off on one server, from the stored ids. */
        fun excludedKeys(deselected: Set<String>, serverId: String): Set<String> {
            val prefix = storageKey(serverId, "")
            return deselected.filter { it.startsWith(prefix) }.map { it.removePrefix(prefix) }.toSet()
        }

        private val MUSIC_VIDEO_TITLE = Regex("music.?video|^music$|^mvs?$", RegexOption.IGNORE_CASE)
    }
}
