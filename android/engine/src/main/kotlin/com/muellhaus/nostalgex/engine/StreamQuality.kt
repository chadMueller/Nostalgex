package com.muellhaus.nostalgex.engine

import java.net.URI

/**
 * STREAM QUALITY: the ceiling for transcoded playback, as the Apple TV's StreamQuality.swift.
 * scripts/stream-quality-golden.json holds the table to the Apple TV's (StreamQualityGoldenTest).
 */
enum class StreamQuality(
    val id: String,
    val displayName: String,
    val detail: String,
    /** Plex's `maxVideoBitrate`, in kbps. */
    val maxBitrateKbps: Int,
    val width: Int,
    val height: Int,
    /** Plex's 0 to 100 `videoQuality`. */
    val videoQualityIndex: Int,
    /**
     * The most a direct play may carry over a remote connection, in kbps: it has no adaptive
     * fallback, so a file over this is transcoded instead. Never applied on a home network.
     */
    val remoteDirectPlayCeilingKbps: Int,
) {
    AUTO("auto", "Auto", "Up to 4K, drops quality when the connection can't keep up.", 40_000, 3840, 2160, 100, 20_000),
    MAXIMUM("maximum", "Maximum", "4K, 40 Mbps, never reduced. Fast local networks only.", 40_000, 3840, 2160, 100, Int.MAX_VALUE),
    HIGH("high", "High", "1080p, 12 Mbps.", 12_000, 1920, 1080, 90, 12_000),
    MEDIUM("medium", "Medium", "720p, 4 Mbps. Works on most hotel and cafe wifi.", 4_000, 1280, 720, 75, 4_000),
    LOW("low", "Low", "480p, 1.5 Mbps. For weak or metered connections.", 1_500, 854, 480, 60, 1_500);

    val resolutionString get() = "${width}x$height"

    companion object {
        /** The Apple TV's UserDefaults key and the web's localStorage key. */
        const val STORAGE_KEY = "nostalgex_stream_quality"

        fun fromId(id: String?) = entries.firstOrNull { it.id == id } ?: AUTO

        /**
         * PlexAPIService.isLikelyLocalServer: a private, loopback or link-local address, or a
         * plex.direct name that encodes one (192-168-1-50.abc.plex.direct).
         */
        fun isLikelyLocalServer(serverUrl: String?): Boolean {
            val host = runCatching { URI(serverUrl ?: return false).host }.getOrNull()?.lowercase() ?: return false
            if (host == "localhost" || host.endsWith(".local")) return true
            val octets = host.replace('-', '.').split('.').mapNotNull { it.toIntOrNull() }
            if (octets.size < 4) return false
            val (a, b) = octets
            return a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31) || a == 127 || (a == 169 && b == 254)
        }
    }
}
