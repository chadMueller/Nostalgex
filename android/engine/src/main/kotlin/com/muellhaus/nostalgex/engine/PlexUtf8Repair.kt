package com.muellhaus.nostalgex.engine

/**
 * A Plex response with bytes that are not UTF-8 (PlexUTF8Repair, #196). Plex copies a file or
 * folder name into its JSON byte for byte, so an unmatched item named in Latin-1 puts a lone
 * 0xE9 in its title. Decoded as UTF-8 that byte becomes U+FFFD and the guide reads
 * "Caf� Society"; the Apple TV, the web tuner and the Roku read it as Windows-1252 and show
 * "Café Society". Held to scripts/utf8-repair-golden.json by Utf8RepairGoldenTest.
 *
 * The rule: every byte outside a well-formed UTF-8 sequence (Unicode table 3-7) is read as
 * Windows-1252; the five bytes Windows-1252 leaves undefined keep their Latin-1 code point. A
 * stray byte is always 0x80 or above, so the repair can't add a quote, a backslash or a control
 * character to the JSON around it. A valid response, which is nearly every one, is decoded as
 * it is.
 */
object PlexUtf8Repair {
    /** The text a JSON parser should read, and how many bytes were repaired (0 for valid UTF-8). */
    data class Decoded(val text: String, val repairedBytes: Int)

    /**
     * `bytes` as text: UTF-8 when valid, otherwise repaired first. One leading byte order mark
     * is dropped, as OkHttp's `body.string()` did and a JSON parser expects; any other U+FEFF
     * is kept.
     */
    fun decode(bytes: ByteArray): Decoded {
        fun bomless(text: String) = if (text.startsWith('\uFEFF')) text.substring(1) else text
        val first = firstInvalidIndex(bytes) ?: return Decoded(bomless(String(bytes, Charsets.UTF_8)), 0)
        val out = StringBuilder(bytes.size + 64)
        out.append(String(bytes, 0, first, Charsets.UTF_8))
        var i: Int = first
        var runStart: Int = first
        var repaired = 0
        while (i < bytes.size) {
            val length = sequenceLength(bytes, i)
            if (length > 0) { i += length; continue }
            out.append(String(bytes, runStart, i - runStart, Charsets.UTF_8))
            out.append(windows1252(bytes[i].toInt() and 0xFF))
            repaired++
            i++
            runStart = i
        }
        out.append(String(bytes, runStart, bytes.size - runStart, Charsets.UTF_8))
        return Decoded(bomless(out.toString()), repaired)
    }

    /** The Apple TV's line when a response was repaired (PlexUTF8Repair.logLine). */
    fun logLine(context: String, repairedBytes: Int) =
        "PLEX UTF-8 $context: repaired $repairedBytes byte(s) that were not UTF-8, read as Windows-1252"

    /** Index of the first byte that doesn't start a well-formed UTF-8 sequence, or null when all are well formed. */
    fun firstInvalidIndex(bytes: ByteArray): Int? {
        var i = 0
        while (i < bytes.size) {
            // ASCII, nearly all of a Plex response.
            if (bytes[i] >= 0) { i++; continue }
            val length = sequenceLength(bytes, i)
            if (length == 0) return i
            i += length
        }
        return null
    }

    /** Length of the well-formed UTF-8 sequence that starts at `i` (Unicode table 3-7), or 0. */
    fun sequenceLength(bytes: ByteArray, i: Int): Int {
        val b0 = bytes[i].toInt() and 0xFF
        if (b0 < 0x80) return 1
        fun cont(k: Int, low: Int = 0x80, high: Int = 0xBF): Boolean {
            if (i + k >= bytes.size) return false
            val b = bytes[i + k].toInt() and 0xFF
            return b in low..high
        }
        return when (b0) {
            in 0xC2..0xDF -> if (cont(1)) 2 else 0
            0xE0 -> if (cont(1, 0xA0) && cont(2)) 3 else 0
            in 0xE1..0xEC, 0xEE, 0xEF -> if (cont(1) && cont(2)) 3 else 0
            0xED -> if (cont(1, 0x80, 0x9F) && cont(2)) 3 else 0
            0xF0 -> if (cont(1, 0x90) && cont(2) && cont(3)) 4 else 0
            in 0xF1..0xF3 -> if (cont(1) && cont(2) && cont(3)) 4 else 0
            0xF4 -> if (cont(1, 0x80, 0x8F) && cont(2) && cont(3)) 4 else 0
            else -> 0
        }
    }

    private val HIGH = intArrayOf(
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    )

    /** Windows-1252: 0xA0 to 0xFF are Latin-1; 0x80 to 0x9F hold the curly quotes, dashes and the euro sign. */
    fun windows1252(byte: Int): Char = (if (byte in 0x80..0x9F) HIGH[byte - 0x80] else byte).toChar()
}
