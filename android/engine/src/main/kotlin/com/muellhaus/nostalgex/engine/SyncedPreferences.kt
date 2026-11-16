package com.muellhaus.nostalgex.engine

/**
 * The preferences that follow the viewer to a new TV, and nothing else: the Apple TV's `PreferenceSync.syncedKeys`
 * under Android's own key names (the Apple TV's legacy report-playback key has no Android counterpart). Server
 * addresses, tokens, user ids, the saved library and every cache stay on the device; this list is the whole of what
 * Auto Backup is allowed to carry, through a mirror file of its own (`nostalgex_backup`) that is the only file the
 * backup rules include.
 */
object SyncedPreferences {
    enum class Kind { STRING_SET_NOT_EMPTY, STRING_SET, BOOL, STRING }

    data class Key(val name: String, val kind: Kind)

    val keys: List<Key> = listOf(
        Key("enabledBundles", Kind.STRING_SET_NOT_EMPTY),           // never an empty lineup
        Key("nostalgex_enabled_collections", Kind.STRING_SET),
        Key("nostalgex_enabled_franchises", Kind.STRING_SET),
        Key("nostalgex_disabled_franchises", Kind.STRING_SET),
        Key("retroMode", Kind.BOOL),
        Key(GuideTextSize.STORAGE_KEY, Kind.STRING),
        Key("subtitlesInFullScreen", Kind.BOOL),
        Key("autoSubtitles", Kind.BOOL),
        Key("subtitleLanguage", Kind.STRING),
        Key("audioLanguage", Kind.STRING),
        Key(StreamQuality.STORAGE_KEY, Kind.STRING),
        Key("nostalgex_show_now_playing_v2", Kind.BOOL),
        Key("nostalgex_mark_watched_v2", Kind.BOOL),
    )

    /** The name of the mirror file in `shared_prefs`, the one file the backup rules include. */
    const val MIRROR_FILE = "nostalgex_backup"

    /**
     * What to copy from `all` (a preferences file's contents): only the listed keys, only when the value has the key's
     * kind (a set of strings, a boolean or a string), and never an empty lineup.
     */
    fun pick(all: Map<String, *>): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        for ((name, kind) in keys) {
            val v = all[name] ?: continue
            val ok = when (kind) {
                Kind.STRING_SET_NOT_EMPTY -> v is Set<*> && v.isNotEmpty() && v.all { it is String }
                Kind.STRING_SET -> v is Set<*> && v.all { it is String }
                Kind.BOOL -> v is Boolean
                Kind.STRING -> v is String
            }
            if (ok) out[name] = v
        }
        return out
    }
}
