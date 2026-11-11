package com.muellhaus.nostalgex.engine

/**
 * MediaItem.serverToken isn't saved, so items read back from `library.json` or a kept scan
 * section get it again here, from the servers signed in now, matched on the item's address.
 * An item whose address no current server has gets none, as it had none to play with.
 */
object ServerTokens {
    fun fill(items: List<MediaItem>, tokenByUrl: Map<String, String>): List<MediaItem> =
        items.map { it.copy(serverToken = it.serverUrl?.let(tokenByUrl::get)) }
}
