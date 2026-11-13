package com.muellhaus.nostalgex.engine

/**
 * What the FRANCHISES page shows for a franchise collection while the FRANCHISES switch is off:
 * the Apple TV's `FranchisesPageGate` (Views/Settings/SettingsChannelsView.swift, ef8d73d4,
 * N-032). The switch gates every franchise channel, the server's franchise collections
 * included, so while it is off no collection airs: the page keeps them listed, greyed out and
 * out of focus's way, and none reads ON. Each collection's own switch is kept as it was, so
 * turning FRANCHISES back on brings back exactly what was set.
 */
object FranchisesPageGate {
    /** The line under the switch while it is off and collections are listed. */
    const val OFF_NOTE = "None of these are on the air while FRANCHISES is off."

    /** The row reads ON only when the collection is set on and actually airs. */
    fun collectionReadsOn(collectionEnabled: Boolean, franchisesOn: Boolean): Boolean = franchisesOn && collectionEnabled

    /** A collection's switch can be reached and pressed only while FRANCHISES is on. */
    fun collectionSelectable(franchisesOn: Boolean): Boolean = franchisesOn

    /** The count beside FRANCHISES on the Channels list: what is on and on the air. */
    fun onCount(franchisesOn: Boolean, franchiseRowsOn: Int, collectionsOn: Int): Int =
        if (!franchisesOn) 0 else franchiseRowsOn + collectionsOn
}
