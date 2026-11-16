package com.muellhaus.nostalgex

import android.content.Context
import com.muellhaus.nostalgex.engine.LiveChannels
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * The Android side of [LiveChannels] (N-074): the last good copy in the app's own files, written whole to a temporary file and renamed,
 * and one OkHttp GET with a short timeout. The bundled copy is read from the assets, as before.
 */
object LiveChannelsSetup {
    fun create(context: Context): LiveChannels = LiveChannels(
        bundledText = { context.assets.open("channels.json").bufferedReader().use { it.readText() } },
        cache = FileCache(File(context.filesDir, "channels-live.json")),
        fetch = Fetch::get,
    )

    private class FileCache(private val file: File) : LiveChannels.Cache {
        override fun read(): String? = runCatching { file.takeIf { it.isFile }?.readText() }.getOrNull()
        override fun write(text: String) {
            val tmp = File(file.path + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) { tmp.delete(); throw java.io.IOException("could not move the copy into place") }
        }
    }

    private object Fetch {
        private val client = OkHttpClient.Builder()
            .callTimeout(LiveChannels.TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .build()

        fun get(url: String): String? =
            client.newCall(Request.Builder().url(url).header("Accept", "application/json").build()).execute().use { r ->
                if (!r.isSuccessful) return null
                // A file that is not a channels.json by size is refused before it is read whole.
                val len = r.body.contentLength()
                if (len > LiveChannels.MAX_CHARS) return null
                r.body.string()
            }
    }
}
