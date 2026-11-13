package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The FRANCHISES page's gate, as the Apple TV's FranchisesPageGate. */
class FranchisesPageGateTest {
    @Test fun aCollectionNeverReadsOnWhileFranchisesIsOff() {
        assertFalse(FranchisesPageGate.collectionReadsOn(collectionEnabled = true, franchisesOn = false))
        assertFalse(FranchisesPageGate.collectionReadsOn(collectionEnabled = false, franchisesOn = false))
    }

    @Test fun aCollectionReadsOnlyItsOwnSwitchWhileFranchisesIsOn() {
        assertTrue(FranchisesPageGate.collectionReadsOn(collectionEnabled = true, franchisesOn = true))
        assertFalse(FranchisesPageGate.collectionReadsOn(collectionEnabled = false, franchisesOn = true))
    }

    @Test fun aCollectionCanBeSwitchedOnlyWhileFranchisesIsOn() {
        assertTrue(FranchisesPageGate.collectionSelectable(franchisesOn = true))
        assertFalse(FranchisesPageGate.collectionSelectable(franchisesOn = false))
    }

    @Test fun theChannelsListCountIsZeroWhileOffAndTheSumWhileOn() {
        assertEquals(0, FranchisesPageGate.onCount(franchisesOn = false, franchiseRowsOn = 3, collectionsOn = 2))
        assertEquals(5, FranchisesPageGate.onCount(franchisesOn = true, franchiseRowsOn = 3, collectionsOn = 2))
    }

    @Test fun theNoteIsPlainCopy() {
        assertEquals("None of these are on the air while FRANCHISES is off.", FranchisesPageGate.OFF_NOTE)
        assertFalse(FranchisesPageGate.OFF_NOTE.contains("—") || FranchisesPageGate.OFF_NOTE.contains("–"))
    }
}
