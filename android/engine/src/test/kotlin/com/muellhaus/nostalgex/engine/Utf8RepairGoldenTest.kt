package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * scripts/utf8-repair-golden.json, the cases the Apple TV (PlexUTF8RepairGoldenTests), the web
 * tuner (nostalgex-utf8-repair-smoke.mjs) and the Roku (Utf8RepairTests.brs) are held to: each
 * input's bytes decode to the same text, with the same count of repaired bytes (#196).
 */
class Utf8RepairGoldenTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private val cases = Json.parseToJsonElement(repoRoot.resolve("scripts/utf8-repair-golden.json").readText())
        .jsonObject["cases"]!!.jsonArray.map { it.jsonObject }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test fun everyGoldenCase() {
        assertTrue(cases.size >= 27)
        val failures = ArrayList<String>()
        for (c in cases) {
            val name = c["name"]!!.jsonPrimitive.content
            val got = PlexUtf8Repair.decode(hex(c["hex"]!!.jsonPrimitive.content))
            val text = c["text"]!!.jsonPrimitive.content
            val repaired = c["repairedBytes"]!!.jsonPrimitive.int
            if (got.text != text || got.repairedBytes != repaired) {
                failures += "$name: want ${text.map { "%04X".format(it.code) }} ($repaired), got ${got.text.map { "%04X".format(it.code) }} (${got.repairedBytes})"
            }
        }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }

    /** What the guide shows: a Plex page with a lone 0xE9 in a title parses, and reads "Café Society". */
    @Test fun aPlexPageWithALatin1TitleParses() {
        val page = """{"MediaContainer":{"Metadata":[{"title":"Caf""".toByteArray() + byteArrayOf(0xE9.toByte()) +
            """ Society","summary":"Amélie 😀"}]}}""".toByteArray()
        val d = PlexUtf8Repair.decode(page)
        assertEquals(1, d.repairedBytes)
        val item = Json.parseToJsonElement(d.text).jsonObject["MediaContainer"]!!.jsonObject["Metadata"]!!.jsonArray[0].jsonObject
        assertEquals("Café Society", item["title"]!!.jsonPrimitive.content)
        assertEquals("Amélie 😀", item["summary"]!!.jsonPrimitive.content)
    }

    @Test fun theLogLineIsTheAppleTvs() {
        assertEquals("PLEX UTF-8 /library/sections/1/all: repaired 1 byte(s) that were not UTF-8, read as Windows-1252",
            PlexUtf8Repair.logLine("/library/sections/1/all", 1))
    }
}
