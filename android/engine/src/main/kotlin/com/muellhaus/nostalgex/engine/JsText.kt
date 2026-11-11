package com.muellhaus.nostalgex.engine

/**
 * JavaScript's text rules, where Kotlin's differ. The engines are ports of
 * scripts/nostalgex-daily-manifest.js and scripts/nostalgex-channel-filter.cjs, and a
 * title has to split, trim and match exactly as it does there.
 */
internal object JsText {
    /** JavaScript's `\s`. Java's `\s` is ASCII only and Kotlin's trim() uses isWhitespace. */
    const val WS = "\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"

    /** JavaScript's `.`: anything but a line terminator. */
    const val DOT = "[^\\n\\r\\u2028\\u2029]"

    private val wsChars: (Char) -> Boolean = { c ->
        c == '\t' || c == '\n' || c == '\u000B' || c == '\u000C' || c == '\r' || c == ' ' ||
            c == '\u00A0' || c == '\u1680' || c in '\u2000'..'\u200A' || c == '\u2028' ||
            c == '\u2029' || c == '\u202F' || c == '\u205F' || c == '\u3000' || c == '\uFEFF'
    }

    fun trim(s: String): String = s.trim(wsChars)

    private fun isWordChar(c: Char) = c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '_'

    /** `\b` as JavaScript reads it without the `u` flag: ASCII word characters only. */
    private fun boundaryAt(s: String, i: Int): Boolean {
        val before = i > 0 && isWordChar(s[i - 1])
        val after = i < s.length && isWordChar(s[i])
        return before != after
    }

    /** `new RegExp("\\b" + escaped + "\\b").test(haystack)`. */
    fun containsWord(haystack: String, needle: String): Boolean {
        if (needle.isEmpty()) return false
        var from = 0
        while (true) {
            val i = haystack.indexOf(needle, from)
            if (i < 0) return false
            if (boundaryAt(haystack, i) && boundaryAt(haystack, i + needle.length)) return true
            from = i + 1
        }
    }
}
