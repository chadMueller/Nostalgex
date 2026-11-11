package com.muellhaus.nostalgex.engine

import java.io.IOException

/**
 * What one server's library scan read, library by library (#198). A library that errors is
 * skipped, so one bad library leaves the rest (Android is ahead of the Apple TV there, which
 * fails the whole scan). But a scan where every library errored and none was read is a failed
 * scan, not an empty library: before, the empty list was saved, the guide said NO CHANNELS
 * FOUND, and every launch from the saved copy said it again.
 */
class SectionTally {
    private var read = 0
    private var first: Exception? = null

    /** A library came back, whether or not it held anything. */
    fun read() { read++ }

    fun failed(e: Exception) {
        if (first == null) first = e
    }

    /** Throws [EveryLibraryFailed] with the first error when libraries failed and none was read. */
    fun check() {
        val e = first
        if (read == 0 && e != null) throw EveryLibraryFailed(e)
    }
}

/** Every library a server listed failed to read. `cause` is the first library's error, for the words CONNECTION FAILED shows. */
class EveryLibraryFailed(override val cause: Exception) : IOException("every library failed to read: ${cause.message}", cause)
