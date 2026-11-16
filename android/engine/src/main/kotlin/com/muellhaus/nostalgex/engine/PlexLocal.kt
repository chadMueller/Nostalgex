package com.muellhaus.nostalgex.engine

/**
 * A Plex server signed in to without plex.tv (I-057, the Apple TV's `connectLocalPlex`): the server lets this network in without a sign-in
 * (Plex's "List of IP addresses and networks that are allowed without auth"), so the token is empty and nothing asks plex.tv.
 */
object PlexLocal {
    /** Plex's own port, added when none is typed. */
    const val DEFAULT_PORT = 32400

    /**
     * What a server that wants a sign-in from this TV is told to change: the setting's own name, so it can be found in Plex
     * (AppState.localPlexNeedsAuthMessage).
     */
    const val NEEDS_AUTH_MESSAGE = "This Plex server wants a sign-in from this Android TV. In Plex, open Settings, then Network, and add your home network to " +
        "\"List of IP addresses and networks that are allowed without auth\", then try again."

    /**
     * The addresses to try for what was typed (PlexAPIService.localServerCandidates): as typed when it has a port, otherwise with Plex's
     * 32400; http unless https was typed. Empty when nothing usable was typed.
     */
    fun candidates(raw: String): List<String> {
        var typed = raw.trim()
        while (typed.endsWith("/")) typed = typed.dropLast(1)
        if (typed.isEmpty()) return emptyList()
        val lower = typed.lowercase()
        val hasScheme = lower.startsWith("http://") || lower.startsWith("https://")
        val withScheme = if (hasScheme) typed else "http://$typed"
        val scheme = withScheme.substringBefore("://").lowercase()
        // Host (and port) is what is between the scheme and the first slash, query or fragment; a path typed after it is dropped.
        val authority = withScheme.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#')
        if (authority.isEmpty() || authority.contains(' ') || authority.contains('@')) return emptyList()
        val (host, port) = splitHostPort(authority) ?: return emptyList()
        if (host.isEmpty()) return emptyList()
        val hostPart = if (host.contains(':')) "[$host]" else host
        return listOf("$scheme://$hostPart:${port ?: DEFAULT_PORT}")
    }

    /** "host", "host:32400", "[::1]:32400" or "[::1]": the host and the port if there is one; null when the port is not a number. */
    private fun splitHostPort(authority: String): Pair<String, Int?>? {
        if (authority.startsWith("[")) {
            val end = authority.indexOf(']')
            if (end < 0) return null
            val host = authority.substring(1, end)
            val rest = authority.substring(end + 1)
            if (rest.isEmpty()) return host to null
            if (!rest.startsWith(":")) return null
            return host to (rest.drop(1).toIntOrNull()?.takeIf { it in 1..65535 } ?: return null)
        }
        val colon = authority.lastIndexOf(':')
        if (colon < 0) return authority to null
        val port = authority.substring(colon + 1).toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
        return authority.substring(0, colon) to port
    }

    /** Whether a token is worth sending: the empty one (a local server with no sign-in) is left out of every header and URL. */
    fun hasToken(token: String?): Boolean = !token.isNullOrEmpty()

    /** True when the saved sign-in is one with no plex.tv, so nothing may ask plex.tv for it. */
    fun asksPlexTv(noPlexTv: Boolean): Boolean = !noPlexTv

    /** Signed in to Plex: servers chosen, and either a plex.tv token or the no-plex.tv flag (an empty token is not a missing one). */
    fun isSignedIn(token: String?, noPlexTv: Boolean, serverCount: Int): Boolean =
        serverCount > 0 && (if (noPlexTv) true else token != null)
}
