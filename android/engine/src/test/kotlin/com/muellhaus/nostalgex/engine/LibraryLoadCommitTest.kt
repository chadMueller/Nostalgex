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
 * Release 9 review: with the guide kept up during a load, Settings and DISCONNECT are reachable mid-load. signOut never ended the load,
 * so it saved library.json for the old servers, showed the guide, and put the viewer back into the server just disconnected. The fake
 * records each effect; `signedOut` is where AppModel's signOut stands: it ends the pass (BackgroundPass.invalidate) and shows the picker.
 */
class LibraryLoadCommitTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private fun item(key: String) = MediaItem(key, title = key, serverUrl = "http://old")

    private class Fake(val gate: CompletableDeferred<Unit>? = null, val blocking: java.util.concurrent.CountDownLatch? = null, val onStep: (String) -> Unit = {}) : LoadCommitEffects<String> {
        val log = ArrayList<String>()
        private fun did(s: String) { log += s; onStep(s) }
        override suspend fun save(items: List<MediaItem>, collections: List<ServerCollection>) = did("save(${items.size})")
        override suspend fun enrich(items: List<MediaItem>, remote: Boolean): List<MediaItem> { did("enrich($remote)"); gate?.await(); blocking?.await(); return items }
        override suspend fun build(items: List<MediaItem>): String { did("build"); return "lineup" }
        override suspend fun show(built: String): Boolean { did("show"); return true }
    }

    /** What the screen shows: the picker after a sign out, the guide only if a load shows it. */
    private class Screen { var name = "guide"; fun showPicker() { name = "sign-in" } }

    private val old = listOf(item("a"), item("b"))
    private val writesAndShows = setOf("save(2)", "show")

    @Test fun aLoadOfTheLibraryInUseSavesBuildsAndShowsInOrder() = runBlocking {
        val fx = Fake()
        assertEquals(LoadResult.SHOWN, LibraryLoadCommit({ true }, fx).run(old, emptyList()))
        assertEquals(listOf("save(2)", "enrich(true)", "build", "show"), fx.log)
    }

    @Test fun theSavedLibraryIsShownWithTheLocalCacheOnlyAndWritesNothing() = runBlocking {
        val fx = Fake()
        assertEquals(LoadResult.SHOWN, LibraryLoadCommit({ true }, fx).runSaved(old))
        assertEquals(listOf("enrich(false)", "build", "show"), fx.log)
    }

    @Test fun signingOutMidLoadBuildsAndShowsNothingAndStaysOnSignIn() = runBlocking {
        val pass = BackgroundPass(scope)
        val screen = Screen()
        val gate = CompletableDeferred<Unit>()
        val fx = Fake(gate = gate)
        val done = CompletableDeferred<Unit>()
        pass.start { current -> try { LibraryLoadCommit(current, fx).run(old, emptyList()) } finally { done.complete(Unit) } }
        while ("enrich(true)" !in fx.log) Thread.sleep(5)
        // The viewer opens Settings and presses DISCONNECT: signOut ends the load, then shows the picker.
        pass.invalidate(); screen.showPicker()
        gate.complete(Unit); done.await()
        Thread.sleep(50)
        assertEquals("sign-in", screen.name)
        assertFalse("the guide was shown for a library that was signed out of: ${fx.log}", "show" in fx.log)
        assertFalse("the old servers were built into a lineup: ${fx.log}", "build" in fx.log)
    }

    @Test fun signingOutDuringAReadThatIgnoresTheCancelKeepsTheLibraryStoreUntouched() = runBlocking {
        // The read of the old server is a blocking call that does not see the cancel: only the generation keeps its result out.
        val pass = BackgroundPass(scope)
        val screen = Screen()
        val latch = java.util.concurrent.CountDownLatch(1)
        val fx = Fake()
        var result: LoadResult? = null
        val done = CompletableDeferred<Unit>()
        val started = java.util.concurrent.CountDownLatch(1)
        pass.start { current ->
            try {
                started.countDown(); latch.await()          // the scan, blocked
                result = LibraryLoadCommit(current, fx).run(old, emptyList())
            } finally { done.complete(Unit) }
        }
        assertTrue(started.await(5, java.util.concurrent.TimeUnit.SECONDS))
        pass.invalidate(); screen.showPicker()
        latch.countDown(); done.await()
        assertEquals(LoadResult.STALE, result)
        assertTrue("wrote or showed after the sign out: ${fx.log}", fx.log.isEmpty())
        assertEquals("sign-in", screen.name)
    }

    @Test fun signingOutAfterTheSaveStillStopsTheBuildAndTheShow() = runBlocking {
        val pass = BackgroundPass(scope)
        val screen = Screen()
        val fx = Fake(onStep = { if (it == "enrich(true)") { pass.invalidate(); screen.showPicker() } })
        var result: LoadResult? = null
        val done = CompletableDeferred<Unit>()
        pass.start { current -> try { result = LibraryLoadCommit(current, fx).run(old, emptyList()) } finally { done.complete(Unit) } }
        done.await()
        assertEquals(LoadResult.STALE, result)
        assertFalse("show" in fx.log)
        assertEquals("sign-in", screen.name)
    }

    @Test fun aSavedLibraryOfALibrarySignedOutOfIsNotShownEither() = runBlocking {
        val pass = BackgroundPass(scope)
        val fx = Fake(onStep = { if (it == "build") pass.invalidate() })
        var result: LoadResult? = null
        val done = CompletableDeferred<Unit>()
        pass.start { current -> try { result = LibraryLoadCommit(current, fx).runSaved(old) } finally { done.complete(Unit) } }
        done.await()
        assertEquals(LoadResult.STALE, result)
        assertFalse("show" in fx.log)
    }

    @Test fun aLoadWithNoChannelsSaysSoRatherThanShowing() = runBlocking {
        val fx = object : LoadCommitEffects<String> {
            override suspend fun save(items: List<MediaItem>, collections: List<ServerCollection>) {}
            override suspend fun enrich(items: List<MediaItem>, remote: Boolean) = items
            override suspend fun build(items: List<MediaItem>) = "empty"
            override suspend fun show(built: String) = false
        }
        assertEquals(LoadResult.NO_CHANNELS, LibraryLoadCommit({ true }, fx).run(old, emptyList()))
    }
}
