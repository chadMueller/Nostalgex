package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #338: what keeps the library choice owed after a launch lists the libraries, and what a launch does first. The rules match the Apple TV's presentLibrarySelectionOrScan. */
class LibraryPickOwedTest {
    private fun section(key: String, hidden: Boolean = false) = LibrarySection("srv", "Server", key, "Library $key", "movie", hidden)

    @Test fun twoLibrariesKeepTheChoiceOwedUntilContinue() {
        val two = listOf(section("1"), section("2"))
        assertTrue(LibraryPicker.pickStillOwed(two, resuming = false))
        assertTrue(LibraryPicker.pickStillOwed(two, resuming = true))
    }

    @Test fun aHiddenLibraryAloneStillOwesTheChoice() {
        val hidden = listOf(section("1", hidden = true))
        assertTrue(LibraryPicker.pickStillOwed(hidden, resuming = false))
        assertTrue(LibraryPicker.pickStillOwed(hidden, resuming = true))
    }

    @Test fun oneLibraryHasNothingToChooseSoTheChoiceIsNotOwed() {
        val one = listOf(section("1"))
        assertFalse(LibraryPicker.pickStillOwed(one, resuming = false))
        assertFalse("a relaunch that read one library scans it", LibraryPicker.pickStillOwed(one, resuming = true))
    }

    @Test fun noLibraryReadableAtSignInClearsItButOnARelaunchItIsKept() {
        // At sign-in the scan reports its own error, as before. On a relaunch the server may just be asleep: the viewer still owes the choice.
        assertFalse(LibraryPicker.pickStillOwed(emptyList(), resuming = false))
        assertTrue(LibraryPicker.pickStillOwed(emptyList(), resuming = true))
    }

    @Test fun aLaunchDoesTheOwedChoiceBeforeAnythingElse() {
        assertEquals(LibraryPicker.LaunchStep.SIGN_IN, LibraryPicker.launchStep(signedIn = false, pickOwed = false, askBeforeLoading = false))
        assertEquals(LibraryPicker.LaunchStep.SIGN_IN, LibraryPicker.launchStep(signedIn = false, pickOwed = true, askBeforeLoading = true))
        assertEquals(LibraryPicker.LaunchStep.RESUME_PICK, LibraryPicker.launchStep(signedIn = true, pickOwed = true, askBeforeLoading = false))
        assertEquals(LibraryPicker.LaunchStep.RESUME_PICK, LibraryPicker.launchStep(signedIn = true, pickOwed = true, askBeforeLoading = true))
        assertEquals(LibraryPicker.LaunchStep.ASK_BEFORE_LOADING, LibraryPicker.launchStep(signedIn = true, pickOwed = false, askBeforeLoading = true))
        assertEquals(LibraryPicker.LaunchStep.LOAD, LibraryPicker.launchStep(signedIn = true, pickOwed = false, askBeforeLoading = false))
    }
}
