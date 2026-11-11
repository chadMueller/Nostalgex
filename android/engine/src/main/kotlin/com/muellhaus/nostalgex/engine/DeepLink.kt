package com.muellhaus.nostalgex.engine

/**
 * A link that tunes a channel (#194): `nostalgex://channel/<id>`, the link the home-screen row
 * opens and the Apple TV's Top Shelf names. As the Roku's DeepLink.brs: the link names a guide
 * channel by its id, or else by the number on the guide, and the app tunes it full screen. A
 * link that names no channel leaves the guide as it is.
 */
object DeepLink {
    const val SCHEME = "nostalgex"
    const val HOST = "channel"

    /** The link for a channel. */
    fun forChannel(id: Int) = "$SCHEME://$HOST/$id"

    /** What a link names (NxDeepLinkFrom's contentId), or null when it isn't a channel link or names nothing. */
    fun contentId(uri: String?): String? {
        val u = uri?.trim() ?: return null
        val prefix = "$SCHEME://$HOST/"
        if (!u.lowercase().startsWith(prefix)) return null
        return u.substring(prefix.length).substringBefore('?').substringBefore('#').trim('/', ' ').takeIf { it.isNotEmpty() }
    }

    /** The index of the channel a link names, by id first and then by number (NxDeepLinkChannel), or -1. */
    fun <T> channelIndex(channels: List<T>, id: (T) -> Int, number: (T) -> Int, contentId: String?): Int {
        if (contentId.isNullOrEmpty()) return -1
        val byId = channels.indexOfFirst { id(it).toString() == contentId }
        if (byId >= 0) return byId
        return channels.indexOfFirst { number(it).toString() == contentId }
    }
}
