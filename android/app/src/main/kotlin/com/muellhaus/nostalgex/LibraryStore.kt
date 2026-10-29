package com.muellhaus.nostalgex

import android.content.Context
import com.muellhaus.nostalgex.engine.MediaItem
import com.muellhaus.nostalgex.plex.PlexServer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromStream
import kotlinx.serialization.json.encodeToStream
import java.io.File

/**
 * The library as last read, so a launch can build the guide without reading every server
 * first. One file in the app's own storage, written whole to a temporary file and renamed, so
 * a power cut mid-write leaves the previous copy. It is only used for the same servers it was
 * read from, and only in this format.
 */
class LibraryStore(context: Context) {
    @Serializable
    private data class Saved(val format: Int, val servers: List<String>, val items: List<MediaItem>)

    private val file = File(context.filesDir, "library.json")
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    private fun key(servers: List<PlexServer>) = servers.map { "${it.machineIdentifier}@${it.url}" }

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    fun load(servers: List<PlexServer>): List<MediaItem>? = runCatching {
        if (!file.exists()) return null
        val saved = file.inputStream().buffered().use { json.decodeFromStream<Saved>(it) }
        saved.items.takeIf { saved.format == FORMAT && saved.servers == key(servers) }
    }.getOrNull()

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    fun save(servers: List<PlexServer>, items: List<MediaItem>) {
        val tmp = File(file.path + ".tmp")
        tmp.outputStream().buffered().use { json.encodeToStream(Saved(FORMAT, key(servers), items), it) }
        tmp.renameTo(file)
    }

    /** When the saved copy was written, for "Last updated" in Settings. */
    fun savedAtMs(): Long? = file.takeIf { it.exists() }?.lastModified()

    fun clear() {
        file.delete()
    }

    companion object {
        /** Bump when MediaItem or what the scan fills in changes, so an old copy is read again. */
        private const val FORMAT = 4 // 2: episodes carry seTag; 3: items carry thumb; 4: and bitrate
    }
}
