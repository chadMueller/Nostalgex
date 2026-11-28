package com.muellhaus.nostalgex

import com.muellhaus.nostalgex.LocalPlexSignInTest.MemoryPrefs
import com.muellhaus.nostalgex.engine.LibraryPicker
import com.muellhaus.nostalgex.engine.LibraryPicker.LaunchStep
import com.muellhaus.nostalgex.plex.PlexServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #338 (the Android twin of #337, the Apple TV's PickerOwedTests): closing the app on CHOOSE YOUR LIBRARIES must not skip the picker on the
 * next launch. The real Prefs over an in-memory store; a relaunch is a new Prefs over the same store, and the launch decision is the one
 * AppModel.start() takes.
 */
class LibraryPickOwedTest {
    private val den = PlexServer("Den", "machine-a", "http://192.168.1.10:32400", token = "")

    /** AppModel.start()'s decision, from what a launch can read of the saved state. */
    private fun launchStep(prefs: Prefs, hasMediaBrowser: Boolean = false, askBeforeLoading: Boolean = false): LaunchStep {
        val signedIn = hasMediaBrowser || prefs.plexSignedIn
        return LibraryPicker.launchStep(signedIn, prefs.libraryPickOwed, signedIn && askBeforeLoading)
    }

    @Test fun nothingIsOwedBeforeAnySignIn() {
        val prefs = Prefs(MemoryPrefs())
        assertFalse(prefs.libraryPickOwed)
        assertEquals(LaunchStep.SIGN_IN, launchStep(prefs))
    }

    @Test fun closingTheAppOnTheLibraryPickerBringsThePickerBackInsteadOfAScan() {
        val store = MemoryPrefs()
        // The sign-in is saved, then the step that shows CHOOSE YOUR LIBRARIES starts, as AppModel.chooseLibrariesOrScan does.
        Prefs(store).apply { saveAccountSignIn("account-token", listOf(den.copy(token = "t"))); libraryPickOwed = true }
        // The app is closed there. The next launch is a new Prefs over the same file.
        val relaunched = Prefs(store)
        assertTrue("still signed in", relaunched.plexSignedIn)
        assertTrue("the choice is still owed", relaunched.libraryPickOwed)
        assertEquals(LaunchStep.RESUME_PICK, launchStep(relaunched))
    }

    @Test fun theSameHoldsForAJellyfinOrEmbySignIn() {
        val store = MemoryPrefs()
        Prefs(store).libraryPickOwed = true
        assertEquals(LaunchStep.RESUME_PICK, launchStep(Prefs(store), hasMediaBrowser = true))
    }

    @Test fun continueClearsItAndTheNextLaunchLoadsTheLibrary() {
        val store = MemoryPrefs()
        Prefs(store).apply { saveLocalPlexSignIn(den); libraryPickOwed = true }
        Prefs(store).libraryPickOwed = false // CONTINUE (confirmLibraries)
        assertEquals(LaunchStep.LOAD, launchStep(Prefs(store)))
    }

    @Test fun signOutClearsItSoTheNextSignInStartsClean() {
        val store = MemoryPrefs()
        val prefs = Prefs(store)
        prefs.saveAccountSignIn("account-token", listOf(den.copy(token = "t")))
        prefs.libraryPickOwed = true
        prefs.signOut()
        assertFalse(prefs.libraryPickOwed)
        assertEquals(LaunchStep.SIGN_IN, launchStep(Prefs(store)))
    }

    @Test fun aSignInThatIsSavedAfterSignOutCanOweTheChoiceAgain() {
        // finishSignIn: prefs.signOut(), then the new sign-in, then the step sets the flag.
        val prefs = Prefs(MemoryPrefs())
        prefs.libraryPickOwed = true
        prefs.signOut()
        prefs.saveLocalPlexSignIn(den)
        assertFalse("saving a sign-in does not itself owe the choice", prefs.libraryPickOwed)
        prefs.libraryPickOwed = true
        assertEquals(LaunchStep.RESUME_PICK, launchStep(prefs))
    }

    @Test fun theOwedChoiceComesBeforeTheUnfinishedLoadsQuestion() {
        val prefs = Prefs(MemoryPrefs()).apply { saveLocalPlexSignIn(den); libraryPickOwed = true }
        assertEquals(LaunchStep.RESUME_PICK, launchStep(prefs, askBeforeLoading = true))
        prefs.libraryPickOwed = false
        assertEquals(LaunchStep.ASK_BEFORE_LOADING, launchStep(prefs, askBeforeLoading = true))
    }
}
