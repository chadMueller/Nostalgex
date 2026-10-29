package com.muellhaus.nostalgex.plex

import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

@Serializable
data class PlexServer(val name: String, val machineIdentifier: String, val url: String, val token: String, val owned: Boolean = true)

data class PlexPin(val id: Long, val code: String)

/**
 * plex.tv sign-in and the server API, as plex-tuner.html does them (startPlexAuth,
 * discoverServers, findWorkingConnection, plexLibraryFetchForServer).
 */
/** A server or plex.tv answered with an HTTP error. */
class PlexHttpException(val code: Int, url: String) : IOException("HTTP $code from $url")

class PlexClient(private val clientId: String, versionName: String) {
    /** How many servers the last discovery found, reachable or not, for the error that says so. */
    var lastServerCount = 0
        private set

    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private val json = Json { ignoreUnknownKeys = true }

    val headers = mapOf(
        "Accept" to "application/json",
        "X-Plex-Product" to "Nostalgex",
        "X-Plex-Version" to versionName,
        "X-Plex-Platform" to "Android",
        "X-Plex-Device" to "Android TV",
        "X-Plex-Device-Name" to Build.MODEL,
        "X-Plex-Client-Identifier" to clientId,
    )

    private fun request(url: String, token: String? = null) = Request.Builder().url(url).apply {
        headers.forEach { (k, v) -> header(k, v) }
        if (token != null) header("X-Plex-Token", token)
    }

    private suspend fun getJson(url: String, token: String? = null, client: OkHttpClient = http): JsonElement = withContext(Dispatchers.IO) {
        client.newCall(request(url, token).build()).execute().use { res ->
            if (!res.isSuccessful) throw PlexHttpException(res.code, url.substringBefore('?'))
            json.parseToJsonElement(res.body.string())
        }
    }

    suspend fun createPin(): PlexPin = withContext(Dispatchers.IO) {
        val req = request("https://plex.tv/api/v2/pins?strong=false").post(ByteArray(0).toRequestBody()).build()
        http.newCall(req).execute().use { res ->
            if (!res.isSuccessful) throw IOException("PIN request failed: ${res.code}")
            val o = json.parseToJsonElement(res.body.string()).jsonObject
            PlexPin(o["id"]!!.jsonPrimitive.longOrNull!!, o["code"]!!.jsonPrimitive.content.uppercase())
        }
    }

    /** The account token once the code has been entered at plex.tv/link, else null. */
    suspend fun pollPin(pin: PlexPin): String? {
        val o = getJson("https://plex.tv/api/v2/pins/${pin.id}").jsonObject
        return (o["authToken"] as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() && it != "null" }
    }

    /**
     * The account's servers, each on the first address that answers /identity. At sign-in, owned
     * servers only when there are any: shared servers can be most of a first load (the Roku
     * port's rule). Settings asks for all of them (`includeShared`), to switch any on.
     */
    suspend fun discoverServers(accountToken: String, includeShared: Boolean = false): List<PlexServer> = coroutineScope {
        val resources = getJson("https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", accountToken).jsonArray
            .map { it.jsonObject }
            .filter { r -> (r["provides"] as? JsonPrimitive)?.content?.split(',')?.contains("server") == true }
            .also { lastServerCount = it.size }
        val owned = resources.filter { (it["owned"] as? JsonPrimitive)?.booleanOrNull == true }
        (if (includeShared) resources else owned.ifEmpty { resources }).map { r ->
            async {
                val token = (r["accessToken"] as? JsonPrimitive)?.content ?: accountToken
                val url = findWorkingConnection(r, token) ?: return@async null
                PlexServer(
                    name = r["name"]?.jsonPrimitive?.content ?: "Plex",
                    machineIdentifier = (r["clientIdentifier"] as? JsonPrimitive)?.content ?: "",
                    url = url,
                    token = token,
                    owned = (r["owned"] as? JsonPrimitive)?.booleanOrNull == true,
                )
            }
        }.awaitAll().filterNotNull()
    }

    private val probe = http.newBuilder().callTimeout(5, TimeUnit.SECONDS).build()

    /** Every address at once; the first in the web's order (HTTPS direct, then local) that answers. */
    private suspend fun findWorkingConnection(resource: JsonObject, token: String): String? = coroutineScope {
        data class Conn(val uri: String, val local: Boolean, val relay: Boolean, val https: Boolean)
        val conns = resource["connections"]?.jsonArray?.map { it.jsonObject }?.map { c ->
            Conn(
                c["uri"]!!.jsonPrimitive.content,
                (c["local"] as? JsonPrimitive)?.booleanOrNull == true,
                (c["relay"] as? JsonPrimitive)?.booleanOrNull == true,
                (c["protocol"] as? JsonPrimitive)?.content == "https",
            )
        } ?: return@coroutineScope null
        val sorted = conns.sortedWith { a, b ->
            val aDirect = !a.relay && a.https
            val bDirect = !b.relay && b.https
            when {
                aDirect && !bDirect -> -1
                bDirect && !aDirect -> 1
                a.local && !b.local -> -1
                b.local && !a.local -> 1
                else -> 0
            }
        }
        val results = sorted.map { c -> async { c to runCatching { getJson("${c.uri}/identity", token, probe) }.isSuccess } }.awaitAll()
        results.firstOrNull { it.second }?.first?.uri
    }

    suspend fun get(server: PlexServer, path: String): JsonObject =
        getJson("${server.url}$path", server.token).jsonObject

    /** Ends a transcode this app started, by its own session id only. */
    fun stopTranscode(server: String, token: String, session: String) {
        val url = "$server/video/:/transcode/universal/stop".toHttpUrl().newBuilder()
            .addQueryParameter("session", session)
            .addQueryParameter("X-Plex-Token", token)
            .build()
        http.newCall(Request.Builder().url(url).build()).enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: IOException) {}
            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) = response.close()
        })
    }

    companion object {
        fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString || it.content != "null" }?.content
        fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.let { it.longOrNull ?: it.content.toDoubleOrNull()?.toLong() }
    }
}
