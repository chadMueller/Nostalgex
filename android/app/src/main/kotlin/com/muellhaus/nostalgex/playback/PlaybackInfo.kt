package com.muellhaus.nostalgex.playback

import com.muellhaus.nostalgex.engine.StreamQuality

/**
 * PLAYBACK INFORMATION, as PlaybackInformation.swift: fixed labels, bounded numbers and
 * allowlisted codec names only. It never shows a URL, server, session or error text.
 */
data class PlaybackInfo(
    val qualityAtTune: StreamQuality,
    val videoCodec: String?,
    val audioCodec: String?,
    val delivery: Delivery? = null,
    val reason: Reason = Reason.NONE,
    val ready: Boolean = false,
) {
    /** Observed recovery decisions, never a guessed cause. */
    enum class Reason(val message: String) {
        NONE("No fallback used."),
        SERVER_STREAM_SELECTED("Server streaming was selected for this source."),
        DIRECT_PLAY_FAILED("Direct Play failed. Trying a server stream."),
    }

    data class Row(val label: String, val value: String)

    fun rows(width: Int?, height: Int?): List<Row> = listOf(
        Row("BACKEND", "Plex"),
        Row("PLAYBACK", if (!ready) "Loading" else when (delivery) {
            Delivery.DIRECT_PLAY -> "Direct Play"
            Delivery.TRANSCODE -> "Server stream"
            null -> "Unknown"
        }),
        Row("QUALITY AT TUNE", qualityAtTune.displayName),
        Row("PLAYER SIZE", if (ready && width != null && height != null && width in 1..65_536 && height in 1..65_536) "$width × $height" else "Unknown"),
        Row("SOURCE METADATA", "Video: ${codec(videoCodec, VIDEO)} · Audio: ${codec(audioCodec, AUDIO)}"),
        Row("FALLBACK", reason.message),
    )

    companion object {
        /** The Apple TV's note; "AVPlayer" is ExoPlayer here. */
        const val EVIDENCE_NOTE = "Source codecs come from library metadata. Player size is reported by ExoPlayer. " +
            "Quality is the selection at tune time, not a measured output. Server streams may copy or convert media; " +
            "the current resolver does not identify which."

        private val VIDEO = mapOf(
            "h264" to "H.264", "avc" to "H.264", "avc1" to "H.264", "hevc" to "HEVC", "h265" to "HEVC", "hev1" to "HEVC",
            "hvc1" to "HEVC", "mpeg2video" to "MPEG-2", "mpeg4" to "MPEG-4", "av1" to "AV1", "vp9" to "VP9", "vc1" to "VC-1",
        )
        private val AUDIO = mapOf(
            "aac" to "AAC", "ac3" to "AC-3", "eac3" to "E-AC-3", "dts" to "DTS", "dca" to "DTS", "truehd" to "TrueHD",
            "flac" to "FLAC", "alac" to "ALAC", "mp3" to "MP3", "opus" to "Opus", "vorbis" to "Vorbis", "pcm" to "PCM",
        )

        private fun codec(value: String?, known: Map<String, String>) = known[value?.trim()?.lowercase() ?: ""] ?: "Unknown"
    }
}
