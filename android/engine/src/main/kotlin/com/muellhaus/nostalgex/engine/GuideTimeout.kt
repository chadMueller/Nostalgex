package com.muellhaus.nostalgex.engine

/**
 * GUIDE TIMEOUT (Settings > PLAYBACK & PICTURE, #290): after this long with no remote press on
 * the guide, the playing channel goes full screen, so the guide's still logo, header and grid
 * lines don't burn into an OLED; full-screen video keeps moving. The Apple TV's GuideTimeout and
 * the web's nostalgex-guide-timeout.js. Per TV, never synced: burn-in is a property of the screen.
 */
enum class GuideTimeout(val stored: String, val label: String, val seconds: Long?) {
    OFF("off", "OFF", null),
    FIVE_MINUTES("5m", "5 MIN", 5 * 60L),
    FIFTEEN_MINUTES("15m", "15 MIN", 15 * 60L);

    /** One press on the row: OFF, 5 MIN, 15 MIN, and round again. */
    val next: GuideTimeout get() = entries[(ordinal + 1) % entries.size]

    companion object {
        const val STORAGE_KEY = "nostalgex_guide_timeout"

        /** The one line to change to make the guide stay up by default. */
        val DEFAULT = FIVE_MINUTES

        /** The Apple TV checks every 5 seconds. */
        const val CHECK_MS = 5_000L

        /** Nothing saved, or anything that isn't one of the three, is the default. */
        fun parse(stored: String?): GuideTimeout = entries.firstOrNull { it.stored == stored } ?: DEFAULT

        /**
         * Whether the guide should hand over to full screen now (shouldGoFullscreen): only while
         * the guide is the screen in front of the viewer and a channel is playing, so Settings,
         * the loading screen and an empty guide are left alone.
         */
        fun shouldGoFullScreen(timeout: GuideTimeout, lastActivityMs: Long, nowMs: Long, guideIsFrontmost: Boolean, isPlaying: Boolean): Boolean {
            val seconds = timeout.seconds ?: return false
            if (!guideIsFrontmost || !isPlaying) return false
            return nowMs - lastActivityMs >= seconds * 1000
        }
    }
}
