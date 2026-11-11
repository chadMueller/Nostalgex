package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.ServerScan.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** #285: the Apple TV's StopWaitingCancellationIsolationTests cases, over the server loop. */
class ServerScanTest {
    private class Fake(private val outcomes: Map<String, Outcome<String>>) {
        val asked = ArrayList<String>()
        fun read(s: String): Outcome<String> { asked += s; return outcomes.getValue(s) }
    }

    @Test fun stopWaitingOnTheFirstDoesNotStartTheSecond() {
        val f = Fake(mapOf("a" to Outcome.Read(listOf("a1", "a2"), abandoned = true, byViewer = true), "b" to Outcome.Read(listOf("b1"), false, false)))
        val t = ServerScan.readAll(listOf("a", "b")) { f.read(it) }
        assertEquals(listOf("a"), f.asked)
        assertEquals(listOf("a1", "a2"), t.items)
        assertTrue(t.abandoned)
        assertEquals(1, t.serversSkipped)
        assertNull(t.error)
    }

    @Test fun stopWaitingOnTheSecondKeepsTheFirstServersItems() {
        val f = Fake(mapOf("a" to Outcome.Read(listOf("a1"), false, false), "b" to Outcome.Read(listOf("b1"), abandoned = true, byViewer = true), "c" to Outcome.Read(listOf("c1"), false, false)))
        val t = ServerScan.readAll(listOf("a", "b", "c")) { f.read(it) }
        assertEquals(listOf("a", "b"), f.asked)
        assertEquals(listOf("a1", "b1"), t.items)
        assertEquals(2, t.serversRead)
    }

    /** A press on a server that had given nothing yet still keeps the servers before it. */
    @Test fun stopWaitingWithNothingFromThatServerKeepsTheOthers() {
        val f = Fake(mapOf("a" to Outcome.Read(listOf("a1"), false, false), "b" to Outcome.Stalled(byViewer = true, Exception("stopped")), "c" to Outcome.Read(listOf("c1"), false, false)))
        val t = ServerScan.readAll(listOf("a", "b", "c")) { f.read(it) }
        assertEquals(listOf("a", "b"), f.asked)
        assertEquals(listOf("a1"), t.items)
        assertNull(t.error)
    }

    /** No press: a stalled server is skipped alone and the next is read, as before. */
    @Test fun aStallWithoutAPressSkipsOnlyThatServer() {
        val f = Fake(mapOf("a" to Outcome.Stalled(byViewer = false, Exception("quiet")), "b" to Outcome.Read(listOf("b1"), false, false)))
        val t = ServerScan.readAll(listOf("a", "b")) { f.read(it) }
        assertEquals(listOf("a", "b"), f.asked)
        assertEquals(listOf("b1"), t.items)
        assertTrue(t.abandoned)
        assertEquals(0, t.serversSkipped)
    }

    @Test fun aStallAbandonedPartWaySkipsOnlyThatServer() {
        val f = Fake(mapOf("a" to Outcome.Read(listOf("a1"), abandoned = true, byViewer = false), "b" to Outcome.Read(listOf("b1"), false, false)))
        assertEquals(listOf("a1", "b1"), ServerScan.readAll(listOf("a", "b")) { f.read(it) }.items)
    }

    /** Nothing read anywhere: the stall is reported before a failure, as before. */
    @Test fun nothingReadReportsTheStallFirst() {
        val stall = Exception("stall")
        val f = Fake(mapOf("a" to Outcome.Failed(Exception("failed")), "b" to Outcome.Stalled(byViewer = true, stall)))
        val t = ServerScan.readAll(listOf("a", "b")) { f.read(it) }
        assertSame(stall, t.error)
        assertEquals(0, t.serversRead)
    }

    @Test fun oneFailedServerAmongGoodOnesIsSkipped() {
        val f = Fake(mapOf("a" to Outcome.Failed(Exception("failed")), "b" to Outcome.Read(listOf("b1"), false, false)))
        val t = ServerScan.readAll(listOf("a", "b")) { f.read(it) }
        assertEquals(listOf("b1"), t.items)
        assertNull(t.error)
        assertFalse(t.abandoned)
    }
}
