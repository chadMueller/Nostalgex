package com.muellhaus.nostalgex

import android.content.SharedPreferences
import com.muellhaus.nostalgex.engine.PlexLocal
import com.muellhaus.nostalgex.plex.PlexClient
import com.muellhaus.nostalgex.plex.PlexHttpException
import com.muellhaus.nostalgex.plex.PlexServer
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList

/**
 * I-057, LOCAL SERVER (NO PLEX.TV), one test per credential path (the Apple TV's LocalPlexSignInTests): the sign-in saved and read back
 * with no token, sign-out, the address check against a stand-in server (identity, libraries with no token, a 401), and the requests,
 * which leave X-Plex-Token out when there is none. The real Prefs over an in-memory store, the real PlexClient over a local server.
 */
class LocalPlexSignInTest {
    // ── The saved sign-in ──

    internal class MemoryPrefs : SharedPreferences {
        val values = HashMap<String, Any?>()
        override fun getAll(): MutableMap<String, *> = HashMap(values)
        override fun getString(key: String, defValue: String?) = values[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?) = values[key] as? MutableSet<String> ?: defValues
        override fun getInt(key: String, defValue: Int) = values[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long) = values[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float) = values[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean) = values[key] as? Boolean ?: defValue
        override fun contains(key: String) = values.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removed = HashSet<String>()
            private var clear = false
            override fun putString(key: String, value: String?) = apply { pending[key] = value }
            override fun putStringSet(key: String, value: MutableSet<String>?) = apply { pending[key] = value }
            override fun putInt(key: String, value: Int) = apply { pending[key] = value }
            override fun putLong(key: String, value: Long) = apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
            override fun remove(key: String) = apply { removed += key }
            override fun clear() = apply { clear = true }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() {
                if (clear) values.clear()
                removed.forEach { values.remove(it) }
                pending.forEach { (k, v) -> if (v == null) values.remove(k) else values[k] = v }
            }
        }
    }

    private val den = PlexServer("Den", "machine-a", "http://192.168.1.10:32400", token = "")

    @Test fun theLocalSignInIsSavedAndSurvivesARelaunchWithNoToken() {
        val store = MemoryPrefs()
        val prefs = Prefs(store)
        assertFalse(prefs.plexSignedIn)
        prefs.saveLocalPlexSignIn(den)
        assertTrue(prefs.plexSignedIn)
        assertTrue(prefs.plexNoPlexTv)
        assertEquals("", prefs.plexToken)

        // A relaunch is a new Prefs over the same file.
        val relaunched = Prefs(store)
        assertTrue("the sign-in survives a relaunch", relaunched.plexSignedIn)
        assertTrue(relaunched.plexNoPlexTv)
        assertEquals("", relaunched.plexToken)
        assertEquals(listOf(den), relaunched.servers)
        assertFalse("no plex.tv call is made for it", PlexLocal.asksPlexTv(relaunched.plexNoPlexTv))
    }

    @Test fun signOutClearsItAndAPlexTvSignInAfterwardsIsAnOrdinaryOne() {
        val store = MemoryPrefs()
        val prefs = Prefs(store)
        prefs.saveLocalPlexSignIn(den)
        prefs.signOut()
        assertFalse(prefs.plexSignedIn)
        assertFalse(prefs.plexNoPlexTv)
        assertNull(prefs.plexToken)
        assertEquals(emptyList<PlexServer>(), prefs.servers)
        assertFalse("signed out stays signed out", Prefs(store).plexSignedIn)

        val account = PlexServer("Den", "machine-a", "http://192.168.1.10:32400", token = "server-token")
        prefs.saveAccountSignIn("account-token", listOf(account))
        assertTrue(prefs.plexSignedIn)
        assertFalse("the flag is gone", prefs.plexNoPlexTv)
        assertEquals("account-token", prefs.plexToken)
        assertTrue(PlexLocal.asksPlexTv(prefs.plexNoPlexTv))
    }

    @Test fun aPlexTvSignInReplacesALocalOneAndTheOtherWayRound() {
        val prefs = Prefs(MemoryPrefs())
        prefs.saveLocalPlexSignIn(den)
        prefs.saveAccountSignIn("account-token", listOf(den.copy(token = "t")))
        assertFalse(prefs.plexNoPlexTv)
        assertEquals("account-token", prefs.plexToken)
        prefs.saveLocalPlexSignIn(den)
        assertTrue(prefs.plexNoPlexTv)
        assertEquals("", prefs.plexToken)
        assertEquals(listOf(den), prefs.servers)
    }

    @Test fun aSavedTokenWithNoServersIsNotASignIn() {
        val prefs = Prefs(MemoryPrefs())
        prefs.plexToken = "account-token"
        assertFalse(prefs.plexSignedIn)
    }

    // ── The address check and the requests ──

    private class Seen(val path: String, val token: String?, val queryToken: String?, val product: String?)

    private lateinit var server: HttpServer
    private val seen = CopyOnWriteArrayList<Seen>()
    @Volatile private var sectionsStatus = 200
    @Volatile private var identityBody: String? = """{"MediaContainer":{"machineIdentifier":"stub-machine","version":"1.43.5"}}"""
    @Volatile private var identityStatus = 200
    private val client by lazy { PlexClient("client-id", "1.0.0") }
    private val base get() = "http://127.0.0.1:${server.address.port}"

    @Before fun start() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { ex ->
            val query = ex.requestURI.rawQuery.orEmpty()
            seen += Seen(ex.requestURI.path, ex.requestHeaders.getFirst("X-Plex-Token"), query.split('&').firstOrNull { it.startsWith("X-Plex-Token=") }, ex.requestHeaders.getFirst("X-Plex-Product"))
            val (status, body) = when (ex.requestURI.path) {
                "/identity" -> identityStatus to (identityBody ?: "")
                "/library/sections" -> sectionsStatus to if (sectionsStatus == 200) """{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}""" else "<html>Unauthorized</html>"
                "/" -> 200 to """{"MediaContainer":{"friendlyName":"Basement Plex","machineIdentifier":"stub-machine"}}"""
                else -> 200 to """{"MediaContainer":{}}"""
            }
            val bytes = body.toByteArray()
            ex.sendResponseHeaders(status, if (bytes.isEmpty()) -1 else bytes.size.toLong())
            if (bytes.isNotEmpty()) ex.responseBody.use { it.write(bytes) } else ex.responseBody.close()
        }
        server.start()
    }

    @After fun stop() = server.stop(0)

    @Test fun theServerIsCheckedByItsIdentityThenItsLibrariesWithNoToken() {
        val found = runBlocking { client.checkLocalServer(base) }
        assertEquals("stub-machine", found.machineIdentifier)
        assertEquals("Basement Plex", found.name)
        assertEquals(listOf("/identity", "/library/sections", "/"), seen.map { it.path })
        assertTrue("no X-Plex-Token header on any of them: ${seen.map { it.token }}", seen.all { it.token == null && it.queryToken == null })
        assertTrue(seen.all { it.product == "Nostalgex" })
    }

    @Test fun a401OnTheLibrariesSaysPlexsSettingAndANoAuthServerIsNeverSignedIn() {
        for (status in listOf(401, 403)) {
            sectionsStatus = status
            seen.clear()
            val e = runCatching { runBlocking { client.checkLocalServer(base) } }.exceptionOrNull()
            assertTrue("$status: ${e?.javaClass}", e is PlexClient.PlexUnauthorizedException)
            assertEquals(status, (e as PlexClient.PlexUnauthorizedException).code)
            // It stopped at the libraries: the name is not asked for.
            assertEquals(listOf("/identity", "/library/sections"), seen.map { it.path })
        }
        assertTrue(PlexLocal.NEEDS_AUTH_MESSAGE.contains("List of IP addresses and networks that are allowed without auth"))
    }

    @Test fun anAddressThatIsNotPlexIsTurnedDown() {
        identityBody = "<html><body>Router login</body></html>"
        val e = runCatching { runBlocking { client.checkLocalServer(base) } }.exceptionOrNull()
        assertTrue(e is PlexClient.NotPlexException)
        assertEquals(listOf("/identity"), seen.map { it.path })
        identityStatus = 404
        assertTrue(runCatching { runBlocking { client.checkLocalServer(base) } }.exceptionOrNull() is PlexHttpException)
    }

    @Test fun serverErrorsOnTheLibrariesAreHttpFailuresNotSignInProblems() {
        sectionsStatus = 500
        val e = runCatching { runBlocking { client.checkLocalServer(base) } }.exceptionOrNull()
        assertTrue(e is PlexHttpException)
        assertEquals(500, (e as PlexHttpException).code)
    }

    @Test fun nothingAnsweringIsAnIoError() {
        val port = server.address.port
        server.stop(0)
        val e = runCatching { runBlocking { client.checkLocalServer("http://127.0.0.1:$port") } }.exceptionOrNull()
        assertTrue(e is java.io.IOException && e !is PlexClient.PlexUnauthorizedException && e !is PlexClient.NotPlexException)
    }

    @Test fun requestsLeaveTheTokenHeaderOutWhenThereIsNone() {
        for (none in listOf("", null)) assertNull("token=$none", client.requestFor("$base/library/sections", none).header("X-Plex-Token"))
        assertEquals("t", client.requestFor("$base/library/sections", "t").header("X-Plex-Token"))
        assertEquals("client-id", client.requestFor("$base/x", "").header("X-Plex-Client-Identifier"))
    }

    @Test fun libraryCallsFromALocalServerCarryNoTokenAndAnAccountServerStillDoes() {
        runBlocking { client.get(PlexServer("Den", "m", base, token = ""), "/library/sections") }
        assertNull(seen.last().token)
        runBlocking { client.get(PlexServer("Den", "m", base, token = "server-token"), "/library/sections") }
        assertEquals("server-token", seen.last().token)
    }

    @Test fun theOtherPlexCallsOmitAnEmptyTokenFromTheirQuery() {
        client.audioStreams(base, "", "42")
        assertNull(seen.last { it.path == "/library/metadata/42" }.queryToken)
        client.audioStreams(base, "tok", "43")
        assertNotNull(seen.last { it.path == "/library/metadata/43" }.queryToken)
        client.stopTranscode(base, "", "session-1")
        client.stopTranscode(base, "tok", "session-2")
        Thread.sleep(500)
        val stops = seen.filter { it.path == "/video/:/transcode/universal/stop" }
        assertEquals(2, stops.size)
        assertEquals(1, stops.count { it.queryToken == null })
        assertEquals(1, stops.count { it.queryToken == "X-Plex-Token=tok" })
    }
}
