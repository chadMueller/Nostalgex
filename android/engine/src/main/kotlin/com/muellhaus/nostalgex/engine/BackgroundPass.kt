package com.muellhaus.nostalgex.engine

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * One background pass over the library at a time (the music genre lookups, #319), tied to the library it started on.
 *
 * A pass reads the library as it stood when it began and hands a new lineup back when it ends, which can be minutes later. If
 * the viewer signed out, switched server or backend, or the library was loaded again in that time, that lineup belongs to
 * a library that is gone and must not replace the current one. [invalidate] is called wherever the library changes: it
 * stops the pass and makes everything it has not handed back yet stale. The work asks `current()` before each hand-back.
 */
class BackgroundPass(private val scope: CoroutineScope) {
    private var job: Job? = null

    /** Counts the libraries seen: it moves on every [invalidate]. */
    @Volatile
    var generation = 0
        private set

    val running: Boolean get() = job?.isActive == true

    fun isCurrent(token: Int) = token == generation

    /** The library changed: cancel the pass and make its unfinished result stale. */
    fun invalidate() {
        generation++
        job?.cancel()
        job = null
    }

    /**
     * Starts [work] unless a pass is already running; false when it did not. `current()` is true only while this pass's
     * library is still the one in use and the pass has not been cancelled.
     */
    fun start(work: suspend (current: () -> Boolean) -> Unit): Boolean {
        if (running) return false
        val mine = generation
        job = scope.launch { work { generation == mine && isActive } }
        return true
    }
}
