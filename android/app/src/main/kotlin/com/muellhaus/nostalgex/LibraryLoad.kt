package com.muellhaus.nostalgex

import android.content.Context
import android.util.Log

/**
 * The loading screen's steps (LibraryLoadPhase.swift). The Apple TV also has Collections,
 * Metadata and Music between Library and Channels; this app has no collections, TMDB, OMDb or
 * MusicBrainz step to show, so its rail is these four.
 */
enum class LoadPhase(val title: String, val hint: String) {
    PREPARING("Lineup", "Loading channel rules and bundles"),
    SCANNING("Library", "Reading movies, shows, and music from your server"),
    BUILDING("Channels", "Matching your library to each channel"),
    FINISHING("Ready", "Almost there");

    /** The headline: the phase's own words, or what it is doing right now (LibraryLoadPhase.headline). */
    fun headline(detail: String = ""): String = when {
        this == FINISHING -> "TUNING IN"
        detail.isNotEmpty() -> detail
        this == PREPARING -> "PREPARING LINEUP"
        this == SCANNING -> "SCANNING LIBRARY"
        else -> "BUILDING CHANNELS"
    }.uppercase()
}

/**
 * A load that ends with the app being killed (out of memory, or closed from the recents list)
 * never reaches its own cleanup. A marker set as a load starts and cleared as it ends tells the
 * next launch the last one died mid-load; after two in a row the app asks first (LaunchGuard.swift).
 * The Apple TV's reinstall half isn't needed: Android deletes the app's data with the app, and
 * backup is off.
 */
class LaunchGuard(context: Context) {
    private val prefs = context.getSharedPreferences("nostalgex", Context.MODE_PRIVATE)

    /** Call once per launch. A marker still set means the previous process died inside a load. */
    fun recordLaunch() {
        if (!prefs.getBoolean(IN_FLIGHT, false)) return
        val count = prefs.getInt(UNFINISHED, 0) + 1
        prefs.edit().remove(IN_FLIGHT).putInt(UNFINISHED, count).commit()
        Log.i("Nostalgex", "LOAD the previous launch ended inside a library load ($count in a row)")
    }

    /** Written at once: the process may not live to write it later. */
    fun loadStarted() {
        prefs.edit().putBoolean(IN_FLIGHT, true).commit()
    }

    /**
     * Any end the process lived to see. `resetCount = false` only clears the marker, for a step
     * that proves nothing about whether the full load can finish (reading the saved library).
     */
    fun loadEnded(resetCount: Boolean = true) {
        prefs.edit().remove(IN_FLIGHT).apply { if (resetCount) remove(UNFINISHED) }.apply()
    }

    fun shouldAskBeforeLoading() = prefs.getInt(UNFINISHED, 0) >= LIMIT

    /** TRY AGAIN: the next load gets the full allowance again. */
    fun resetUnfinishedLoads() {
        prefs.edit().remove(UNFINISHED).apply()
    }

    companion object {
        /** The Apple TV's keys. */
        private const val IN_FLIGHT = "nostalgex_library_load_in_flight"
        private const val UNFINISHED = "nostalgex_unfinished_library_loads"
        /** Unfinished loads in a row before the app asks instead of loading. */
        private const val LIMIT = 2
    }
}
