package com.muellhaus.nostalgex.engine

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Release 9 review: a load that was ended still cleared the crash-guard mark in its own cleanup, so the mark a newer load had set was
 * gone, and an out-of-memory crash on a big library went unseen at the next launch. The fake store is LaunchGuard's two values.
 */
class LoadCrashMarkTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private class Store : LoadMarkStore {
        var inFlight = false
        var unfinished = 2
        override fun set() { inFlight = true }
        override fun clear(resetCount: Boolean) { inFlight = false; if (resetCount) unfinished = 0 }
        override fun resetCount() { unfinished = 0 }
    }

    @Test fun aLoadThatIsStillTheLibrarysEndsItsOwnMarkAndAFullLoadResetsTheCount() {
        val store = Store(); val mark = LoadCrashMark(store)
        mark.loadStarted(); assertTrue(store.inFlight)
        mark.loadEnded(current = true, resetCount = true)
        assertFalse(store.inFlight); assertEquals(0, store.unfinished)
    }

    @Test fun readingTheSavedLibraryClearsTheMarkerButProvesNothingAboutTheCount() {
        val store = Store(); val mark = LoadCrashMark(store)
        mark.loadStarted(); mark.loadEnded(current = true, resetCount = false)
        assertFalse(store.inFlight); assertEquals(2, store.unfinished)
    }

    @Test fun aLoadThatWasEndedLeavesTheMarkAlone() {
        val store = Store(); val mark = LoadCrashMark(store)
        mark.loadStarted()
        mark.loadEnded(current = false, resetCount = true)
        assertTrue("a dead load cleared a mark that is not its own", store.inFlight)
        assertEquals(2, store.unfinished)
    }

    @Test fun aDeadLoadsLateCleanupDoesNotClearTheNewerLoadsMark() = runBlocking {
        val pass = BackgroundPass(scope)
        val store = Store(); val mark = LoadCrashMark(store)
        val release = CompletableDeferred<Unit>()
        val oldEnded = CompletableDeferred<Unit>()
        val oldStarted = java.util.concurrent.CountDownLatch(1)
        // Load A: marks, then waits on the old server (a read that does not see the cancel), then runs its cleanup.
        val blocker = java.util.concurrent.CountDownLatch(1)
        pass.start { current ->
            mark.loadStarted(); oldStarted.countDown()
            try { blocker.await() } finally { mark.loadEnded(current(), resetCount = true); oldEnded.complete(Unit) }
        }
        assertTrue(oldStarted.await(5, java.util.concurrent.TimeUnit.SECONDS))
        // The viewer signs out and picks a server: what endBackgroundWork and loadLibrary do, then load B sets its mark.
        pass.invalidate(); mark.loadAbandoned()
        mark.loadStarted()
        // The old server answers at last; load A's cleanup runs now.
        blocker.countDown(); oldEnded.await()
        release.complete(Unit)
        assertTrue("the newer load's crash mark was cleared by the dead load", store.inFlight)
        assertEquals("a dead load reset the count", 2, store.unfinished)
    }

    @Test fun signingOutMidLoadLeavesNoMarkBehindForTheNextLaunchToCount() = runBlocking {
        val pass = BackgroundPass(scope)
        val store = Store(); val mark = LoadCrashMark(store)
        val started = java.util.concurrent.CountDownLatch(1)
        val ended = CompletableDeferred<Unit>()
        val blocker = java.util.concurrent.CountDownLatch(1)
        pass.start { current -> mark.loadStarted(); started.countDown(); try { blocker.await() } finally { mark.loadEnded(current(), resetCount = true); ended.complete(Unit) } }
        assertTrue(started.await(5, java.util.concurrent.TimeUnit.SECONDS))
        pass.invalidate(); mark.loadAbandoned()          // signOut
        blocker.countDown(); ended.await()
        assertFalse("a stopped load's marker would count as an unfinished load at the next launch", store.inFlight)
        assertEquals("stopping a load is not a finished one", 2, store.unfinished)
    }

    @Test fun startOverForgetsTheUnfinishedLoadsThatAskedForIt() {
        val store = Store(); val mark = LoadCrashMark(store)
        assertEquals(2, store.unfinished)               // "LOADING DIDN'T FINISH" came up after two
        mark.startedOver()
        assertEquals(0, store.unfinished)
    }

    @Test fun startOverLeavesALoadsMarkToTheLoadThatSetIt() {
        val store = Store(); val mark = LoadCrashMark(store)
        mark.loadStarted(); mark.startedOver()
        assertTrue(store.inFlight)
    }

    /** AppModel.release(): the mark's `released()`, then the scope is cancelled with the load in it. */
    private fun loadThenRelease(releaseFirst: Boolean): Store {
        val store = Store(); val mark = LoadCrashMark(store)
        val ownScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val pass = BackgroundPass(ownScope)
        val started = java.util.concurrent.CountDownLatch(1)
        val ended = java.util.concurrent.CountDownLatch(1)
        pass.start { current ->
            mark.loadStarted(); started.countDown()
            try { kotlinx.coroutines.awaitCancellation() } finally { mark.loadEnded(current(), resetCount = true); ended.countDown() }
        }
        assertTrue(started.await(5, java.util.concurrent.TimeUnit.SECONDS))
        if (releaseFirst) mark.released()
        ownScope.cancel()
        assertTrue(ended.await(5, java.util.concurrent.TimeUnit.SECONDS))
        return store
    }

    @Test fun aLoadEndedByReleaseLeavesNoMarkAndKeepsTheCount() {
        val store = loadThenRelease(releaseFirst = true)
        assertFalse("Back during a long first load would count as an unfinished load at the next cold start", store.inFlight)
        assertEquals(2, store.unfinished)
    }

    @Test fun withoutReleaseClearingItTheCancelledLoadLeavesTheMarkBehind() {
        // The bug: the scope's cancel makes the load's own cleanup see it is not current, so nothing clears the mark.
        assertTrue(loadThenRelease(releaseFirst = false).inFlight)
    }
}
