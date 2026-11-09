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
 * Libraries a user hides from the Jellyfin home screen (the Apple TV's JellyfinHiddenLibrariesTests):
 * /UserViews leaves them out unless asked with includeHidden=true. They are listed, marked
 * hidden, and read only once the viewer switches them on.
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

    /**
     * Films and Docs on the home screen, Adult hidden from it: the list names Adult only when
     * asked with includeHidden. `failHidden` makes that request fail. Each library holds one film.
     */
    private class Server(val backend: String = "jellyfin", val failHidden: Boolean = false) {
        val requests = ArrayList<String>()
        fun library() = MediaBrowserLibrary({ path ->
            requests += path
            val v = { id: String -> JsonObject(mapOf("Id" to JsonPrimitive(id), "Name" to JsonPrimitive(id.uppercase()), "CollectionType" to JsonPrimitive("movies"))) }
            when {
                path.contains("Views") && path.contains("includeHidden=true") ->
                    if (failHidden) 500 to null
                    else 200 to JsonObject(mapOf("Items" to JsonArray(listOf(v("films"), v("adult"), v("docs")))))
                path.contains("Views") -> 200 to JsonObject(mapOf("Items" to JsonArray(listOf(v("films"), v("docs")))))
                path.contains("/Items?") -> {
                    val parent = Regex("ParentId=([^&]+)").find(path)!!.groupValues[1]
                    200 to JsonObject(mapOf(
                        "Items" to JsonArray(listOf(JsonObject(mapOf("Id" to JsonPrimitive("$parent-1"), "Name" to JsonPrimitive("$parent film"),
                            "Type" to JsonPrimitive("Movie"), "RunTimeTicks" to JsonPrimitive(90L * 60 * 10_000_000))))),
                        "TotalRecordCount" to JsonPrimitive(1),
                    ))
                }
                else -> 404 to null
            } as Pair<Int, JsonElement?>
        }, "u1", backend)
    }

    @Test fun aHiddenLibraryIsListedAndMarked() {
        val sections = Server().library().sections("srv", "Server")
        assertEquals(listOf("films", "adult", "docs"), sections.map { it.key })
        assertEquals(listOf(false, true, false), sections.map { it.hidden })
        assertEquals("Movies · HIDDEN ON JELLYFIN", sections[1].subtitle(multiServer = false))
        assertEquals("Movies", sections[0].subtitle(multiServer = false))
    }

    @Test fun whenTheHiddenListFailsThePlainListStands() {
        val sections = Server(failHidden = true).library().sections("srv", "Server")
        assertEquals(listOf("films", "docs"), sections.map { it.key })
        assertTrue(sections.none { it.hidden })
    }

    /** Off by default: the scan asks exactly what it always did and never reads the hidden library. */
    @Test fun aScanLeavesAHiddenLibraryOutUntilItIsSwitchedOn() {
        assertFalse(LibrarySection.HIDDEN_ON_BY_DEFAULT)
        val s = Server()
        val items = s.library().scan()
        assertEquals(listOf("films-1", "docs-1"), items.map { it.ratingKey })
        assertTrue(s.requests.none { it.contains("includeHidden") })
    }

    @Test fun aSwitchedOnHiddenLibraryIsRead() {
        val items = Server().library().scan(includedHidden = setOf("adult"))
        assertEquals(listOf("films-1", "adult-1", "docs-1"), items.map { it.ratingKey })
    }

    /** Emby's list has no such switch: one request, no includeHidden. */
    @Test fun embyIsUnchanged() {
        val s = Server(backend = "emby")
        val sections = s.library().sections("srv", "Server")
        assertEquals(listOf("films", "docs"), sections.map { it.key })
        assertTrue(s.requests.none { it.contains("includeHidden") })
    }
}
