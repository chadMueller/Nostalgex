package com.muellhaus.nostalgex.engine

/**
 * The `X-Plex-Client-Profile-Extra` the Plex server stream sends (#192), so a 5.1 film keeps its
 * channels and a 4K HEVC Main 10 film is copied, not re-encoded to 1080p H.264. The Roku's shape
 * (`NxPlexAudioExtra` in roku/source/plex/PlexPlayback.brs): codecs added to Plex's own profile
 * for the platform, each only when this TV takes it, plus the Apple TV's raised HEVC limits and
 * E-AC-3 cap (PlexAPIService.clientProfileExtra, eac3ChannelCap).
 *
 * Measured on a Plex 1.43.5 server, request as Android sends it (`X-Plex-Platform=Android`):
 * - Without it, a DTS or TrueHD 5.1 film came as stereo AAC, and a 4K HEVC Main 10 film as 1080p
 *   8-bit H.264 with stereo AAC.
 * - With it, on a TV that takes E-AC-3: DTS, TrueHD and AAC 5.1 come as E-AC-3 5.1, AC-3 and
 *   E-AC-3 are copied, and 4K HEVC Main 10 is copied at 3840x2160.
 * - The Apple TV's form (a whole `add-transcode-target` with an mpegts container) is ignored for
 *   the Android platform: everything came as stereo AAC and H.264. So the targets are added a
 *   codec at a time, as the Roku's are.
 * - Lossless audio is never a target: the Apple TV measured TrueHD made into ALAC at negative
 *   speed (picture, no sound).
 */
object PlexClientProfile {
    private const val TARGET = "type=videoProfile&context=streaming&protocol=hls"

    /** The Apple TV's eac3ChannelCap. Must be scope `videoAudioCodec`: `audioCodec` is ignored. */
    const val EAC3_CHANNEL_CAP = "add-limitation(scope=videoAudioCodec&scopeName=eac3&type=upperBound&name=audio.channels&value=6)"

    /**
     * `hevc`: the TV decodes HEVC, so Plex may copy it instead of making H.264 (never on the
     * capped rung, which asks for 1080p H.264 on purpose). `hevc4k10`: and up to 3840x2160 at
     * 10 bits, so Plex's base limits (1080 lines, 8 bits) are lifted for it. `ac3`, `eac3`: the
     * TV or its receiver takes them; a Dolby track copied to a TV that can't plays silent.
     */
    fun extra(hevc: Boolean, hevc4k10: Boolean, ac3: Boolean, eac3: Boolean): String {
        val parts = ArrayList<String>()
        if (hevc) {
            parts += "add-transcode-target-codec($TARGET&videoCodec=hevc)"
            if (hevc4k10) {
                parts += "add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.width&value=3840&replace=true)"
                parts += "add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.height&value=2160&replace=true)"
                parts += "add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.bitDepth&value=10&replace=true)"
            }
        }
        if (ac3) parts += "add-transcode-target-audio-codec($TARGET&audioCodec=ac3)"
        if (eac3) {
            parts += "add-transcode-target-audio-codec($TARGET&audioCodec=eac3)"
            parts += EAC3_CHANNEL_CAP
        }
        return parts.joinToString("+")
    }

    private val PROFILE_FIVE = Regex("^dv(he|h1)\\.05(\\.|$)", RegexOption.IGNORE_CASE)

    /**
     * Whether the server stream must not copy the HEVC of a Dolby Vision track this TV has no
     * decoder for (#193), from the track's `codecs` as Media3 reports it. Profile 5's base layer
     * is in Dolby's own colour space and shows green and purple on a plain HEVC decoder, so HEVC
     * isn't offered and Plex refuses (2003). Profile 8's base layer is HDR10 and is copied as it
     * was. Measured on a Google TV emulator: "dvhe.05.06" and "dvhe.08.06".
     */
    fun withholdHevcFor(codecs: List<String>): Boolean = codecs.any { PROFILE_FIVE.containsMatchIn(it.trim()) }
}
