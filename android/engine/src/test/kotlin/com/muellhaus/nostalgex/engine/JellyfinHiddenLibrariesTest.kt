package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #224, INCLUDE LIBRARIES HIDDEN ON JELLYFIN, as the web tuner has it (scripts/nostalgex-jellyfin-library-smoke.mjs):
 * /UserViews leaves out the libraries a user hides from the home screen unless asked with
 * includeHidden=true. One switch, off by default; on, the hidden libraries are read like any other.
 */
class JellyfinHiddenLibrariesTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")

    /** The request paths every app is held to: `views` in scripts/jellyfin-library-golden.json. */
    @Test fun theListRequestIsTheSharedOne() {
        val cases = Json.parseToJsonElement(repoRoot.resolve("scripts/jellyfin-library-golden.json").readText())
            .jsonObject["views"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val got = MediaBrowserLibrary.userViewsPath(c["backend"]!!.jsonPrimitive.content, c["userId"]!!.jsonPrimitive.content,
                c["includeHidden"]!!.jsonPrimitive.boolean)
            assertEquals(c.toString(), c["path"]!!.jsonPrimitive.content, got)
        }
    }

    @Test fun theSwitchStartsOff() = assertFalse(MediaBrowserLibrary.INCLUDE_HIDDEN_DEFAULT)

    /**
     * Films and Shows on the home screen; Adult and Kept Shows hidden from it, listed only with
     * includeHidden=true; Locked, a library the user has no access to, listed in neither answer
     * (and refused if asked). Each film library holds one film, each show library one show of
     * two episodes.
     */
    private class Server(val backend: String = "jellyfin") {
        val requests = ArrayList<String>()
        val itemsAskedOf = LinkedHashSet<String>()

        fun library() = MediaBrowserLibrary({ path ->
            requests += path
            fun v(id: String, type: String) = JsonObject(mapOf("Id" to JsonPrimitive(id), "Name" to JsonPrimitive(id.uppercase()), "CollectionType" to JsonPrimitive(type)))
            fun page(rows: List<JsonObject>) = 200 to JsonObject(mapOf("Items" to JsonArray(rows), "TotalRecordCount" to JsonPrimitive(rows.size)))
            fun row(id: String, name: String, type: String, minutes: Long) = JsonObject(mapOf("Id" to JsonPrimitive(id), "Name" to JsonPrimitive(name),
                "Type" to JsonPrimitive(type), "RunTimeTicks" to JsonPrimitive(minutes * 60 * 10_000_000)))
            val shown = listOf(v("films", "movies"), v("shows", "tvshows"))
            val withHidden = listOf(v("films", "movies"), v("adult", "movies"), v("shows", "tvshows"), v("keptshows", "tvshows"))
            when {
                path.contains("Views") && path.contains("includeHidden=true") -> page(withHidden)
                path.contains("Views") -> page(shown)
                path.contains("/Items?") -> {
                    val parent = Regex("ParentId=([^&]+)").find(path)!!.groupValues[1]
                    itemsAskedOf += parent
                    when {
                        parent == "locked" -> 401 to null
                        parent.endsWith("shows") -> page(listOf(row("$parent-s", "$parent show", "Series", 0)))
                        parent.endsWith("shows-s") -> page((1..2).map { row("$parent$it", "$parent ep $it", "Episode", 22) })
                        else -> page(listOf(row("$parent-1", "$parent film", "Movie", 90)))
                    }
                }
                else -> 404 to null
            } as Pair<Int, JsonElement?>
        }, "u1", backend)
    }

    /** Off: the one plain list, exactly as Android always asked, and the hidden libraries are never read. */
    @Test fun offAsksWhatItAlwaysDid() {
        val s = Server()
        val items = s.library().scan(includeHidden = false)
        assertEquals(listOf("films-1", "shows-s1", "shows-s2"), items.map { it.ratingKey })
        assertEquals(listOf("/UserViews?userId=u1"), s.requests.filter { it.contains("Views") })
        assertTrue(s.requests.none { it.contains("includeHidden") })
        assertEquals(setOf("films", "shows", "shows-s"), s.itemsAskedOf)
    }

    /** On: the hidden libraries' films and episodes are read; the one without access is never asked. */
    @Test fun onReadsTheHiddenLibraries() {
        val s = Server()
        val items = s.library().scan(includeHidden = true)
        assertEquals(listOf("films-1", "adult-1", "shows-s1", "shows-s2", "keptshows-s1", "keptshows-s2"), items.map { it.ratingKey })
        assertEquals(listOf("/UserViews?userId=u1&includeHidden=true"), s.requests.filter { it.contains("Views") })
        assertFalse("a library the user can't access is never asked for items", "locked" in s.itemsAskedOf)
    }

    /** Off: library selection lists what the scan reads, one request. On: the hidden ones too, marked. */
    @Test fun librarySelectionFollowsTheSwitch() {
        val off = Server()
        val plain = off.library().sections("srv", "Server", includeHidden = false)
        assertEquals(listOf("films", "shows"), plain.map { it.key })
        assertTrue(plain.none { it.hidden })
        assertEquals(1, off.requests.size)

        val sections = Server().library().sections("srv", "Server", includeHidden = true)
        assertEquals(listOf("films", "adult", "shows", "keptshows"), sections.map { it.key })
        assertEquals(listOf(false, true, false, true), sections.map { it.hidden })
        assertEquals("Movies · HIDDEN ON JELLYFIN", sections[1].subtitle(multiServer = false))
        assertEquals("Movies", sections[0].subtitle(multiServer = false))
    }

    /** A library switched off in the picker stays off with the switch on. */
    @Test fun aHiddenLibrarySwitchedOffIsNotRead() {
        val s = Server()
        val items = s.library().scan(includeHidden = true, excluded = setOf("adult"))
        assertFalse(items.any { it.ratingKey == "adult-1" })
        assertFalse("adult" in s.itemsAskedOf)
    }

    /** Emby's list has no such switch: the same one request in both positions. */
    @Test fun embyIsTheSameEitherWay() {
        for (on in listOf(false, true)) {
            val s = Server(backend = "emby")
            assertEquals(listOf("films", "shows"), s.library().sections("srv", "Server", includeHidden = on).map { it.key })
            s.library().scan(includeHidden = on)
            assertTrue(s.requests.none { it.contains("includeHidden") })
            assertTrue(s.requests.filter { it.contains("Views") }.all { it == "/Users/u1/Views" })
        }
    }
}
