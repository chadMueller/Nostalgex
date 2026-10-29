package com.muellhaus.nostalgex

import android.content.Context
import com.muellhaus.nostalgex.engine.LanguageChoice
import com.muellhaus.nostalgex.engine.ManifestStore
import com.muellhaus.nostalgex.engine.StreamQuality
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

    /** STREAM QUALITY's level id, under the Apple TV's key. */
    var streamQuality: String
        get() = prefs.getString(StreamQuality.STORAGE_KEY, null) ?: StreamQuality.AUTO.id
        set(value) = prefs.edit().putString(StreamQuality.STORAGE_KEY, value).apply()

    fun signOut() = prefs.edit().remove("plexToken").remove("servers").apply()
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
