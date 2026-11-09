package com.muellhaus.nostalgex

import android.content.Context
import com.muellhaus.nostalgex.engine.ChannelConfig
import com.muellhaus.nostalgex.engine.LanguageChoice
import com.muellhaus.nostalgex.engine.LibrarySection
import com.muellhaus.nostalgex.engine.ManifestStore
import com.muellhaus.nostalgex.engine.StreamQuality
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserServer
import com.muellhaus.nostalgex.plex.PlexServer
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/** The sign-in, the servers and the packages, kept across launches. */
class Prefs(context: Context) {
    private val prefs = context.getSharedPreferences("nostalgex", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    /** One id per install, sent as X-Plex-Client-Identifier, as the web tuner's getClientId. */
    val clientId: String
        get() = prefs.getString("clientId", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("clientId", it).apply()
        }

    var plexToken: String?
        get() = prefs.getString("plexToken", null)
        set(value) = prefs.edit().putString("plexToken", value).apply()

    /** Each server on, with the address that answered at sign-in. */
    var servers: List<PlexServer>
        get() = prefs.getString("servers", null)?.let { runCatching { json.decodeFromString<List<PlexServer>>(it) }.getOrNull() } ?: emptyList()
        set(value) = prefs.edit().putString("servers", json.encodeToString(value)).apply()

    /** The Jellyfin or Emby server signed in to; null on Plex. One backend at a time, as the Apple TV. */
    var mediaBrowser: MediaBrowserServer?
        get() = prefs.getString("mediaBrowser", null)?.let { runCatching { json.decodeFromString<MediaBrowserServer>(it) }.getOrNull() }
        set(value) = prefs.edit().putString("mediaBrowser", value?.let { json.encodeToString(it) }).apply()

    /** "nostalgex" on a first launch, as the web tuner and the Apple TV. */
    var enabledBundles: Set<String>
        get() = prefs.getStringSet("enabledBundles", null) ?: setOf("nostalgex")
        set(value) = prefs.edit().putStringSet("enabledBundles", value).apply()

    /** RETRO MODE, on unless switched off (AppState.retroMode, `nostalgex_retro_mode`). */
    var retroMode: Boolean
        get() = prefs.getBoolean("retroMode", true)
        set(value) = prefs.edit().putBoolean("retroMode", value).apply()

    /** The CC row: subtitles in full screen, off unless switched on (`nostalgex_subtitles_fullscreen`). */
    var subtitlesInFullScreen: Boolean
        get() = prefs.getBoolean("subtitlesInFullScreen", false)
        set(value) = prefs.edit().putBoolean("subtitlesInFullScreen", value).apply()

    /** AUTO SUBTITLES (FOREIGN AUDIO), on unless switched off (`nostalgex_auto_subs_foreign_audio`). */
    var autoSubtitles: Boolean
        get() = prefs.getBoolean("autoSubtitles", true)
        set(value) = prefs.edit().putBoolean("autoSubtitles", value).apply()

    /** SUBTITLE LANGUAGE and AUDIO LANGUAGE, following the TV's language until chosen. */
    var subtitleLanguage: String
        get() = prefs.getString("subtitleLanguage", null) ?: LanguageChoice.SYSTEM
        set(value) = prefs.edit().putString("subtitleLanguage", value).apply()
    var audioLanguage: String
        get() = prefs.getString("audioLanguage", null) ?: LanguageChoice.SYSTEM
        set(value) = prefs.edit().putString("audioLanguage", value).apply()

    /** Set once a full library load has finished on this device: later ones skip the first-setup warning. */
    var initialLoadComplete: Boolean
        get() = prefs.getBoolean("nostalgex_completed_initial_load", false)
        set(value) = prefs.edit().putBoolean("nostalgex_completed_initial_load", value).apply()

    /** The libraries switched off (LibrarySection ids), under the Apple TV's key. Absent means every library is on. */
    var deselectedSections: Set<String>
        get() = prefs.getStringSet(LibrarySection.STORAGE_KEY, null) ?: emptySet()
        set(value) = prefs.edit().putStringSet(LibrarySection.STORAGE_KEY, value).apply()

    /**
     * Franchises switched on and off by stable id ("dict:STAR WARS", "tmdb:2806"), under the
     * Apple TV's keys (PreferenceSync). A franchise in neither set takes its default: a stock
     * classic on, a found franchise on only if the dictionary says so (FranchiseDictionary.isOn).
     */
    var enabledFranchises: Set<String>
        get() = prefs.getStringSet("nostalgex_enabled_franchises", null) ?: emptySet()
        set(value) = prefs.edit().putStringSet("nostalgex_enabled_franchises", value).apply()

    var disabledFranchises: Set<String>
        get() = prefs.getStringSet("nostalgex_disabled_franchises", null) ?: emptySet()
        set(value) = prefs.edit().putStringSet("nostalgex_disabled_franchises", value).apply()

    /** Server collections switched on, by collection id; every collection starts off. The Apple TV's key. */
    var enabledCollections: Set<String>
        get() = prefs.getStringSet("nostalgex_enabled_collections", null) ?: emptySet()
        set(value) = prefs.edit().putStringSet("nostalgex_enabled_collections", value).apply()

    /** SHOW NOW PLAYING and MARK WATCHED, off unless switched on, under the Apple TV's keys (PlaybackReportingPreferences). */
    var showNowPlaying: Boolean
        get() = prefs.getBoolean("nostalgex_show_now_playing_v2", false)
        set(value) = prefs.edit().putBoolean("nostalgex_show_now_playing_v2", value).apply()

    var markWatched: Boolean
        get() = prefs.getBoolean("nostalgex_mark_watched_v2", false)
        set(value) = prefs.edit().putBoolean("nostalgex_mark_watched_v2", value).apply()

    /** The seasonal invite's answers, under the Apple TV's keys (Season.neverKey, Season.dismissedKey): set means silenced. */
    fun flag(key: String) = prefs.getBoolean(key, false)
    fun setFlag(key: String) = prefs.edit().putBoolean(key, true).apply()

    /** GUIDE TEXT SIZE: "large", or anything else for NORMAL, under the Apple TV's key. */
    var guideTextLarge: Boolean
        get() = prefs.getString("nostalgex_guide_text_size", null) == "large"
        set(value) = prefs.edit().putString("nostalgex_guide_text_size", if (value) "large" else "normal").apply()

    /** WATERSHED (Settings > SCHEDULE), off unless switched on, under the Apple TV's key. */
    var watershed: Boolean
        get() = prefs.getBoolean(ChannelConfig.WATERSHED_STORAGE_KEY, false)
        set(value) = prefs.edit().putBoolean(ChannelConfig.WATERSHED_STORAGE_KEY, value).apply()

    /** STREAM QUALITY's level id, under the Apple TV's key. */
    var streamQuality: String
        get() = prefs.getString(StreamQuality.STORAGE_KEY, null) ?: StreamQuality.AUTO.id
        set(value) = prefs.edit().putString(StreamQuality.STORAGE_KEY, value).apply()

    /**
     * The daily refresh's clock and baseline (#195), as the Apple TV keeps them with its
     * snapshot: when the library last loaded (backdated a day after an abandoned scan), when it
     * was last checked, and the Plex signature it loaded with. Seconds since the epoch.
     */
    var lastLoadSec: Long
        get() = prefs.getLong("nostalgex_last_load_at", 0L)
        set(value) = prefs.edit().putLong("nostalgex_last_load_at", value).apply()

    var lastCheckSec: Long
        get() = prefs.getLong("nostalgex_last_library_check_at", 0L)
        set(value) = prefs.edit().putLong("nostalgex_last_library_check_at", value).apply()

    var librarySignature: String?
        get() = prefs.getString("nostalgex_library_signature", null)
        set(value) = prefs.edit().putString("nostalgex_library_signature", value).apply()

    fun signOut() = prefs.edit().remove("plexToken").remove("servers").remove("mediaBrowser")
        .remove("nostalgex_last_load_at").remove("nostalgex_last_library_check_at").remove("nostalgex_library_signature").apply()
}

/**
 * Manifests as one small file each under filesDir/manifests, read through a memory cache: a
 * guide rebuild reads every channel's two days, and SharedPreferences would rewrite one big
 * file on each new day.
 */
class FileManifestStore(context: Context) : ManifestStore {
    private val dir = File(context.filesDir, "manifests").apply { mkdirs() }
    private val cache = HashMap<String, String?>()

    private fun file(key: String) = File(dir, key.replace(Regex("[^A-Za-z0-9_.-]"), "_"))

    @Synchronized
    override fun get(key: String): String? = cache.getOrPut(key) { file(key).takeIf { it.exists() }?.readText() }

    @Synchronized
    override fun set(key: String, value: String) {
        cache[key] = value
        file(key).writeText(value)
    }

    @Synchronized
    override fun remove(key: String) {
        cache.remove(key)
        file(key).delete()
    }

    @Synchronized
    override fun keys(): Set<String> = dir.list()?.toSet() ?: emptySet()
}
