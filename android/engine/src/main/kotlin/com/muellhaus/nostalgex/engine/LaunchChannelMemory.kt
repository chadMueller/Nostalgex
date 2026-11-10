package com.muellhaus.nostalgex.engine

import kotlinx.serialization.Serializable

/**
 * OPEN ON LAST CHANNEL (I-017), the Apple TV's LaunchChannelMemory: start on the channel the
 * viewer last tuned instead of the first one in the guide. Off unless switched on; with it off a
 * launch opens exactly where it always did.
 *
 * What is saved is the channel's id and its name. A collection or franchise channel can be
 * renumbered when the lineup is rebuilt, so an id alone could tune a different channel from the
 * one the viewer left. A saved channel that is gone, or whose name no longer matches, opens the
 * first channel, as before.
 */
object LaunchChannelMemory {
    /** The Settings switch, under the Apple TV's key. */
    const val ENABLED_KEY = "nostalgex_open_on_last_channel"

    /**
     * On by default on every surface since 2026-11-09 (#225, I-017): a TV that never chose opens
     * on the channel it was last watching. The switch stays in Settings.
     */
    const val ENABLED_BY_DEFAULT = true

    /**
     * The switch as stored (`null` when the viewer never chose), as the web's isOn(stored): the
     * default only when nothing is stored, so a TV that switched it off stays off.
     */
    fun isOn(stored: Boolean?): Boolean = stored ?: ENABLED_BY_DEFAULT

    /** The channel the viewer last tuned, as JSON [Saved], under the Apple TV's key. */
    const val SAVED_KEY = "nostalgex_last_watched_channel"

    @Serializable
    data class Saved(val id: Int, val name: String)

    /** The saved channel when the switch is on and a channel with the same id and name is in `channels`, else null. */
    fun <T> channelToOpen(channels: List<T>, id: (T) -> Int, name: (T) -> String, enabled: Boolean, saved: Saved?): T? {
        if (!enabled || saved == null) return null
        return channels.firstOrNull { id(it) == saved.id && name(it) == saved.name }
    }

    /**
     * The channel a launch tunes first (channelToOpenFirst): the remembered one when it applies,
     * otherwise the first. Demo mode always opens on the first.
     */
    fun <T> channelToOpenFirst(channels: List<T>, id: (T) -> Int, name: (T) -> String, enabled: Boolean, saved: Saved?, demo: Boolean): T? =
        (if (demo) null else channelToOpen(channels, id, name, enabled, saved)) ?: channels.firstOrNull()
}
