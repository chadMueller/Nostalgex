package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** #288, from fake sections: the Apple TV's LibraryScanProgressTests and LibraryScanResumeTests cases. */
class ScanResumeTest {
    private val now = 1_800_000_000L
    private fun kept(ageSec: Long = 60, build: Int = 5, stamp: String? = "u1/c1") =
        ScanResume.Kept("srv", "1", now - ageSec, build, stamp, listOf(MediaItem(ratingKey = "a", title = "A")))

    @Test fun aYoungSectionFromThisBuildIsReused() = assertTrue(ScanResume.reusable(kept(), now, 5, "u1/c1", stampRequired = true))

    @Test fun aSectionChangedOnTheServerIsReadAgain() = assertFalse(ScanResume.reusable(kept(), now, 5, "u2/c1", stampRequired = true))

    @Test fun aSectionPastTheAgeIsReadAgain() {
        assertTrue(ScanResume.reusable(kept(ageSec = ScanResume.MAX_AGE_SECONDS - 1), now, 5, "u1/c1", true))
        assertFalse(ScanResume.reusable(kept(ageSec = ScanResume.MAX_AGE_SECONDS), now, 5, "u1/c1", true))
    }

    @Test fun aSectionFromAnotherBuildIsIgnored() = assertFalse(ScanResume.reusable(kept(build = 4), now, 5, "u1/c1", true))

    @Test fun aSectionFromTheFutureIsIgnored() = assertFalse(ScanResume.reusable(kept(ageSec = -10), now, 5, "u1/c1", true))

    /** On Plex a section with no stamp can't be seen to be unchanged; Jellyfin and Emby have none. */
    @Test fun theStampIsNeededOnlyOnPlex() {
        assertFalse(ScanResume.reusable(kept(stamp = null), now, 5, null, stampRequired = true))
        assertTrue(ScanResume.reusable(kept(stamp = null), now, 5, null, stampRequired = false))
    }

    @Test fun plexStamp() {
        assertEquals("u10/c20", ScanResume.plexStamp(10, 20))
        assertEquals("u0/c20", ScanResume.plexStamp(null, 20))
        assertNull(ScanResume.plexStamp(null, null))
    }

    /** A store in memory that keeps what `done` hands it, as the app's does. */
    private class Store : SectionKeep {
        val kept = LinkedHashMap<String, List<MediaItem>>()
        override fun kept(key: String, stamp: String?) = kept[key]
        override fun done(key: String, stamp: String?, items: List<MediaItem>) { kept[key] = items }
    }

    /** Three film libraries; `dies` makes the scan stop for good at that library, as a killed app would. */
    private class Server(val dies: String? = null) {
        val asked = ArrayList<String>()
        fun library() = MediaBrowserLibrary({ path ->
            fun page(rows: List<JsonObject>) = 200 to JsonObject(mapOf("Items" to JsonArray(rows), "TotalRecordCount" to JsonPrimitive(rows.size)))
            when {
                path.contains("Views") -> page(listOf("one", "two", "three").map {
                    JsonObject(mapOf("Id" to JsonPrimitive(it), "Name" to JsonPrimitive(it), "CollectionType" to JsonPrimitive("movies")))
                })
                path.contains("/Items?") -> {
                    val parent = Regex("ParentId=([^&]+)").find(path)!!.groupValues[1]
                    asked += parent
                    if (parent == dies) throw ScanCancelled()
                    page((1..2).map { n -> JsonObject(mapOf("Id" to JsonPrimitive("$parent-$n"), "Name" to JsonPrimitive("$parent $n"),
                        "Type" to JsonPrimitive("Movie"), "RunTimeTicks" to JsonPrimitive(90L * 600_000_000))) })
                }
                else -> 404 to null
            } as Pair<Int, JsonElement?>
        }, "u1", "jellyfin")
    }

    @Test fun aScanThatDiesResumesWithTheLibrariesItHadNotFinished() {
        val store = Store()
        val first = Server(dies = "three")
        runCatching { first.library().scan(keep = store) }
        assertEquals("the two finished libraries are kept", listOf("one", "two"), store.kept.keys.toList())

        val second = Server()
        val items = second.library().scan(keep = store)
        assertEquals("only the unfinished library is read", listOf("three"), second.asked)
        assertEquals(listOf("one-1", "one-2", "two-1", "two-2", "three-1", "three-2"), items.map { it.ratingKey })
    }

    @Test fun nothingKeptReadsEverything() {
        val s = Server()
        s.library().scan(keep = SectionKeep.NONE)
        assertEquals(listOf("one", "two", "three"), s.asked)
    }
}
