package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * scripts/nostalgex-server-resolve.js's answers, from gen-resolve-vectors.mjs: each run replayed
 * on a virtual clock as the smoke runs it (the grace timer, the deadline, then each probe in
 * candidate order, ties in that order), and the same address chosen at the same moment.
 */
class ServerResolveTest {
    private val vectors = Json.parseToJsonElement(File(System.getProperty("nostalgex.resolveVectors")).readText()).jsonObject

    private fun conn(o: JsonObject) = ServerResolve.Conn(o["uri"]!!.jsonPrimitive.content, o["local"]!!.jsonPrimitive.boolean, o["relay"]!!.jsonPrimitive.boolean)
    private fun str(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private data class Answer(val uri: String?, val kind: String?, val at: Long)

    private fun simulate(addresses: List<JsonObject>, graceMs: Long, deadlineMs: Long): Answer {
        val r = ServerResolve.Resolver(addresses.map(::conn), graceMs, deadlineMs)
        r.result?.let { return Answer(it.conn?.uri, null, 0) }
        val byUri = addresses.associateBy { it["uri"]!!.jsonPrimitive.content }
        class Event(val t: Long, val n: Int, val fire: (Long) -> ServerResolve.Outcome?)
        val events = ArrayList<Event>()
        events += Event(graceMs, 0) { r.graceFired(it) }
        events += Event(deadlineMs, 1) { r.expired(it) }
        r.candidates.forEachIndexed { i, c ->
            val a = byUri.getValue(c.conn.uri)
            events += Event(a["delay"]!!.jsonPrimitive.long, 2 + i) { t -> r.report(c, a["ok"]!!.jsonPrimitive.boolean, t) }
        }
        for (e in events.sortedWith(compareBy({ it.t }, { it.n }))) {
            val out = e.fire(e.t) ?: continue
            return Answer(out.conn?.uri, out.conn?.let { out.kind }, e.t)
        }
        error("never settled")
    }

    @Test fun everyRunChoosesTheSameAddressAtTheSameMoment() {
        val runs = vectors["runs"]!!.jsonArray.map { it.jsonObject }
        assertTrue(runs.size >= 400)
        val failures = ArrayList<String>()
        for (run in runs) {
            val want = run["want"]!!.jsonObject
            val got = simulate(run["addresses"]!!.jsonArray.map { it.jsonObject }, run["graceMs"]!!.jsonPrimitive.long, run["deadlineMs"]!!.jsonPrimitive.long)
            val expected = Answer(str(want, "uri"), str(want, "kind"), want["at"]!!.jsonPrimitive.long)
            if (got != expected) failures += "${run["name"]!!.jsonPrimitive.content}: want $expected, got $got"
        }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
        // The vectors cover both outcomes.
        assertTrue(runs.count { str(it["want"]!!.jsonObject, "uri") != null } > 100)
    }

    @Test fun theOrderHomeThenRemoteHttpsThenPlainThenRelay() {
        val order = vectors["order"]!!.jsonObject
        val got = ServerResolve.candidates(order["input"]!!.jsonArray.map { conn(it.jsonObject) }).map { it.conn.uri to it.kind }
        val want = order["want"]!!.jsonArray.map { it.jsonObject }.map { it["uri"]!!.jsonPrimitive.content to it["kind"]!!.jsonPrimitive.content }
        assertEquals(want, got)
    }

    @Test fun onlyADifferentIdentifierTurnsAnAddressDown() {
        for (c in vectors["identity"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(c.toString(), c["want"]!!.jsonPrimitive.boolean, ServerResolve.identityMatches(str(c, "answered"), str(c, "expected")))
        }
    }

    @Test fun noAddressesIsSettledAtOnceWithNone() {
        val r = ServerResolve.Resolver(listOf(null, ServerResolve.Conn("", false, false)))
        assertEquals(ServerResolve.Outcome(true, null, ""), r.result)
    }
}
