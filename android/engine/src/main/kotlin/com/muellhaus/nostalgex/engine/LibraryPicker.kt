package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Which servers and libraries Nostalgex lists, starts on and reads: one rule set for every platform (N-016 option A, Chad's go 2026-11-15).
 * The contract is the web tuner's scripts/nostalgex-library-picker.js (rules 1 to 9 in its header), pinned by
 * scripts/library-picker-golden.json, which LibraryPickerGoldenTest reads. The Apple TV, the Roku and this app match it.
 *
 * A library is on or off. Two saved lists make that: `off` (ids the viewer switched OFF; every library but a hidden one reads it) and
 * `includedHidden` (ids of hidden Jellyfin libraries the viewer switched ON; a hidden library reads only this). Everything starts on
 * except a hidden Jellyfin library. Ids are [LibrarySection.id], `<serverId>::<key>`.
 */
object LibraryPicker {
    /** Rule 1: a Plex library type the app lists and reads. */
    val PLEX_TYPES = setOf("movie", "show")

    fun isPlexVideoType(type: String?) = type?.lowercase() in PLEX_TYPES

    /** The two saved lists. */
    data class State(val off: Set<String> = emptySet(), val includedHidden: Set<String> = emptySet())

    /** Rule 1. One Plex server's /library/sections answer as listed rows; null (a server that did not answer) lists nothing. */
    fun plexListed(serverId: String, serverName: String, sections: List<JsonObject>?): List<LibrarySection> =
        (sections ?: emptyList()).filter { isPlexVideoType(it.str("type")) }.map {
            LibrarySection(serverId, serverName, it.str("key") ?: "", it.str("title")?.ifEmpty { null } ?: "Library", (it.str("type") ?: "").lowercase())
        }

    /**
     * Rules 2 and 5. A Jellyfin or Emby user's libraries: `shown` is the plain list, `all` the includeHidden list (null: not asked, or the
     * ask failed). A view only in `all` is hidden; one in `shown` and not in `all` is kept (the union, in the order of `all` then the
     * rest of `shown`); a view that holds no videos is never listed. A plain ask that failed is the caller's to handle (pass the one
     * answer that came as `shown` and null as `all`: nothing is then marked hidden).
     */
    fun mediaBrowserListed(serverId: String, serverName: String, shown: List<JsonObject>, all: List<JsonObject>?): List<LibrarySection> {
        val (first, second) = shown to all
        val shownIds = first.mapNotNull { it.str("Id") }.toSet()
        val secondIds = second?.mapNotNull { it.str("Id") }?.toSet() ?: emptySet()
        val union = if (second != null) second + first.filter { it.str("Id") !in secondIds } else first
        return union.filter { MediaBrowserLibrary.sectionType(it.str("CollectionType")) != "other" }.map { view ->
            LibrarySection(serverId, serverName, view.str("Id") ?: "", view.str("Name")?.ifEmpty { null } ?: "Library",
                MediaBrowserLibrary.sectionType(view.str("CollectionType")), hidden = second != null && view.str("Id") !in shownIds)
        }
    }

    /** Rules 3 and 5: whether a library is on before the viewer has chosen anything. */
    fun startsOn(section: LibrarySection) = !section.hidden

    /** Whether a library is on under a saved state. A hidden one follows the included list only; every other follows the off list. */
    fun isOn(section: LibrarySection, state: State) =
        if (section.hidden) section.id in state.includedHidden else section.id !in state.off

    /** The ids a scan reads, in listed order. */
    fun readIds(sections: List<LibrarySection>, state: State) = sections.filter { isOn(it, state) }.map { it.id }

    /** Rule 7: the state after the viewer switches one library: only its id moves, every other saved id stays, answered or not. */
    fun toggled(section: LibrarySection, state: State): State = when {
        isOn(section, state) -> if (section.hidden) state.copy(includedHidden = state.includedHidden - section.id) else state.copy(off = state.off + section.id)
        else -> if (section.hidden) state.copy(includedHidden = state.includedHidden + section.id) else state.copy(off = state.off - section.id)
    }

    /** The state that has exactly [on] of [sections] switched on (the picker's CONTINUE): others of the saved state stay. */
    fun withOn(sections: List<LibrarySection>, on: Set<String>, state: State = State()): State =
        sections.fold(state) { s, sec -> if (isOn(sec, s) == (sec.id in on)) s else toggled(sec, s) }

    /** Rule 8: whether the picker is offered at a sign-in, for the libraries listed across the chosen servers. */
    fun offersPicker(sections: List<LibrarySection>) = sections.size > 1 || sections.any { it.hidden }

    /** Rule 9: the saved state after a sign-in, whatever it was before. */
    fun afterSignIn() = State()

    /** Rule 4: the ids of the servers that start on: the viewer's own, or all of them when none is. */
    fun defaultServerIds(servers: List<Pair<String, Boolean>>): List<String> {
        val own = servers.filter { it.second }
        return (own.ifEmpty { servers }).map { it.first }
    }

    /**
     * The upgrade from the one switch (INCLUDE LIBRARIES HIDDEN ON JELLYFIN) to a switch per library. With the switch on, each hidden library not
     * in `off` goes into the included list, once; `done` says the old switch may be cleared. With the hidden libraries not yet known
     * (`hiddenKnown` false: the includeHidden list was not answered) nothing changes and the switch is kept for the next time.
     */
    fun carryOverHiddenSwitch(switchOn: Boolean, hiddenKnown: Boolean, sections: List<LibrarySection>, state: State): Pair<State, Boolean> {
        if (!switchOn) return state to true
        if (!hiddenKnown) return state to false
        return state.copy(includedHidden = state.includedHidden + sections.filter { it.hidden && it.id !in state.off }.map { it.id }) to true
    }

    private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
}
