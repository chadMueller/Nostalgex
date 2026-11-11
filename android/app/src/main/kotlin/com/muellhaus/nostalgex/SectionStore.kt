package com.muellhaus.nostalgex

import android.content.Context
import com.muellhaus.nostalgex.engine.ScanResume
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromStream
import kotlinx.serialization.json.encodeToStream
import java.io.File

/**
 * Library sections read in full by a scan that hasn't finished (#288, the Apple TV's
 * LibraryScanProgressStore): one file per section, apart from the library snapshot, each written
 * to a temporary file and renamed. Cleared once a whole library has been read, and on DISCONNECT.
 */
class SectionStore(context: Context) {
    private val dir = File(context.filesDir, "scan-sections")
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    private fun file(serverId: String, key: String) =
        File(dir, "$serverId::$key".replace(Regex("[^A-Za-z0-9_.-]"), "_") + ".json")

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    fun load(serverId: String, key: String): ScanResume.Kept? = runCatching {
        val f = file(serverId, key)
        if (!f.exists()) return null
        f.inputStream().buffered().use { json.decodeFromStream<ScanResume.Kept>(it) }.takeIf { it.serverId == serverId && it.key == key }
    }.getOrNull()

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    fun save(kept: ScanResume.Kept) {
        runCatching {
            dir.mkdirs()
            val f = file(kept.serverId, kept.key)
            val tmp = File(f.path + ".tmp")
            tmp.outputStream().buffered().use { json.encodeToStream(kept, it) }
            tmp.renameTo(f)
        }
    }

    /** How many sections are kept, for the log. */
    fun count(): Int = dir.listFiles { f -> f.name.endsWith(".json") }?.size ?: 0

    fun clear() {
        dir.listFiles()?.forEach { it.delete() }
    }
}
