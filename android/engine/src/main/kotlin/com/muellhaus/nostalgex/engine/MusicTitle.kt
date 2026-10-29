package com.muellhaus.nostalgex.engine

/**
 * "Artist - Song" out of a music video's title: scripts/nostalgex-music-brainz.js's
 * cleanTitle, stripFeaturing, parseTitle and parseMusicVideoFromPlex. The MusicBrainz and
 * Deezer lookups that refine it afterwards are not ported.
 */
object MusicTitle {
    private val BRACKETS = Regex("\\[[^\\]]*\\]|\\{[^}]*\\}")
    private val TRAILING_YEAR = Regex("[${JsText.WS}]*\\((?:19|20)\\d\\d\\)[${JsText.WS}]*\\z")
    private val YEAR_IN_PARENS = Regex("\\([^)]*(?:19|20)\\d\\d[^)]*\\)")
    private val NOISE = Regex("(?<![A-Za-z0-9_])(official|video|hd|hq|lyrics?|remaster(?:ed)?|mv|xvid|dvdrip|vgb|prv)(?![A-Za-z0-9_])!?", RegexOption.IGNORE_CASE)
    private val WS_RUN = Regex("[${JsText.WS}]+")
    private val EDGES = Regex("^[${JsText.WS}\\-!.]+|[${JsText.WS}\\-!.]+\\z")
    private val FEAT_ARTIST = Regex("[${JsText.WS}]+(?:ft\\.?|feat\\.?|featuring|with|and the)[${JsText.WS}]+${JsText.DOT}*\\z", RegexOption.IGNORE_CASE)
    private val FEAT_SONG = Regex("[${JsText.WS}]+(?:ft\\.?|feat\\.?|featuring)[${JsText.WS}]+${JsText.DOT}*\\z", RegexOption.IGNORE_CASE)
    private val COMMA_EDGES = Regex("^[${JsText.WS},]+|[${JsText.WS},]+\\z")
    private val LONE_DASH = Regex("^(${JsText.DOT}{2,}?)-(${JsText.DOT}+)\\z")

    fun cleanTitle(raw: String?): String {
        var t = (raw ?: "").replace('_', ' ')
        t = t.replace(BRACKETS, "")
        t = t.replace(TRAILING_YEAR, "")
        t = t.replace(YEAR_IN_PARENS, "")
        t = t.replace(NOISE, "")
        t = t.replace(WS_RUN, " ")
        return t.replace(EDGES, "")
    }

    private fun stripFeaturing(s: String, artistSide: Boolean): String =
        s.replace(if (artistSide) FEAT_ARTIST else FEAT_SONG, "").replace(COMMA_EDGES, "")

    data class Parsed(val artist: String?, val song: String)

    fun parseTitle(raw: String?): Parsed {
        val cleaned = cleanTitle(raw)
        val dash = cleaned.indexOf(" - ")
        if (dash > 0) {
            val artist = stripFeaturing(cleaned.substring(0, dash), true)
            var song = JsText.trim(cleaned.substring(dash + 3))
            val next = song.indexOf(" - ")
            if (next > 0) song = song.substring(0, next)
            song = stripFeaturing(song, false)
            if (artist.isNotEmpty() && song.isNotEmpty()) return Parsed(artist, song)
        }
        val by = cleaned.lowercase().lastIndexOf(" by ")
        if (by > 0) {
            val song = stripFeaturing(cleaned.substring(0, by), false)
            val artist = stripFeaturing(cleaned.substring(by + 4), true)
            if (artist.isNotEmpty() && song.isNotEmpty()) return Parsed(artist, song)
        }
        LONE_DASH.find(cleaned)?.let { m ->
            if (!m.groupValues[1].contains(" - ")) {
                val artist = stripFeaturing(m.groupValues[1], true)
                val song = stripFeaturing(m.groupValues[2], false)
                if (artist.length >= 2 && song.length >= 2) return Parsed(artist, song)
            }
        }
        return Parsed(null, stripFeaturing(cleaned, false))
    }

    /** The title and artist a music video shows: the artist from the server when it names one, else from the title. */
    fun musicVideo(rawTitle: String, parentTitle: String?, grandparentTitle: String?): Pair<String, String?> {
        val hint = parentTitle?.ifEmpty { null } ?: grandparentTitle?.ifEmpty { null }
        val parsed = parseTitle(rawTitle)
        return (parsed.song.ifEmpty { rawTitle }) to (hint ?: parsed.artist)
    }
}
