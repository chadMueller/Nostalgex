package com.muellhaus.nostalgex

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.muellhaus.nostalgex.engine.SyncedPreferences

/**
 * Preferences that follow the viewer to a new TV through Auto Backup, and nothing else (the Apple TV's PreferenceSync,
 * with Auto Backup in place of iCloud). The main preferences file also holds the Plex token, the servers' addresses and
 * the media-browser sign-in, so it is never backed up: the backup rules include one file only, [SyncedPreferences.MIRROR_FILE],
 * and this class is the only thing that writes to it, copying the 13 settings in [SyncedPreferences.keys].
 *
 * [mirror] runs when the app stops, so the file is current whenever Android decides to back up. [restoreIfFresh] runs
 * first thing on a launch: on a TV that has just been restored from a backup the mirror file is there and the main
 * file is not, and the settings are copied back; on any other launch it does nothing.
 */
object SettingsBackup {
    private const val TAG = "Nostalgex"

    /** The per-TV switch, in the main preferences and not among the synced keys. */
    const val ENABLED_KEY = "nostalgex_settings_backup_enabled"

    private fun mainPrefs(context: Context) = context.getSharedPreferences("nostalgex", Context.MODE_PRIVATE)
    private fun mirrorPrefs(context: Context) = context.getSharedPreferences(SyncedPreferences.MIRROR_FILE, Context.MODE_PRIVATE)

    /** Writes the mirror when the switch is on, and empties it when it is off, so nothing is held for a backup unless the viewer asked. */
    fun mirror(context: Context) {
        val main = mainPrefs(context)
        val picked = if (main.getBoolean(ENABLED_KEY, false)) SyncedPreferences.pick(main.all) else emptyMap()
        write(mirrorPrefs(context), picked)
    }

    /** True when settings were brought back from a restored backup. */
    fun restoreIfFresh(context: Context): Boolean {
        val main = mainPrefs(context)
        // Fresh: nothing of this install's own, not even the client id every launch writes.
        if (main.all.isNotEmpty()) return false
        val backed = SyncedPreferences.pick(mirrorPrefs(context).all)
        if (backed.isEmpty()) return false
        write(main, backed, clearOthers = false)
        // A mirror existed, so the switch was on where it was written: it is on here too.
        main.edit().putBoolean(ENABLED_KEY, true).apply()
        Log.i(TAG, "BACKUP restored ${backed.size} settings from the backup")
        return true
    }

    @Suppress("UNCHECKED_CAST")
    private fun write(into: SharedPreferences, values: Map<String, Any>, clearOthers: Boolean = true) {
        val edit = into.edit()
        if (clearOthers) for (k in SyncedPreferences.keys) if (k.name !in values) edit.remove(k.name)
        for ((name, v) in values) when (v) {
            is Boolean -> edit.putBoolean(name, v)
            is String -> edit.putString(name, v)
            is Set<*> -> edit.putStringSet(name, v as Set<String>)
        }
        edit.apply()
    }
}
