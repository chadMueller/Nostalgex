import XCTest
@testable import Nostalgex

/// A signed-in user must never be shown the connect screen while the Keychain read is
/// still in flight. Credentials load in a `.task`, which SwiftUI runs after the first
/// body evaluation, so `hasCredentials` is false for at least one frame on every launch.
/// On an Apple TV HD that frame lasted long enough to read and press, and the press
/// looked like it "went straight through" into the first channel.
@MainActor
final class LaunchGateTests: XCTestCase {
    private final class MemStore: Nostalgex.CredentialStoring {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    /// Mirrors RootView's branch order. Keep in sync with Plex90App.swift.
    private func rootShowsConnectScreen(_ s: AppState) -> Bool {
        if s.needsServerSelection { return false }
        if s.needsLibrarySelection { return false }
        if !s.didAttemptCredentialHydration { return false }
        return !s.hasCredentials
    }

    private func signedInState() -> AppState {
        let store = MemStore()
        store.values["plex_server_url"] = "https://my-plex.example.com"
        store.values["plex_token"] = "a-real-saved-token"
        return AppState(credentialStore: store)
    }

    func testConnectScreenIsNotShownBeforeTheKeychainHasBeenRead() {
        let state = signedInState()
        XCTAssertFalse(state.didAttemptCredentialHydration, "fresh launch has not read the Keychain yet")
        XCTAssertFalse(state.hasCredentials, "credentials are not in memory until hydration runs")
        XCTAssertFalse(
            rootShowsConnectScreen(state),
            "a signed-in user was shown CONNECT TO PLEX while the Keychain read was still in flight"
        )
    }

    func testConnectScreenIsShownOnceHydrationFindsNothing() async {
        let state = AppState(credentialStore: MemStore())   // nothing saved
        await state.hydrateCredentialsWithRetry()
        XCTAssertTrue(state.didAttemptCredentialHydration)
        XCTAssertTrue(rootShowsConnectScreen(state), "a genuinely signed-out user must reach the connect screen")
    }

    func testHydrationMarksItselfDoneEvenWhenItFindsNothing() async {
        let state = AppState(credentialStore: MemStore())
        await state.hydrateCredentialsWithRetry()
        XCTAssertTrue(state.didAttemptCredentialHydration, "the gate must open even when there is no sign-in, or the app hangs on LOADING")
    }

    func testSignedInUserGoesStraightToTheGuide() async {
        let state = signedInState()
        await state.hydrateCredentialsWithRetry()
        XCTAssertTrue(state.hasCredentials)
        XCTAssertFalse(rootShowsConnectScreen(state), "a signed-in user must never see the connect screen")
    }
}
