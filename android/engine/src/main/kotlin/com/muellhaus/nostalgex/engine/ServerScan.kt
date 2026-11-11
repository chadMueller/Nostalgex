package com.muellhaus.nostalgex.engine

/**
 * Reading the servers in use one after another (#285, the Apple TV 1.0.32's rule for #146).
 * STOP WAITING ends the whole scan: once the viewer presses it, no further server is read, and
 * what the servers before it gave is kept. A server that stalls by itself (no press) is skipped
 * alone and the next one is read, as before.
 */
object ServerScan {
    /** One server's read. */
    sealed class Outcome<out T> {
        /** It returned items; `abandoned` when the stall watch stopped it part way, `byViewer` when that was STOP WAITING. */
        data class Read<T>(val items: List<T>, val abandoned: Boolean, val byViewer: Boolean) : Outcome<T>()
        /** It was abandoned with nothing read. */
        data class Stalled(val byViewer: Boolean, val error: Exception) : Outcome<Nothing>()
        /** Every library on it failed (#198); the others still count. */
        data class Failed(val error: Exception) : Outcome<Nothing>()
    }

    data class Totals<T>(
        val items: List<T>,
        val abandoned: Boolean,
        /** Servers that returned items. */
        val serversRead: Int,
        /** Servers never started because the viewer stopped waiting. */
        val serversSkipped: Int,
        /** With no server read, what to report: the stall before a failure, as before. */
        val error: Exception?,
    )

    inline fun <S, T> readAll(servers: List<S>, read: (S) -> Outcome<T>): Totals<T> {
        val items = ArrayList<T>()
        var abandoned = false
        var serversRead = 0
        var stalled: Exception? = null
        var failed: Exception? = null
        for ((i, server) in servers.withIndex()) {
            val byViewer = when (val o = read(server)) {
                is Outcome.Read -> {
                    items += o.items
                    abandoned = abandoned || o.abandoned
                    serversRead++
                    o.byViewer
                }
                is Outcome.Stalled -> {
                    abandoned = true
                    stalled = o.error
                    o.byViewer
                }
                is Outcome.Failed -> {
                    failed = failed ?: o.error
                    false
                }
            }
            if (byViewer) return Totals(items, abandoned, serversRead, servers.size - i - 1, if (serversRead == 0) stalled ?: failed else null)
        }
        return Totals(items, abandoned, serversRead, 0, if (serversRead == 0) stalled ?: failed else null)
    }
}
