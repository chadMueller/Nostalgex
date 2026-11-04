import XCTest
@testable import Nostalgex

/// The TV stays awake while video plays and while the viewer waits on the loading screen
/// (first load, RESCAN), and goes back to its own sleep timer on the guide, the error screen
/// and sign-out (N-033). One answer feeds `UIApplication.isIdleTimerDisabled`, so the two
/// holders never fight over it.
final class ScreenAwakePolicyTests: XCTestCase {

    func testPlaybackHoldsTheTVAwake() {
        XCTAssertTrue(ScreenAwakePolicy.keepsAwake(playbackState: .playing, isLoading: false, hasCredentials: true))
        XCTAssertTrue(ScreenAwakePolicy.keepsAwake(playbackState: .playing, isLoading: false, hasCredentials: false),
                      "playback is playback whatever the sign-in state says")
    }

    func testTheLoadingScreenHoldsTheTVAwake() {
        XCTAssertTrue(ScreenAwakePolicy.keepsAwake(playbackState: .idle, isLoading: true, hasCredentials: true))
        XCTAssertTrue(ScreenAwakePolicy.keepsAwake(playbackState: .loading, isLoading: true, hasCredentials: true))
    }

    func testIdleOnTheGuideLetsTheTVSleep() {
        XCTAssertFalse(ScreenAwakePolicy.keepsAwake(playbackState: .idle, isLoading: false, hasCredentials: true))
        XCTAssertFalse(ScreenAwakePolicy.keepsAwake(playbackState: .loading, isLoading: false, hasCredentials: true),
                       "a tune that is still buffering is not playback")
        XCTAssertFalse(ScreenAwakePolicy.keepsAwake(playbackState: .watershedHold, isLoading: false, hasCredentials: true))
        XCTAssertFalse(ScreenAwakePolicy.keepsAwake(playbackState: .error(.serverUnreachable(server: "Vault")), isLoading: false, hasCredentials: true))
    }

    func testALoadWithNoSignInIsNotTheLoadingScreen() {
        // RootView shows the connect screen, not the loading screen, without credentials.
        XCTAssertFalse(ScreenAwakePolicy.keepsAwake(playbackState: .idle, isLoading: true, hasCredentials: false))
    }

    /// Both holders, in every order: the switch stays on until the last one lets go.
    func testTheTwoHoldersNeverReleaseEachOther() {
        XCTAssertTrue(ScreenAwakePolicy.keepsAwake(playbackState: .playing, isLoading: true, hasCredentials: true))
        // Playback ends under a RESCAN: the load still holds.
        XCTAssertTrue(ScreenAwakePolicy.keepsAwake(playbackState: .idle, isLoading: true, hasCredentials: true))
        // The load ends while video plays: playback still holds.
        XCTAssertTrue(ScreenAwakePolicy.keepsAwake(playbackState: .playing, isLoading: false, hasCredentials: true))
    }
}

/// The same through `AppState.keepsScreenAwake`, the property `RootView` watches.
@MainActor
final class ScreenAwakeAppStateTests: XCTestCase {

    private final class MemoryCredentials: CredentialStoring, @unchecked Sendable {
        private var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    private var scope: HarnessScope?

    override func setUp() {
        super.setUp()
        // disconnect() clears today's schedules; under HarnessScope that is the harness's
        // own store, never a TV's.
        scope = HarnessScope.begin("screen-awake")
    }

    override func tearDown() {
        scope?.end()
        scope = nil
        super.tearDown()
    }

    private func signedInState() -> AppState {
        let state = AppState(credentialStore: MemoryCredentials())
        state.backendKind = .plex
        state.token = "t"
        XCTAssertTrue(state.hasCredentials)
        return state
    }

    func testAFirstLoadHoldsUntilTheGuideIsUp() {
        let state = signedInState()
        XCTAssertFalse(state.keepsScreenAwake, "nothing yet")
        state.isLoading = true
        XCTAssertTrue(state.keepsScreenAwake, "the loading screen is up")
        state.isLoading = false
        XCTAssertFalse(state.keepsScreenAwake, "the guide is up")
    }

    func testABackgroundRefreshBehindTheGuideDoesNotHold() {
        let state = signedInState()
        state.isBackgroundRefreshing = true
        XCTAssertFalse(state.keepsScreenAwake)
    }

    func testTheErrorScreenReleases() {
        let state = signedInState()
        state.isLoading = true
        XCTAssertTrue(state.keepsScreenAwake)
        // What every failed load does: the message, then the screen comes down.
        state.errorMessage = "Your server stopped sending data"
        state.isLoading = false
        XCTAssertFalse(state.keepsScreenAwake)
    }

    func testSignOutDuringALoadReleases() {
        let state = signedInState()
        state.isLoading = true
        XCTAssertTrue(state.keepsScreenAwake)
        state.disconnect()
        XCTAssertFalse(state.hasCredentials)
        XCTAssertFalse(state.keepsScreenAwake, "the connect screen is up, not the loading screen")
    }

    func testPlaybackAndTheLoadingScreenShareTheHold() {
        let state = signedInState()
        state.playbackState = .playing
        XCTAssertTrue(state.keepsScreenAwake, "playing")
        state.isLoading = true
        XCTAssertTrue(state.keepsScreenAwake, "RESCAN pressed while playing")
        state.playbackState = .idle
        XCTAssertTrue(state.keepsScreenAwake, "playback stopped, the load still holds")
        state.isLoading = false
        XCTAssertFalse(state.keepsScreenAwake, "the last holder let go")
    }
}
