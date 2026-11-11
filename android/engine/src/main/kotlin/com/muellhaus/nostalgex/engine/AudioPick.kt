package com.muellhaus.nostalgex.engine

/**
 * A director's or cast commentary is never the audio a channel starts on while the file has
 * another track (#286): scripts/nostalgex-audio-pick.js and the Apple TV's AudioTrackCommentary,
 * held to scripts/audio-pick-golden.json. Servers name it in the track title ("Commentary",
 * "Director's Commentary", "Audio Commentary with the cast") and often flag it default or give
 * it the viewer's language, so a language match alone lands on it.
 */
object AudioPick {
    /** True when any of the titles says "commentary", in any case. */
    fun isCommentary(vararg titles: String?): Boolean = titles.any { it?.lowercase()?.contains("commentary") == true }

    /** `items` without the commentaries, unless that leaves nothing: a file whose only audio is one still plays it. */
    fun <T> skippingCommentary(items: List<T>, titlesOf: (T) -> List<String?>): List<T> {
        val rest = items.filter { !isCommentary(*titlesOf(it).toTypedArray()) }
        return rest.ifEmpty { items }
    }

    /** A Plex audio stream from an item's own metadata. */
    data class PlexAudio(val id: Long, val selected: Boolean, val title: String?, val displayTitle: String?)

    /**
     * The Plex audio stream to play (PlexAPIService.playbackAudioStream(in:), plexAudioStream): the
     * one Plex marks selected, else the first, never a commentary while another track exists.
     */
    fun plexAudioStream(streams: List<PlexAudio>): PlexAudio? {
        val pool = skippingCommentary(streams) { listOf(it.title, it.displayTitle) }
        return pool.firstOrNull { it.selected } ?: pool.firstOrNull()
    }
}
