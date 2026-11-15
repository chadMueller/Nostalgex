package com.muellhaus.nostalgex

import android.content.Context
import com.muellhaus.nostalgex.engine.DeezerClient
import com.muellhaus.nostalgex.engine.MusicBrainzClient
import com.muellhaus.nostalgex.engine.MusicEnrichmentService
import com.muellhaus.nostalgex.engine.MusicFetch
import com.muellhaus.nostalgex.engine.MusicVideoEnrichment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit

/**
 * The two network calls behind music video genres (#319, the Apple TV's MusicBrainzService and DeezerService): musicbrainz.org
 * and api.deezer.com, over https, one request at a time per host and paced as the Apple TV paces them (MusicBrainz asks for
 * at most one a second). Nothing goes with a request but the URL (a song title, an artist, an id) and a User-Agent of
 * "Nostalgex/<version> (https://www.nostalgex.app)": no cookie, no token, no server address, no account identity.
 */
internal class MusicHttp(versionName: String) {
    private val userAgent = "Nostalgex/$versionName (https://www.nostalgex.app)"
    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .build()

    private class Pace(val gapMs: Long) {
        val lock = Mutex()
        var lastAt = 0L
    }
    private val pace = mapOf(MusicBrainzClient.HOST to Pace(1_050), DeezerClient.HOST to Pace(250))

    val fetch: MusicFetch = { url -> get(url) }

    private suspend fun get(url: String): String {
        val host = URI(url).host
        val p = pace[host] ?: throw IOException("not a music lookup host: $host")      // only these two hosts are ever asked
        p.lock.withLock {
            val wait = p.lastAt + p.gapMs - System.currentTimeMillis()
            if (wait > 0) delay(wait)
            p.lastAt = System.currentTimeMillis()
        }
        return withContext(Dispatchers.IO) {
            http.newCall(Request.Builder().url(url).header("User-Agent", userAgent).header("Accept", "application/json").build()).execute().use { res ->
                if (res.code != 200) throw IOException("HTTP ${res.code} from $host")
                res.body.string()
            }
        }
    }
}

/** The music videos' resolved rows, on the TV (`music_video_enrichments_v2.json`, the Apple TV's file name): no account, no server, only what the two sources said. */
internal class MusicEnrichmentStore(context: Context) {
    private val file = File(context.filesDir, "music_video_enrichments_v2.json")
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = MapSerializer(String.serializer(), MusicVideoEnrichment.serializer())

    fun load(): Map<String, MusicVideoEnrichment> =
        runCatching { json.decodeFromString(serializer, file.readText()) }.getOrDefault(emptyMap())

    fun save(rows: Map<String, MusicVideoEnrichment>) {
        runCatching {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json.encodeToString(serializer, rows))
            tmp.renameTo(file)
        }
    }
}

internal fun newMusicEnrichment(context: Context, versionName: String): Pair<MusicEnrichmentService, MusicEnrichmentStore> {
    val http = MusicHttp(versionName)
    val store = MusicEnrichmentStore(context)
    val service = MusicEnrichmentService(MusicBrainzClient(http.fetch), DeezerClient(http.fetch), log = { android.util.Log.i("Nostalgex", it) })
    service.cache.putAll(store.load())
    return service to store
}
