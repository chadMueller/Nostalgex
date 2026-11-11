package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.ServerSharing.Ref
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** #289's rule: A to B clears the playback failures, A to A plus B keeps them. */
class ServerSharingTest {
    private val a = Ref("machine-a", "https://192-0-2-10.abc.plex.direct:32400")
    private val b = Ref("machine-b", "https://192-0-2-20.def.plex.direct:32400")

    @Test fun aToBSharesNothing() = assertFalse(ServerSharing.sharesAServer(listOf(a), listOf(b)))

    @Test fun aToAPlusBShares() = assertTrue(ServerSharing.sharesAServer(listOf(a), listOf(a, b)))

    @Test fun removingOneOfSeveralShares() = assertTrue(ServerSharing.sharesAServer(listOf(a, b), listOf(b)))

    /** The same server reached at another address is still the same machine. */
    @Test fun theSameIdAtAnotherAddressShares() =
        assertTrue(ServerSharing.sharesAServer(listOf(a), listOf(a.copy(url = "http://192.0.2.10:32400"))))

    /** An older install kept its one server by address only. */
    @Test fun theSameHostAndPortSharesWithoutAnId() {
        assertTrue(ServerSharing.sharesAServer(listOf(Ref(null, "http://jelly.example:8096")), listOf(Ref("srv-1", "http://JELLY.example:8096/"))))
        assertTrue(ServerSharing.sharesAServer(listOf(Ref(null, "https://jelly.example")), listOf(Ref("srv-1", "https://jelly.example:443"))))
    }

    @Test fun anotherPortIsAnotherServer() =
        assertFalse(ServerSharing.sharesAServer(listOf(Ref(null, "http://jelly.example:8096")), listOf(Ref(null, "http://jelly.example:8097"))))

    @Test fun nothingBeforeSharesNothing() = assertFalse(ServerSharing.sharesAServer(emptyList(), listOf(a)))

    @Test fun anEmptyIdIsNotAMatch() =
        assertFalse(ServerSharing.sharesAServer(listOf(Ref("", "http://one.example")), listOf(Ref("", "http://two.example"))))

    @Test fun hostPort() {
        assertEquals("host.example:8096", ServerSharing.hostPort("http://Host.example:8096/web"))
        assertEquals("host.example:80", ServerSharing.hostPort("http://host.example"))
        assertNull(ServerSharing.hostPort("not a url"))
        assertNull(ServerSharing.hostPort(null))
    }
}
