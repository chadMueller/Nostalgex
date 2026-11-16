package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * N-016 option A: which servers and libraries are listed, start on and are read, held to the shared golden
 * (scripts/library-picker-golden.json, from the web tuner's nostalgex-library-picker.js). The Apple TV, the Roku and this app read the same file.
 */
class LibraryPickerGoldenTest {
    private val golden = Json.parseToJsonElement(File(System.getProperty("nostalgex.repoRoot") ?: "..").resolve("scripts/library-picker-golden.json").readText()).jsonObject

    private fun cases(key: String) = golden[key]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonObject.strings(k: String) = (this[k] as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList()
    private fun JsonObject.objs(k: String) = (this[k] as? JsonArray)?.map { it.jsonObject }

    /** A library from the golden's `{ id: "<server>::<key>", hidden }`. */
    private fun lib(o: JsonObject): LibrarySection {
        val (server, key) = o.str("id")!!.split("::", limit = 2)
        return LibrarySection(server, server, key, key, "movie", hidden = o["hidden"]!!.jsonPrimitive.boolean)
    }

    private fun state(c: JsonObject, off: String = "off", included: String = "includedHidden") = LibraryPicker.State(c.strings(off).toSet(), c.strings(included).toSet())

    /** What the golden's `listed` says for a row, from a listing. */
    private fun describe(listed: List<LibrarySection>): List<List<Any>> {
        val multi = listed.map { it.serverId }.toSet().size > 1
        return listed.map { listOf(it.id, it.title, it.type, it.typeLabel, it.musicVideo, it.hidden, LibraryPicker.startsOn(it), it.subtitle(multi)) }
    }

    private fun expected(listed: List<JsonObject>) = listed.map {
        listOf(it.str("id")!!, it.str("title")!!, it.str("type")!!, it.str("label")!!, it["musicVideo"]!!.jsonPrimitive.boolean, it["hidden"]!!.jsonPrimitive.boolean,
            it["startsOn"]!!.jsonPrimitive.boolean, it.str("subtitle")!!)
    }

    @Test fun plexListsAndReadsMovieAndShowLibrariesOnly() {
        for (c in cases("plexListing")) {
            val listed = c.objs("servers")!!.flatMap { s ->
                LibraryPicker.plexListed(s.str("id")!!, s.str("name")!!, s.objs("sections"))
            }
            assertEquals(c.str("name"), expected(c.objs("listed")!!), describe(listed))
        }
    }

    @Test fun jellyfinAndEmbyListedWithHiddenLibrariesMarkedAndOff() {
        for (c in cases("mediaBrowserListing")) {
            val listed = LibraryPicker.mediaBrowserListed(c.str("serverId")!!, c.str("serverName")!!, c.objs("shown") ?: emptyList(), c.objs("all"))
            assertEquals(c.str("name"), expected(c.objs("listed")!!), describe(listed))
        }
    }

    @Test fun theViewersOwnPlexServersStartOnAndAllWhenNoneIsTheirs() {
        for (c in cases("serverDefaults")) {
            val got = LibraryPicker.defaultServerIds(c.objs("servers")!!.map { it.str("id")!! to it["owned"]!!.jsonPrimitive.boolean })
            assertEquals(c.str("name"), c.strings("on"), got)
        }
    }

    @Test fun aScanReadsTheLibrariesThatAreOn() {
        for (c in cases("reads")) {
            val libs = c.objs("libraries")!!.map(::lib)
            assertEquals(c.str("name"), c.strings("read"), LibraryPicker.readIds(libs, state(c)))
        }
    }

    @Test fun aChoiceOnlyMovesTheOneLibraryTheViewerTouched() {
        for (c in cases("choices")) {
            val libs = c.objs("libraries")!!.map(::lib).associateBy { it.id }
            var s = state(c)
            for (id in c.strings("toggle")) s = LibraryPicker.toggled(libs[id]!!, s)
            assertEquals(c.str("name"), c.strings("offAfter").toSet(), s.off)
            assertEquals(c.str("name"), c.strings("includedHiddenAfter").toSet(), s.includedHidden)
        }
    }

    @Test fun theOldSingleSwitchCarriesOverOnceAndIsClearedWhenDone() {
        for (c in cases("hiddenSwitchUpgrade")) {
            val libs = c.objs("libraries")!!.map(::lib)
            val (s, done) = LibraryPicker.carryOverHiddenSwitch(c["switchOn"]!!.jsonPrimitive.boolean, c["hiddenKnown"]!!.jsonPrimitive.boolean, libs, state(c))
            assertEquals(c.str("name"), c.strings("includedHiddenAfter").toSet(), s.includedHidden)
            assertEquals(c.str("name"), c.strings("offAfter").toSet(), s.off)
            assertEquals(c.str("name"), c["done"]!!.jsonPrimitive.boolean, done)
        }
    }

    @Test fun thePickerIsOfferedOnlyWhenThereIsSomethingToChoose() {
        for (c in cases("pickerOffered")) {
            assertEquals(c.str("name"), c["offered"]!!.jsonPrimitive.boolean, LibraryPicker.offersPicker(c.objs("libraries")!!.map(::lib)))
        }
    }

    @Test fun everySignInStartsAgain() {
        for (c in cases("signInReset")) {
            // Whatever was saved, and whichever way the old single switch stood, the sign-in leaves both lists empty and the switch gone.
            assertEquals(c.str("name"), LibraryPicker.State(c.strings("offAfter").toSet(), c.strings("includedHiddenAfter").toSet()), LibraryPicker.afterSignIn())
            assertEquals(c.str("name"), null, c.str("legacySwitchAfter"))
        }
    }

    @Test fun theGoldenIsTheOneThisBuildWasWrittenFor() {
        assertEquals(1, golden["version"]!!.jsonPrimitive.content.toInt())
        assertTrue(cases("plexListing").isNotEmpty() && cases("hiddenSwitchUpgrade").isNotEmpty())
    }

    @Test fun thePickersConfirmKeepsWhatTheViewerLeftOnAndLeavesTheRest() {
        // CONTINUE: the ones left on are on, the others off; a hidden one left on goes in the included list, not out of the off list.
        val a = LibrarySection("j", "J", "1", "Films", "movie")
        val b = LibrarySection("j", "J", "2", "Shows", "show")
        val h = LibrarySection("j", "J", "3", "Adult", "movie", hidden = true)
        val s = LibraryPicker.withOn(listOf(a, b, h), setOf(a.id, h.id))
        assertEquals(setOf(b.id), s.off)
        assertEquals(setOf(h.id), s.includedHidden)
    }

    /** The collection sweep skips a library that is off: its collections are not asked for (N-016). */
    @Test fun theCollectionSweepSkipsLibrariesThatAreOff() {
        val asked = ArrayList<String>()
        fun obj(vararg kv: Pair<String, JsonElement>) = JsonObject(mapOf(*kv))
        fun rows(key: String, vararg r: JsonObject) = obj("MediaContainer" to obj(key to JsonArray(r.toList())))
        val getJson: (String) -> JsonElement = { path ->
            asked += path
            when (path) {
                "/library/sections" -> rows("Directory", obj("key" to JsonPrimitive("1"), "type" to JsonPrimitive("movie")), obj("key" to JsonPrimitive("2"), "type" to JsonPrimitive("show")),
                    obj("key" to JsonPrimitive("3"), "type" to JsonPrimitive("movie")))
                "/library/sections/1/collections" -> rows("Metadata", obj("ratingKey" to JsonPrimitive("c1"), "title" to JsonPrimitive("One")))
                "/library/sections/2/collections" -> rows("Metadata", obj("ratingKey" to JsonPrimitive("c2"), "title" to JsonPrimitive("Two")))
                "/library/sections/3/collections" -> rows("Metadata", obj("ratingKey" to JsonPrimitive("c3"), "title" to JsonPrimitive("Three")))
                else -> rows("Metadata", obj("ratingKey" to JsonPrimitive("m1")))
            }
        }
        val all = Collections.fetchPlexCollections("srv", getJson)
        assertEquals(listOf("One", "Two", "Three"), all.map { it.title })
        asked.clear()
        val some = Collections.fetchPlexCollections("srv", getJson, isSectionOn = { it != "2" })
        assertEquals(listOf("One", "Three"), some.map { it.title })
        assertTrue("a library that is off was asked for its collections: $asked", "/library/sections/2/collections" !in asked)
    }
}
