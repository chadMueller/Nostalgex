package com.muellhaus.nostalgex

import android.content.Context
import android.util.Log
import com.muellhaus.nostalgex.engine.Enrichment
import com.muellhaus.nostalgex.engine.EnrichmentService
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromStream
import kotlinx.serialization.json.encodeToStream
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * The Android side of [EnrichmentService]: OkHttp for the relay and Supabase, a file for the
 * local cache, SharedPreferences for the OMDb backoff. Built only when local.properties
 * turned enrichment on (app/build.gradle.kts); otherwise [create] answers null and no rule
 * that needs TMDB or OMDb ever matches, as on an Apple TV with no enrichment.
 */
object EnrichmentSetup {
    fun create(context: Context): EnrichmentService? {
        if (!BuildConfig.ENRICHMENT) return null
        val config = EnrichmentService.Config(
            BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_ANON_KEY,
            BuildConfig.RELAY_URL.ifEmpty { EnrichmentService.RELAY_URL },
        )
        if (!config.isComplete) {
            Log.w("Nostalgex", "ENRICHMENT switched on without a Supabase URL and anon key; off")
            return null
        }
        return EnrichmentService(config, OkHttpNet(), FileCache(File(context.filesDir, "enrichment.json")), PrefsBackoff(context))
    }

    fun clear(context: Context) {
        File(context.filesDir, "enrichment.json").delete()
    }
}

private class OkHttpNet : EnrichmentService.Net {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private fun run(request: Request): EnrichmentService.Response = try {
        client.newCall(request).execute().use { EnrichmentService.Response(it.code, it.body.string()) }
    } catch (e: Exception) {
        EnrichmentService.Response(0, null)
    }

    override fun get(url: String, headers: Map<String, String>) =
        run(Request.Builder().url(url).apply { headers.forEach { (k, v) -> header(k, v) } }.build())

    override fun post(url: String, headers: Map<String, String>, body: String) =
        run(Request.Builder().url(url).apply { headers.forEach { (k, v) -> header(k, v) } }
            .post(body.toRequestBody("application/json".toMediaType())).build())
}

/**
 * The local cache (the web tuner's IndexedDB store, EnrichmentCache.swift's file): one JSON
 * file, read once and written whole to a temporary file and renamed, as LibraryStore is.
 */
private class FileCache(private val file: File) : EnrichmentService.Cache {
    @Serializable
    private data class Row(val savedAtMs: Long, val record: Enrichment? = null)

    @Serializable
    private data class Saved(val format: Int, val rows: Map<String, Row>)

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private var rows: MutableMap<String, Row>? = null

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    private fun loaded(): MutableMap<String, Row> = rows ?: runCatching {
        file.inputStream().buffered().use { json.decodeFromStream<Saved>(it) }.takeIf { it.format == FORMAT }?.rows?.toMutableMap()
    }.getOrNull().orEmpty().toMutableMap().also { rows = it }

    @Synchronized
    override fun getMany(ids: List<String>): Map<String, EnrichmentService.CacheRow> {
        val all = loaded()
        return ids.mapNotNull { id -> all[id]?.let { id to EnrichmentService.CacheRow(id, it.savedAtMs, it.record) } }.toMap()
    }

    @Synchronized
    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    override fun putMany(rows: List<EnrichmentService.CacheRow>) {
        val all = loaded()
        rows.forEach { all[it.tmdbID] = Row(it.savedAtMs, it.record) }
        val tmp = File(file.path + ".tmp")
        tmp.outputStream().buffered().use { json.encodeToStream(Saved(FORMAT, all), it) }
        tmp.renameTo(file)
    }

    companion object {
        private const val FORMAT = 1
    }
}

/** OMDBBackoff: the time OMDb may be asked again, kept across launches. */
private class PrefsBackoff(context: Context) : EnrichmentService.OmdbBackoff {
    private val prefs = context.getSharedPreferences("nostalgex", Context.MODE_PRIVATE)
    override fun blockedUntilMs() = prefs.getLong(KEY, 0L)
    override fun mark(nowMs: Long) {
        prefs.edit().putLong(KEY, EnrichmentService.nextUTCMidnight(nowMs)).apply()
    }

    companion object {
        /** The web tuner's localStorage key. */
        const val KEY = "nostalgex_omdb_blocked_until"
    }
}
