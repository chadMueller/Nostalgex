package com.muellhaus.nostalgex.plex

import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import android.os.SystemClock
import android.util.Log
import com.muellhaus.nostalgex.engine.ServerResolve
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
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import com.muellhaus.nostalgex.engine.PlexUtf8Repair
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

@Serializable
data class PlexServer(val name: String, val machineIdentifier: String, val url: String, val token: String, val owned: Boolean = true)

/** A plex.tv/link code; `expiresIn` is how long plex.tv keeps it, in seconds, when it says (#284). */
data class PlexPin(val id: Long, val code: String, val expiresIn: Long? = null)

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

    /**
     * A Plex answer as JSON. Its bytes are read and repaired first (PlexUtf8Repair, #196): Plex
     * copies a Latin-1 file name into a title byte for byte, and decoding that as UTF-8 showed
     * "Caf\uFFFD Society". A valid answer is decoded as it is; a repaired one logs the Apple TV's line.
     */
    private suspend fun getJson(url: String, token: String? = null, client: OkHttpClient = http): JsonElement = withContext(Dispatchers.IO) {
        client.newCall(request(url, token).build()).execute().use { res ->
            if (!res.isSuccessful) throw PlexHttpException(res.code, url.substringBefore('?'))
            val decoded = PlexUtf8Repair.decode(res.body.bytes())
            if (decoded.repairedBytes > 0) Log.i(TAG, PlexUtf8Repair.logLine(logContext(url), decoded.repairedBytes))
            json.parseToJsonElement(decoded.text)
        }
    }

    /** The request's path and query with any token left out, for the log (PlexAPIService.logContext). */
    private fun logContext(url: String): String {
        val u = url.toHttpUrlOrNull() ?: return "?"
        val query = (0 until u.querySize).filter { !u.queryParameterName(it).lowercase().contains("token") }
            .joinToString("&") { "${u.queryParameterName(it)}=${u.queryParameterValue(it) ?: ""}" }
        return u.encodedPath + if (query.isEmpty()) "" else "?$query"
    }

    suspend fun createPin(): PlexPin = withContext(Dispatchers.IO) {
        val req = request("https://plex.tv/api/v2/pins?strong=false").post(ByteArray(0).toRequestBody()).build()
        http.newCall(req).execute().use { res ->
            if (!res.isSuccessful) throw IOException("PIN request failed: ${res.code}")
            val o = json.parseToJsonElement(res.body.string()).jsonObject
            PlexPin(o["id"]!!.jsonPrimitive.longOrNull!!, o["code"]!!.jsonPrimitive.content.uppercase(), (o["expiresIn"] as? JsonPrimitive)?.longOrNull)
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

    /**
     * The address to use for one server: every address asked at once, and no more waiting once the
     * answer cannot change (ServerResolve, the Apple TV's bestReachableURI and Roku's
     * NxResolveOutcome, through the web tuner's nostalgex-server-resolve.js). Home network first,
     * then remote HTTPS, remote plain, relay. A home answer settles at once; a home address silent
     * for 3 s stops holding up a remote answer; 10 s ends the wait. The probes still waiting are
     * cancelled when it settles. A probe is /identity with a 5 s timeout, as the web's, and an
     * address that answers as a different Plex server is turned down.
     */
    private suspend fun findWorkingConnection(resource: JsonObject, token: String): String? {
        val machineId = (resource["clientIdentifier"] as? JsonPrimitive)?.content
        val conns = resource["connections"]?.jsonArray?.map { it.jsonObject }?.map { c ->
            ServerResolve.Conn(
                (c["uri"] as? JsonPrimitive)?.content ?: "",
                (c["local"] as? JsonPrimitive)?.booleanOrNull == true,
                (c["relay"] as? JsonPrimitive)?.booleanOrNull == true,
            )
        } ?: return null
        val resolver = ServerResolve.Resolver(conns)
        resolver.result?.let { return null }
        val started = SystemClock.elapsedRealtime()
        fun elapsed() = SystemClock.elapsedRealtime() - started
        // Every probe and timer reports here; the resolver is read on one coroutine only.
        val events = Channel<() -> ServerResolve.Outcome?>(Channel.UNLIMITED)
        val calls = java.util.concurrent.ConcurrentLinkedQueue<okhttp3.Call>()
        // Why each address failed, for the log: refused, timed out, an HTTP status, or another server.
        val why = java.util.concurrent.ConcurrentHashMap<String, String>()
        val name = resource["name"]?.jsonPrimitive?.content ?: "Plex"
        return coroutineScope {
            val graceJob = launch { delay(resolver.graceMs); events.send { resolver.graceFired(elapsed()) } }
            val deadlineJob = launch { delay(resolver.deadlineMs); events.send { resolver.expired(elapsed()) } }
            for (c in resolver.candidates) {
                val call = probe.newCall(request("${c.conn.uri}/identity", token).build())
                calls += call
                call.enqueue(object : okhttp3.Callback {
                    override fun onFailure(call: okhttp3.Call, e: IOException) {
                        if (!call.isCanceled()) why[c.kind] = (why[c.kind]?.let { "$it, " } ?: "") + (e::class.simpleName ?: "error")
                        events.trySend { resolver.report(c, false, elapsed()) }
                    }
                    override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                        val ok = response.use { res ->
                            res.isSuccessful && runCatching {
                                val mc = json.parseToJsonElement(res.body.string()).jsonObject["MediaContainer"] as? JsonObject
                                ServerResolve.identityMatches((mc?.get("machineIdentifier") as? JsonPrimitive)?.content, machineId)
                            }.getOrDefault(true).also { if (!it) why[c.kind] = (why[c.kind]?.let { w -> "$w, " } ?: "") + "another server" }
                        }
                        if (!response.isSuccessful) why[c.kind] = (why[c.kind]?.let { "$it, " } ?: "") + "HTTP ${response.code}"
                        events.trySend { resolver.report(c, ok, elapsed()) }
                    }
                })
            }
            var out: ServerResolve.Outcome? = null
            while (out == null) out = events.receive()()
            graceJob.cancel()
            deadlineJob.cancel()
            calls.forEach { it.cancel() }
            Log.i(TAG, "SERVER ADDRESS \"$name\": ${out.conn?.let { "${out.kind} ${it.uri.substringBefore("://")}" } ?: "none answered"} in ${elapsed()} ms of ${resolver.candidates.size} tried" +
                (if (why.isEmpty()) "" else "; failed: " + why.entries.joinToString("; ") { "${it.key} ${it.value}" }))
            out.conn?.uri
        }
    }

    suspend fun get(server: PlexServer, path: String): JsonObject =
        getJson("${server.url}$path", server.token).jsonObject

    /**
     * The server's collections from its movie and TV sections (nostalgex-collections.js
     * fetchPlexCollections), each with its members' keys. The server key is its address, as
     * the library's items carry it (`serverUrl`), so members resolve against this server only.
     */
    suspend fun collections(server: PlexServer): List<com.muellhaus.nostalgex.engine.ServerCollection> = withContext(Dispatchers.IO) {
        com.muellhaus.nostalgex.engine.Collections.fetchPlexCollections(server.url, { path -> kotlinx.coroutines.runBlocking { get(server, path) } })
    }

    /**
     * Asks Plex's decision for a server stream before starting it, with the same query and
     * session (`/video/:/transcode/universal/decision`). Plex 1.43.5 refuses a start.m3u8 whose
     * session has no decision ("Denying access due to session lacking decision for transcode")
     * once this client has started that file before: measured on a lab server, a second tune of
     * the same film within minutes answered HTTP 400 and the card said the server wouldn't start
     * it; with the decision asked first, 4 of 4 starts answered 200. Blocking: call it off the
     * main thread. Returns the HTTP status and body, or null when nothing answered.
     */
    fun decision(startUrl: String): Pair<Int, String>? = runCatching {
        val url = startUrl.replace("/video/:/transcode/universal/start.m3u8", "/video/:/transcode/universal/decision")
        decisionHttp.newCall(Request.Builder().url(url).build()).execute().use { it.code to (it.body?.string() ?: "") }
    }.getOrNull()

    /** At most 5 s: the startup watchdog only begins once the stream loads. */
    private val decisionHttp by lazy { http.newBuilder().callTimeout(5, java.util.concurrent.TimeUnit.SECONDS).build() }

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
        private const val TAG = "Nostalgex"
        fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString || it.content != "null" }?.content
        fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.let { it.longOrNull ?: it.content.toDoubleOrNull()?.toLong() }
    }
}
