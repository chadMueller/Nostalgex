package com.muellhaus.nostalgex.engine

/** Where the crash-guard mark lives (LaunchGuard's preferences); the engine only decides when it is set and cleared. */
interface LoadMarkStore {
    /** Written at once: the process may not live to write it later. */
    fun set()

    /** Clears the mark; with [resetCount] also the count of unfinished loads in a row. */
    fun clear(resetCount: Boolean)
}

/**
 * The mark that tells the next launch a load died inside the process (out of memory on a big library): set as a load starts, cleared as
 * it ends. Release 9 review: a load that was ended (signed out, another server) still ran its own cleanup and cleared the mark a newer
 * load had set, so an out-of-memory crash on the newer load went unseen at the next launch. Now only a load that is still the one in
 * use ends its own mark; whoever ends a load from outside clears the marker (never the count: a load that was stopped proves nothing)
 * before the next one sets it.
 */
class LoadCrashMark(private val store: LoadMarkStore) {
    fun loadStarted() = store.set()

    /** A load's own end, any way the process lives to see: only when it is still the library's load ([current]). */
    fun loadEnded(current: Boolean, resetCount: Boolean) {
        if (current) store.clear(resetCount)
    }

    /** The library changed under a load (signed out, another server or backend, a new load): its marker goes, its count stays. */
    fun loadAbandoned() = store.clear(resetCount = false)
}
