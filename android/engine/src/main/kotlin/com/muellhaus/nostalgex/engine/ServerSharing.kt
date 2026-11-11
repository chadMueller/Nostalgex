package com.muellhaus.nostalgex.engine

import java.net.URI

/**
 * Whether a new set of servers is still the viewer's old library (#289, the Apple TV's
 * sharesAServer): the saved playback failures are about the old servers, so they go when the
 * viewer moves to servers that share none of them, and stay when one of several is added or
 * removed.
 */
object ServerSharing {
    /** A server by its machine identifier (Plex) or server id (Jellyfin, Emby), and its address. */
    data class Ref(val id: String?, val url: String?)

    /**
     * True when some old server is a new one: the same identifier, or the same host and port (an
     * older install keyed its one server by address). With no old servers there is nothing to keep.
     */
    fun sharesAServer(old: List<Ref>, new: List<Ref>): Boolean = old.any { o ->
        new.any { n ->
            (!o.id.isNullOrEmpty() && o.id == n.id) || (hostPort(o.url)?.let { it == hostPort(n.url) } ?: false)
        }
    }

    /** "host:port", the port from the scheme when the address leaves it out; null when unreadable. */
    fun hostPort(url: String?): String? {
        val u = runCatching { URI(url?.trim() ?: return null) }.getOrNull() ?: return null
        val host = u.host?.lowercase()?.ifEmpty { null } ?: return null
        val port = if (u.port != -1) u.port else when (u.scheme?.lowercase()) {
            "https" -> 443
            "http" -> 80
            else -> return null
        }
        return "$host:$port"
    }
}
