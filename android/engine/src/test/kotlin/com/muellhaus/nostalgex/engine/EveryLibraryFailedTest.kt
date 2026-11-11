package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * #198: a scan where every library errors is a failed scan, not an empty library to save. One
 * library that errors among others still leaves the rest, and a library that answers with
 * nothing is read, not failed.
 */
class EveryLibraryFailedTest {
    private fun view(id: String, type: String) = JsonObject(mapOf(
        "Id" to JsonPrimitive(id), "Name" to JsonPrimitive(id), "CollectionType" to JsonPrimitive(type),
    ))

    private fun film(i: Int) = JsonObject(mapOf(
        "Id" to JsonPrimitive("m$i"), "Name" to JsonPrimitive("Film $i"), "Type" to JsonPrimitive("Movie"),
        "RunTimeTicks" to JsonPrimitive(90L * 60 * 10_000_000),
    ))

    /** Views `films` and `docs`, each with `perLibrary` films; a parent in `failing` answers HTTP 500. */
    private fun server(failing: Set<String>, perLibrary: Int = 3) = MediaBrowserLibrary({ path ->
        when {
            path.contains("Views") -> 200 to JsonObject(mapOf("Items" to JsonArray(listOf(view("films", "movies"), view("docs", "movies")))))
            path.contains("/Items?") -> {
                val parent = Regex("ParentId=([^&]+)").find(path)!!.groupValues[1]
                if (parent in failing) 500 to null
                else 200 to JsonObject(mapOf(
                    "Items" to JsonArray((0 until perLibrary).map { film(it + if (parent == "docs") 100 else 0) }),
                    "TotalRecordCount" to JsonPrimitive(perLibrary),
                ))
            }
            else -> 404 to null
        } as Pair<Int, JsonElement?>
    }, "u1", "jellyfin")

    @Test fun everyLibraryFailingFailsTheScanWithTheFirstError() {
        try {
            server(setOf("films", "docs")).scan()
            fail("every library failed, so the scan should have")
        } catch (e: EveryLibraryFailed) {
            assertTrue(e.cause.message, e.cause.message!!.contains("films"))
        }
    }

    @Test fun oneFailingLibraryLeavesTheRest() {
        val items = server(setOf("docs")).scan()
        assertEquals(listOf("m0", "m1", "m2"), items.map { it.ratingKey })
    }

    @Test fun anEmptyLibraryIsReadNotFailed() {
        assertTrue(server(emptySet(), perLibrary = 0).scan().isEmpty())
        // An empty library and a failing one: something was read, so no failure, and nothing to show.
        assertTrue(server(setOf("docs"), perLibrary = 0).scan().isEmpty())
    }

    @Test fun theTally() {
        SectionTally().check()
        SectionTally().apply { read(); failed(RuntimeException("a")) }.check()
        try {
            SectionTally().apply { failed(RuntimeException("first")); failed(RuntimeException("second")) }.check()
            fail()
        } catch (e: EveryLibraryFailed) {
            assertEquals("first", e.cause.message)
        }
    }
}
