package com.muellhaus.nostalgex.engine

/**
 * The last few times playback was given up on, and why (PlaybackDiagnostics), so Settings can
 * show the newest under RESCAN LIBRARY: "device" or "server" without a debugger. Logging only:
 * nothing here changes what the player does. The app stores the lines; this makes them.
 */
object PlaybackDiagnostics {
    /** The Apple TV's key for the stored lines, newest first. */
    const val KEY = "nostalgex_playback_verdicts_v2"

    /** How many lines are kept. */
    const val KEEP = 5

    /** One stored line: `<stamp> <outcome>: "<title>", <detail>`, with anything secret taken out. */
    fun line(stamp: String, outcome: String, title: String, detail: String): String =
        redact("$stamp $outcome: \"$title\", $detail")

    /** `rows` with `line` added at the front, at most [KEEP]. */
    fun push(rows: List<String>, line: String): List<String> = (listOf(line) + rows).take(KEEP)

    private val SECRETS = listOf(
        Regex("""(?i)\b(?:https?|plex)://[^\s<>"']+"""),
        Regex("""(?i)authorization["']?\s*[:=]\s*[^\r\n,]+"""),
        Regex("""(?i)(?:x[-_]plex[-_]token|x[-_]emby[-_]token|access[-_]?token|api[-_]?key|token|password|secret)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s&,;]+)"""),
    )

    /**
     * Error text can carry a full URL, a token or a header dump (redactSensitiveText): decoded
     * twice first, so an encoded URL is caught, then each such run is `[redacted]`.
     */
    fun redact(text: String): String {
        var safe = text
        repeat(2) { safe = runCatching { java.net.URLDecoder.decode(safe.replace("+", "%2B"), "UTF-8") }.getOrDefault(safe) }
        for (r in SECRETS) safe = r.replace(safe, "[redacted]")
        return safe
    }
}
