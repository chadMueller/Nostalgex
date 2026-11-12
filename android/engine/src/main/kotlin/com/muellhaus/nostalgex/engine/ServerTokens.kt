package com.muellhaus.nostalgex.engine

/**
 * MediaItem.serverToken isn't saved, so items read back from `library.json` or a kept scan
 * section get it again here, from the servers signed in now, matched on the item's address.
 * An item whose address no current server has gets none, as it had none to play with.
 */
object ServerTokens {
    fun fill(items: List<MediaItem>, tokenByUrl: Map<String, String>): List<MediaItem> =
        items.map { it.copy(serverToken = it.serverUrl?.let(tokenByUrl::get)) }

    /**
     * A kept scan section's items (#288), all from one server: they take its address and token
     * as they are now. The address too, so a server that moved between the killed scan and the
     * resume still matches in `fill` when the saved library is next read.
     */
    fun claim(items: List<MediaItem>, url: String, token: String): List<MediaItem> =
        items.map { it.copy(serverUrl = url, serverToken = token) }
}
