package com.muellhaus.nostalgex.mediabrowser

import android.os.Build
import android.util.Log
import com.muellhaus.nostalgex.engine.MediaBrowserLibrary
import com.muellhaus.nostalgex.engine.MediaItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit

/** A Jellyfin or Emby server signed in to: one at a time, as the Apple TV holds one backend. */
@Serializable
data class MediaBrowserServer(
    /** "jellyfin" or "emby". */
    val kind: String,
    val url: String,
    val name: String,
    val serverId: String,
    val userId: String,
    val token: String,
)

/** What a server says about itself before anyone types (SignInFlow.CheckedServer). */
data class CheckedServer(
    val kind: String,
    val url: String,
    val name: String,
    /** Null when the server won't say (older Jellyfin, or Emby). */
    val quickConnectEnabled: Boolean?,
    val users: List<PublicUser>,
) {
    /** Quick Connect first on a Jellyfin server that says it is on; Emby has none. */
    val prefersQuickConnect get() = kind == "jellyfin" && quickConnectEnabled == true
    /** Offered unless the server said it is off, so a server that can't say still gets it. */
    val offersQuickConnect get() = kind == "jellyfin" && quickConnectEnabled != false
}

data class PublicUser(val id: String, val name: String, val hasPassword: Boolean)

data class DiscoveredServer(val kind: String, val name: String, val address: String, val id: String)

/** HTTP failure from a MediaBrowser server, with its status. */
class MediaBrowserHttpException(val code: Int, what: String) : IOException("HTTP $code from $what")

/**
 * Jellyfin and Emby: the Apple TV's JellyfinAPIService and EmbyAPIService, SignInFlow and
 * LANServerDiscovery, and the web tuner's nostalgex-jellyfin-urls.js. One code path for both.
 */
