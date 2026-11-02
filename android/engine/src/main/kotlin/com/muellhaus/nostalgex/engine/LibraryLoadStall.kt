package com.muellhaus.nostalgex.engine

/**
 * The counters a healthy library scan keeps moving (LibraryLoadProgressSample). Compared as a
 * whole: any field changing means the load is still doing something, however slowly. `detail`
 * carries what the counters can't, such as shows completed inside one section.
 */
data class LibraryLoadProgressSample(
    val phase: Int = 0,
    val sectionIndex: Int = 0,
    val totalSections: Int = 0,
    val itemsFound: Int = 0,
    val detail: String = "",
)

/**
 * Separates "stalled" from "slow but working" (LibraryLoadStallDetector.swift). Elapsed time
 * alone can't: a large library over a thin connection takes many minutes, and killing that
 * scan would punish the viewers this protects. Only the absence of forward progress counts.
 */
class LibraryLoadStallDetector(
    start: LibraryLoadProgressSample,
    nowSec: Double,
    val warnAfter: Double = DEFAULT_WARN_AFTER,
    val stallAfter: Double = DEFAULT_STALL_AFTER,
) {
    sealed class Verdict {
        object Progressing : Verdict() {
            override fun toString() = "Progressing"
        }
        /** Quiet long enough to tell the viewer, not long enough to act on. */
        data class Slow(val secondsWithoutProgress: Double) : Verdict()
        data class Stalled(val secondsWithoutProgress: Double) : Verdict()
    }

    private var lastSample = start
    private var lastChangeAt = nowSec

    fun evaluate(sample: LibraryLoadProgressSample, nowSec: Double): Verdict {
        if (sample != lastSample) {
            lastSample = sample
            lastChangeAt = nowSec
            return Verdict.Progressing
        }
        val idle = nowSec - lastChangeAt
        if (idle >= stallAfter) return Verdict.Stalled(idle)
        if (idle >= warnAfter) return Verdict.Slow(idle)
        return Verdict.Progressing
    }

    companion object {
        /**
         * Above a single request's whole retry ladder (about 181 s on the Apple TV), which ends
         * in a real error worth more than anything invented here.
         */
        const val DEFAULT_STALL_AFTER = 210.0
        /** Long enough that a slow page doesn't nag, short enough that nobody sits before a frozen screen. */
        const val DEFAULT_WARN_AFTER = 60.0
    }
}

/** A scan told to stop between requests: STOP WAITING, or the watchdog (LibraryLoadStalled). */
class ScanCancelled : RuntimeException("library scan stopped")
