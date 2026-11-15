package com.muellhaus.nostalgex.engine

/**
 * Which year a music video gets, in trust order (the Apple TV's `MusicYear`): the year in its own filename, the MusicBrainz first
 * release, then the server's only when it is plausible. 1970 is the servers' "unknown", and anything at or past the current year is
 * the date it was added. (The Android loaders clean a title before the item is made, so the filename's year is not available here;
 * the other two steps are the Apple TV's.)
 */
object MusicYear {
    fun resolve(titleYear: Int?, musicBrainzYear: Int?, serverYear: Int?, thisYear: Int): Int? {
        if (titleYear != null) return titleYear
        if (musicBrainzYear != null) return musicBrainzYear
        if (serverYear == null) return null
        return if (serverYear > 1970 && serverYear < thisYear) serverYear else null
    }
}