class MediaBrowserClient(val deviceId: String, private val versionName: String) {
    private val http = OkHttpClient.Builder().connectTimeout(8, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()
    private val check = http.newBuilder().callTimeout(12, TimeUnit.SECONDS).build()
    private val json = Json { ignoreUnknownKeys = true }

    /** The MediaBrowser header on every request; the token once signed in. */
    fun authHeader(token: String? = null): String {
        val fields = mutableListOf("Client=\"Nostalgex\"", "Device=\"${Build.MODEL}\"", "DeviceId=\"$deviceId\"", "Version=\"$versionName\"")
        if (token != null) fields += "Token=\"$token\""
        return "MediaBrowser " + fields.joinToString(", ")
    }

    private fun request(url: String, token: String? = null) = Request.Builder().url(url)
        .header("Accept", "application/json")
        .header("Authorization", authHeader(token))

    private suspend fun send(req: Request, client: OkHttpClient = http): Pair<Int, String> = withContext(Dispatchers.IO) {
        client.newCall(req).execute().use { it.code to it.body.string() }
    }

    private suspend fun getJson(url: String, token: String? = null, client: OkHttpClient = http): JsonElement {
        val (code, body) = send(request(url, token).build(), client)
        if (code !in 200..299) throw MediaBrowserHttpException(code, url.substringBefore('?'))
        return json.parseToJsonElement(body)
    }

    private suspend fun postJson(url: String, body: JsonObject?, token: String? = null): Pair<Int, String> =
        send(request(url, token).post((body?.toString() ?: "").toRequestBody("application/json".toMediaType())).build())

    // ── Before signing in ────────────────────────────────────────────────

    /**
     * SignInFlow.check: who is at this address, and which way in it wants. A bare address
     * tries :8096 first, as ServerURLNormalizer.candidates. Null when something answered but
     * none of it is a Jellyfin or Emby server; the network error when nothing answered.
     */
    suspend fun check(address: String): CheckedServer? {
        var unreachable: IOException? = null
        var answered = false
        for (base in candidates(address)) {
            val info = try {
                getJson("$base/System/Info/Public", client = check) as? JsonObject
            } catch (e: MediaBrowserHttpException) {
                answered = true
                null
            } catch (e: IOException) {
                unreachable = e
                null
            } catch (e: Exception) {
                // An answer that isn't JSON: a web page, a proxy's login.
                answered = true
                null
            } ?: continue
            answered = true
            val id = (info["Id"] as? JsonPrimitive)?.content?.trim()?.ifEmpty { null } ?: continue
            // Jellyfin names itself in ProductName; Emby 4.x leaves it out.
            val product = (info["ProductName"] as? JsonPrimitive)?.content?.lowercase() ?: ""
            val kind = if ("jellyfin" in product) "jellyfin" else "emby"
            val name = (info["ServerName"] as? JsonPrimitive)?.content?.trim()?.ifEmpty { null } ?: displayName(kind)
            val quick = if (kind == "jellyfin") {
                runCatching {
                    val (code, body) = send(request("$base/QuickConnect/Enabled").build(), check)
                    if (code in 200..299) when (body.trim().lowercase()) { "true" -> true; "false" -> false; else -> null } else null
                }.getOrNull()
            } else null
            val users = runCatching { (getJson("$base/Users/Public", client = check) as? JsonArray) }.getOrNull()?.mapNotNull { e ->
                val u = e as? JsonObject ?: return@mapNotNull null
                val uid = (u["Id"] as? JsonPrimitive)?.content?.ifEmpty { null } ?: return@mapNotNull null
                val uname = (u["Name"] as? JsonPrimitive)?.content?.trim()?.ifEmpty { null } ?: return@mapNotNull null
                PublicUser(uid, uname, (u["HasPassword"] as? JsonPrimitive)?.booleanOrNull ?: true)
            } ?: emptyList()
            Log.i(TAG, "CHECK $kind \"$name\" quick connect $quick, ${users.size} public user(s)")
            return CheckedServer(kind, base, name, quick, users)
        }
        if (!answered && unreachable != null) throw unreachable
        return null
    }

    /**
     * LANServerDiscovery: "who is JellyfinServer?" (or EmbyServer) to UDP 7359, broadcast on
     * every interface's own broadcast address as well as the limited one, and every reply
     * collected for two seconds. Each server answers with its Address, Id and Name.
     */
    suspend fun discover(kind: String): List<DiscoveredServer> = withContext(Dispatchers.IO) {
        val probe = (if (kind == "emby") "who is EmbyServer?" else "who is JellyfinServer?").toByteArray()
        val found = LinkedHashMap<String, DiscoveredServer>()
        runCatching {
            DatagramSocket().use { socket ->
                socket.broadcast = true
                socket.soTimeout = 400
                val targets = mutableSetOf(InetAddress.getByName("255.255.255.255"))
                NetworkInterface.getNetworkInterfaces()?.toList()?.filter { it.isUp && !it.isLoopback }?.forEach { nif ->
                    nif.interfaceAddresses.mapNotNullTo(targets) { it.broadcast }
                }
                for (t in targets) runCatching { socket.send(DatagramPacket(probe, probe.size, t, 7359)) }
                val until = System.currentTimeMillis() + 2000
                val buf = ByteArray(4096)
                while (System.currentTimeMillis() < until) {
                    val packet = DatagramPacket(buf, buf.size)
                    try {
                        socket.receive(packet)
                    } catch (e: SocketTimeoutException) {
                        continue
                    }
                    val reply = runCatching { json.parseToJsonElement(String(packet.data, 0, packet.length)).jsonObject }.getOrNull() ?: continue
                    val id = (reply["Id"] as? JsonPrimitive)?.content ?: continue
                    val address = (reply["Address"] as? JsonPrimitive)?.content ?: continue
                    found.putIfAbsent(id, DiscoveredServer(kind, (reply["Name"] as? JsonPrimitive)?.content ?: displayName(kind), address, id))
                }
            }
        }.onFailure { Log.w(TAG, "Discovery failed", it) }
        Log.i(TAG, "DISCOVER $kind: ${found.size} server(s)")
        found.values.toList()
    }

    // ── Signing in ───────────────────────────────────────────────────────

    /** POST /Users/AuthenticateByName with {Username, Pw}. Null on a refused sign-in. */
    suspend fun signIn(server: CheckedServer, username: String, password: String): MediaBrowserServer? {
        val (code, body) = postJson("${server.url}/Users/AuthenticateByName", buildJsonObject { put("Username", username); put("Pw", password) })
        if (code == 401 || code == 403) return null
        if (code !in 200..299) throw MediaBrowserHttpException(code, "${server.url}/Users/AuthenticateByName")
        return session(server, json.parseToJsonElement(body).jsonObject)
    }

    data class QuickConnect(val code: String, val secret: String)

    /**
     * POST /QuickConnect/Initiate (Jellyfin 12 refuses a GET), GET only on 405 or 404 for older
     * servers. Throws MediaBrowserHttpException with the server's status when it says no.
     */
    suspend fun quickConnectInitiate(server: CheckedServer): QuickConnect {
        var (code, body) = postJson("${server.url}/QuickConnect/Initiate", null)
        if (code == 405 || code == 404) send(request("${server.url}/QuickConnect/Initiate").build()).let { code = it.first; body = it.second }
        if (code !in 200..299) throw MediaBrowserHttpException(code, "${server.url}/QuickConnect/Initiate")
        val o = json.parseToJsonElement(body).jsonObject
        val qcCode = (o["Code"] as? JsonPrimitive)?.content
        val secret = (o["Secret"] as? JsonPrimitive)?.content
        if (qcCode == null || secret == null) throw MediaBrowserHttpException(code, "${server.url}/QuickConnect/Initiate")
        return QuickConnect(qcCode, secret)
    }

    /** True once the code has been approved in Jellyfin. */
    suspend fun quickConnectApproved(server: CheckedServer, qc: QuickConnect): Boolean {
        val o = runCatching { getJson("${server.url}/QuickConnect/Connect?Secret=${qc.secret}") as? JsonObject }.getOrNull() ?: return false
        return (o["Authenticated"] as? JsonPrimitive)?.booleanOrNull == true
    }

    suspend fun quickConnectSignIn(server: CheckedServer, qc: QuickConnect): MediaBrowserServer? {
        val (code, body) = postJson("${server.url}/Users/AuthenticateWithQuickConnect", buildJsonObject { put("Secret", qc.secret) })
        if (code !in 200..299) return null
        return session(server, json.parseToJsonElement(body).jsonObject)
    }

    private suspend fun session(server: CheckedServer, auth: JsonObject): MediaBrowserServer? {
        val token = (auth["AccessToken"] as? JsonPrimitive)?.content ?: return null
        val user = auth["User"] as? JsonObject ?: return null
        val userId = (user["Id"] as? JsonPrimitive)?.content ?: return null
        val serverId = (auth["ServerId"] as? JsonPrimitive)?.content ?: (user["ServerId"] as? JsonPrimitive)?.content ?: ""
        Log.i(TAG, "SIGNED IN to ${server.kind} \"${server.name}\"")
        return MediaBrowserServer(server.kind, server.url, server.name, serverId, userId, token)
    }

    // ── The library and playback ─────────────────────────────────────────

    /**
     * The engine's scan over this server, as the web tuner's fetchJellyfinLibraryFromServer,
     * with the server stamped on each item for playback. Throws on a refused or failed read.
     */
    suspend fun scan(server: MediaBrowserServer, progress: MediaBrowserLibrary.Progress): List<MediaItem> = withContext(Dispatchers.IO) {
        val library = MediaBrowserLibrary({ path ->
            http.newCall(request(server.url + path, server.token).build()).execute().use { res ->
                if (res.code == 401 || res.code >= 500) throw MediaBrowserHttpException(res.code, server.url + path.substringBefore('?'))
                res.code to (if (res.isSuccessful) json.parseToJsonElement(res.body.string()) else null)
            }
        }, server.userId, server.kind)
        library.scan(progress).map { it.copy(serverUrl = server.url, serverToken = server.token) }
    }

    /** DELETE /Videos/ActiveEncodings: ends this app's encode, by its own session only. */
    fun stopEncoding(server: MediaBrowserServer, playSessionId: String) {
        val req = request("${server.url}/Videos/ActiveEncodings?deviceId=$deviceId&playSessionId=$playSessionId", server.token).delete().build()
        http.newCall(req).enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: IOException) {}
            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) = response.close()
        })
    }

    companion object {
        private const val TAG = "Nostalgex"

        fun displayName(kind: String) = if (kind == "emby") "Emby" else "Jellyfin"

        /** ServerURLNormalizer.candidates: http and :8096 first for a bare host, else as typed. */
        fun candidates(raw: String): List<String> {
            var s = raw.trim().trimEnd('/')
            if (s.isEmpty()) return emptyList()
            val hasScheme = s.contains("://")
            if (!hasScheme) s = "http://$s"
            s = s.removeSuffix("/web").removeSuffix("/web/index.html").trimEnd('/')
            val afterScheme = s.substringAfter("://")
            val hostPort = afterScheme.substringBefore('/')
            val hasPort = hostPort.substringAfterLast(']').contains(':')
            val hasPath = afterScheme.contains('/')
            return if (!hasPort && s.startsWith("http://") && !hasPath) listOf(s.replaceFirst(hostPort, "$hostPort:8096"), s) else listOf(s)
        }
    }
}
