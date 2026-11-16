package com.muellhaus.nostalgex.engine

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The music pass that outlived its library (reviewer finding on release 8): a lookup started on one server, the viewer signed out or
 * switched, and the pass still swapped its lineup in. Each test stands in for the AppModel's pass: wait for the lookups, then
 * hand the lineup back only if `current()` still says it is this library's.
 */
class BackgroundPassTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** A pass that waits on [lookups] (the network), then swaps in [handedBack] if its library is still current. */
    private fun passOver(pass: BackgroundPass, lookups: CompletableDeferred<Unit>, handedBack: MutableList<String>, id: String): Boolean =
        pass.start { current ->
            lookups.await()
            if (!current()) return@start
            handedBack += id
        }

    private fun settle(ms: Long = 150) = Thread.sleep(ms)

    @Test fun aPassThatFinishesOnItsOwnLibraryHandsBackItsLineup() = runBlocking {
        val pass = BackgroundPass(scope)
        val lookups = CompletableDeferred<Unit>()
        val handedBack = ArrayList<String>()
        assertTrue(passOver(pass, lookups, handedBack, "A"))
        lookups.complete(Unit); settle()
        assertEquals(listOf("A"), handedBack)
    }

    @Test fun signingOutDuringTheLookupsStopsTheLineupFromBeingSwappedIn() = runBlocking {
        val pass = BackgroundPass(scope)
        val lookups = CompletableDeferred<Unit>()
        val handedBack = ArrayList<String>()
        passOver(pass, lookups, handedBack, "old server")
        pass.invalidate()                       // signOut, a server switch or a new library load
        lookups.complete(Unit); settle()        // the old server's lookups still finish
        assertTrue("the old library's lineup was swapped in after the library changed", handedBack.isEmpty())
    }

    @Test fun aPassThatIgnoresItsCancellationIsStillHeldByTheGeneration() = runBlocking {
        // The lookup is a blocking call that does not see the cancel; the generation is what keeps its result out.
        val pass = BackgroundPass(scope)
        val release = java.util.concurrent.CountDownLatch(1)
        val handedBack = ArrayList<String>()
        val started = java.util.concurrent.CountDownLatch(1)
        val finished = java.util.concurrent.CountDownLatch(1)
        val seenCurrent = java.util.concurrent.atomic.AtomicBoolean(true)
        pass.start { current ->
            started.countDown()
            release.await()                      // blocks the thread: cancellation cannot reach it
            seenCurrent.set(current())
            if (current()) handedBack += "old"
            finished.countDown()
        }
        assertTrue(started.await(5, java.util.concurrent.TimeUnit.SECONDS))
        pass.invalidate()
        release.countDown()
        assertTrue(finished.await(5, java.util.concurrent.TimeUnit.SECONDS))
        assertFalse(seenCurrent.get())
        assertTrue(handedBack.isEmpty())
    }

    @Test fun aNewPassCanStartOnceTheOldOneWasInvalidatedAndTheOldOneStaysOut() = runBlocking {
        val pass = BackgroundPass(scope)
        val oldLookups = CompletableDeferred<Unit>()
        val newLookups = CompletableDeferred<Unit>()
        val handedBack = ArrayList<String>()
        passOver(pass, oldLookups, handedBack, "old")
        pass.invalidate()
        assertFalse("invalidate stops the old pass", pass.running)
        assertTrue(passOver(pass, newLookups, handedBack, "new"))
        oldLookups.complete(Unit); newLookups.complete(Unit); settle()
        assertEquals(listOf("new"), handedBack)
    }

    @Test fun onlyOnePassRunsAtATime() = runBlocking {
        val pass = BackgroundPass(scope)
        val lookups = CompletableDeferred<Unit>()
        assertTrue(passOver(pass, lookups, ArrayList(), "first"))
        assertFalse("a second start while one runs is refused", passOver(pass, lookups, ArrayList(), "second"))
        pass.invalidate()
    }

    @Test fun aRefreshThatStartedOnAnEarlierLibraryCanTellItsTokenIsStale() {
        val pass = BackgroundPass(scope)
        val token = pass.generation
        assertTrue(pass.isCurrent(token))
        pass.invalidate()
        assertFalse(pass.isCurrent(token))
        assertTrue(pass.isCurrent(pass.generation))
    }
}
