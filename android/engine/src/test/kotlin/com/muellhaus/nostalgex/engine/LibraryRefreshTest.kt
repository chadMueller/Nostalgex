package com.muellhaus.nostalgex.engine

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The background refresh that outlived its library (found with the music pass on release 8): a refresh started on one server, the viewer signed
 * out or switched, and it still wrote the old server's library into the store and swapped its lineup in. The fake records every
 * effect, so each test reads what the refresh wrote.
 */
class LibraryRefreshTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private fun item(key: String) = MediaItem(key, title = key, serverUrl = "http://s")

    private class Fake(
        override var savedItems: List<MediaItem>,
        override var heldCollections: List<ServerCollection> = emptyList(),
        override var currentItems: List<MediaItem> = savedItems,
        val read: List<MediaItem> = savedItems,
        val abandoned: Boolean = false,
        val gate: CompletableDeferred<Unit>? = null,
        val blocking: java.util.concurrent.CountDownLatch? = null,
        val onStep: (String) -> Unit = {},
    ) : RefreshEffects {
        val log = ArrayList<String>()
        private fun did(s: String) { log += s; onStep(s) }
        override suspend fun scan(): RefreshRead { did("scan"); gate?.await(); blocking?.await(); return RefreshRead(read, abandoned, 5) }
        override suspend fun markLoaded(abandoned: Boolean) = did("markLoaded($abandoned)")
        override suspend fun readComplete(read: RefreshRead) = did("clearKeptSections")
        override suspend fun readCollections(): List<ServerCollection> { did("readCollections"); return heldCollections }
        override suspend fun save(items: List<MediaItem>, collections: List<ServerCollection>) = did("save(${items.size})")
        override suspend fun enrich(items: List<MediaItem>): List<MediaItem> { did("enrich"); return items }
        override suspend fun adopt(enriched: List<MediaItem>) = did("adopt(${enriched.size})")
        override fun note(line: String) {}
    }

    private val writes = setOf("markLoaded(true)", "markLoaded(false)", "clearKeptSections", "save(1)", "save(2)", "adopt(1)", "adopt(2)")

    @Test fun aRefreshOfTheLibraryInUseWritesItInOrder() = runBlocking {
        val fx = Fake(savedItems = listOf(item("a")), read = listOf(item("a"), item("b")), currentItems = listOf(item("a")))
        val result = LibraryRefresh({ true }, fx).run()
        assertEquals(RefreshResult.ADOPTED, result)
        assertEquals(listOf("scan", "markLoaded(false)", "clearKeptSections", "readCollections", "save(2)", "enrich", "adopt(2)"), fx.log)
    }

    @Test fun signingOutDuringAScanThatSeesTheCancelKeepsEverythingItRead() = runBlocking {
        val pass = BackgroundPass(scope)
        val gate = CompletableDeferred<Unit>()
        val fx = Fake(savedItems = listOf(item("a")), read = listOf(item("old server 1"), item("old server 2")), gate = gate)
        pass.start { current -> LibraryRefresh(current, fx).run() }
        while (!fx.log.contains("scan")) Thread.sleep(5)
        pass.invalidate()                       // signOut
        gate.complete(Unit)
        Thread.sleep(100)
        assertTrue("wrote after the library changed: ${fx.log}", fx.log.none { it in writes })
    }

    @Test fun signingOutDuringAScanThatBlocksThroughTheCancelKeepsEverythingItRead() = runBlocking {
        // A blocking read of the old server does not see the cancel: only the generation keeps its result out.
        val pass = BackgroundPass(scope)
        val latch = java.util.concurrent.CountDownLatch(1)
        val fx = Fake(savedItems = listOf(item("a")), read = listOf(item("old server 1"), item("old server 2")), blocking = latch)
        var result: RefreshResult? = null
        val done = CompletableDeferred<Unit>()
        pass.start { current -> try { result = LibraryRefresh(current, fx).run() } finally { done.complete(Unit) } }
        while (!fx.log.contains("scan")) Thread.sleep(5)
        pass.invalidate()
        latch.countDown()
        done.await()
        assertEquals(RefreshResult.STALE, result)
        assertTrue("wrote after the library changed: ${fx.log}", fx.log.none { it in writes })
    }

    @Test fun signingOutAfterTheScanStopsTheLibraryStoreWrite() = runBlocking {
        val pass = BackgroundPass(scope)
        val fx = Fake(savedItems = listOf(item("a")), read = listOf(item("a"), item("b")), onStep = { if (it == "readCollections") pass.invalidate() })
        var result: RefreshResult? = null
        val done = CompletableDeferred<Unit>()
        pass.start { current -> try { result = LibraryRefresh(current, fx).run() } finally { done.complete(Unit) } }
        done.await()
        assertEquals(RefreshResult.STALE, result)
        assertTrue("saved the old server's library after the change: ${fx.log}", "save(2)" !in fx.log && "adopt(2)" !in fx.log)
    }

    @Test fun signingOutDuringEnrichmentStopsTheLineupSwap() = runBlocking {
        val pass = BackgroundPass(scope)
        val fx = Fake(savedItems = listOf(item("a")), read = listOf(item("a"), item("b")), onStep = { if (it == "enrich") pass.invalidate() })
        var result: RefreshResult? = null
        val done = CompletableDeferred<Unit>()
        pass.start { current -> try { result = LibraryRefresh(current, fx).run() } finally { done.complete(Unit) } }
        done.await()
        assertEquals(RefreshResult.STALE, result)
        assertTrue("swapped the old lineup in: ${fx.log}", "adopt(2)" !in fx.log)
    }

    @Test fun anAbandonedScanOfAnEarlierLibraryDoesNotMarkTheNewOneLoaded() = runBlocking {
        val pass = BackgroundPass(scope)
        val gate = CompletableDeferred<Unit>()
        val fx = Fake(savedItems = listOf(item("a")), abandoned = true, gate = gate)
        val done = CompletableDeferred<Unit>()
        pass.start { current -> try { LibraryRefresh(current, fx).run() } finally { done.complete(Unit) } }
        while (!fx.log.contains("scan")) Thread.sleep(5)
        pass.invalidate()
        gate.complete(Unit); done.await()
        assertTrue(fx.log.none { it in writes })
    }

    @Test fun anAbandonedScanOfTheLibraryInUseIsMarkedAndTheGuideKept() = runBlocking {
        val fx = Fake(savedItems = listOf(item("a")), abandoned = true)
        assertEquals(RefreshResult.ABANDONED, LibraryRefresh({ true }, fx).run())
        assertEquals(listOf("scan", "markLoaded(true)"), fx.log)
    }

    @Test fun aLibraryThatHasNotChangedIsNotSavedOrRebuilt() = runBlocking {
        val same = listOf(item("a"))
        val fx = Fake(savedItems = same, read = same, currentItems = same)
        assertEquals(RefreshResult.UNCHANGED, LibraryRefresh({ true }, fx).run())
        assertTrue("save(1)" !in fx.log && "adopt(1)" !in fx.log)
    }

    @Test fun aStoreThatWasJustClearedIsSavedEvenWhenNothingChanged() = runBlocking {
        val same = listOf(item("a"))
        val fx = Fake(savedItems = same, read = same, currentItems = same)
        LibraryRefresh({ true }, fx, alwaysSave = true).run()
        assertTrue("save(1)" in fx.log)
    }
}
