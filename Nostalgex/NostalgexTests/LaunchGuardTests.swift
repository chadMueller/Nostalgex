import XCTest
@testable import Nostalgex

/// Discord #support 2026-10-22: a very large Emby library took the app down while loading,
/// and deleting and reinstalling the app came straight back into the same load, because
/// tvOS keeps keychain items after an app is deleted.
final class LaunchGuardTests: XCTestCase {
    private final class MemoryStore: CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    private var defaults: UserDefaults!
    private let suite = "LaunchGuardTests"

    override func setUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func signedInStore() -> MemoryStore {
        let store = MemoryStore()
        store.save(key: "plex_server_url", value: "http://192.168.1.10:8096")
        store.save(key: "plex_token", value: "t")
        store.save(key: AppState.backendKindKey, value: "emby")
        store.save(key: AppState.jellyfinUserIdKey, value: "u")
        store.save(key: AppState.serversKey, value: "[]")
        return store
    }

    // MARK: Reinstall

    func testFreshInstallClearsTheSignInADeletedInstallLeft() {
        let store = signedInStore()
        let cleared = LaunchGuard.clearCredentialsLeftByDeletedInstall(store: store, defaults: defaults, installStampExists: false)
        XCTAssertTrue(cleared)
        XCTAssertTrue(store.values.isEmpty, "every credential key goes, so nothing half-signed-in is left")
    }

    func testAnUpdateKeepsTheSignIn() {
        defaults.set(41, forKey: "nostalgex_launch_count")
        let store = signedInStore()
        XCTAssertFalse(LaunchGuard.clearCredentialsLeftByDeletedInstall(store: store, defaults: defaults, installStampExists: true))
        XCTAssertEqual(store.values.count, 5)
    }

    func testAnyOneEarlierLaunchKeyMeansAnExistingInstall() {
        for key in LaunchGuard.existingInstallKeys {
            UserDefaults().removePersistentDomain(forName: suite)
            defaults.set(true, forKey: key)
            let store = signedInStore()
            XCTAssertFalse(LaunchGuard.clearCredentialsLeftByDeletedInstall(store: store, defaults: defaults, installStampExists: false), key)
            XCTAssertEqual(store.values.count, 5, key)
        }
    }

    func testLostUserDefaultsAloneDoNotSignAnyoneOut() {
        // InstallDiagnostics watches for UserDefaults going missing on a device that kept
        // its files. The stamp file is the second witness; with it present, keep the sign-in.
        let store = signedInStore()
        XCTAssertFalse(LaunchGuard.clearCredentialsLeftByDeletedInstall(store: store, defaults: defaults, installStampExists: true))
        XCTAssertEqual(store.values.count, 5)
    }

    func testFreshInstallWithNothingInTheKeychainDoesNothing() {
        XCTAssertFalse(LaunchGuard.clearCredentialsLeftByDeletedInstall(store: MemoryStore(), defaults: defaults, installStampExists: false))
    }

    // MARK: Unfinished loads

    func testTwoLoadsThatNeverFinishedAskBeforeATheThird() {
        LaunchGuard.loadStarted(defaults: defaults)        // app killed mid-load
        LaunchGuard.recordLaunch(defaults: defaults)
        XCTAssertFalse(LaunchGuard.shouldAskBeforeLoading(defaults: defaults))
        LaunchGuard.loadStarted(defaults: defaults)        // killed again
        LaunchGuard.recordLaunch(defaults: defaults)
        XCTAssertTrue(LaunchGuard.shouldAskBeforeLoading(defaults: defaults))
    }

    func testALoadThatEndsResetsTheCount() {
        LaunchGuard.loadStarted(defaults: defaults)
        LaunchGuard.recordLaunch(defaults: defaults)
        LaunchGuard.loadStarted(defaults: defaults)
        LaunchGuard.loadEnded(defaults: defaults)          // this one finished
        LaunchGuard.recordLaunch(defaults: defaults)
        XCTAssertFalse(LaunchGuard.shouldAskBeforeLoading(defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: LaunchGuard.unfinishedLoadsKey), 0)
    }

    func testANormalRelaunchCountsNothing() {
        LaunchGuard.recordLaunch(defaults: defaults)
        LaunchGuard.recordLaunch(defaults: defaults)
        XCTAssertFalse(LaunchGuard.shouldAskBeforeLoading(defaults: defaults))
    }

    func testARestoreThatWorksDoesNotHideAKillingRefresh() {
        // Launch 1: snapshot restores, then the refresh kills the app.
        LaunchGuard.loadStarted(defaults: defaults)
        LaunchGuard.loadEnded(resetCount: false, defaults: defaults)
        LaunchGuard.loadStarted(defaults: defaults)
        LaunchGuard.recordLaunch(defaults: defaults)
        // Launch 2: same again.
        LaunchGuard.loadStarted(defaults: defaults)
        LaunchGuard.loadEnded(resetCount: false, defaults: defaults)
        LaunchGuard.loadStarted(defaults: defaults)
        LaunchGuard.recordLaunch(defaults: defaults)
        XCTAssertTrue(LaunchGuard.shouldAskBeforeLoading(defaults: defaults))
    }

    func testTryAgainGivesTheFullAllowanceBack() {
        defaults.set(2, forKey: LaunchGuard.unfinishedLoadsKey)
        LaunchGuard.resetUnfinishedLoads(defaults: defaults)
        XCTAssertFalse(LaunchGuard.shouldAskBeforeLoading(defaults: defaults))
    }
}

/// START OVER, from the loading screen or the unfinished-loads screen.
@MainActor
final class StartOverTests: XCTestCase {
    private final class MemoryStore: CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LaunchGuard.loadInFlightKey)
        UserDefaults.standard.removeObject(forKey: LaunchGuard.unfinishedLoadsKey)
    }

    func testStartOverMidLoadSignsOutAndStopsTheLoad() {
        let store = MemoryStore()
        let state = AppState(credentialStore: store)
        state.backendKind = .emby
        state.serverURL = "http://192.168.1.10:8096"
        state.token = "t"
        state.saveCredentials()
        state.isLoading = true
        LaunchGuard.loadStarted()
        let generation = state.librarySessionGeneration

        state.startOver()

        XCTAssertFalse(state.hasCredentials)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.loadCancelRequested, "the stall watch cancels the server fetch on its next poll")
        XCTAssertNotEqual(state.librarySessionGeneration, generation, "anything still in flight is discarded")
        XCTAssertNil(store.load(key: "plex_token"))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: LaunchGuard.loadInFlightKey))
    }

    func testStartOverFromTheUnfinishedLoadsScreen() {
        let state = AppState(credentialStore: MemoryStore())
        state.serverURL = "http://192.168.1.10:8096"
        state.token = "t"
        state.isHoldingAfterUnfinishedLoads = true
        UserDefaults.standard.set(2, forKey: LaunchGuard.unfinishedLoadsKey)

        state.startOver()

        XCTAssertFalse(state.isHoldingAfterUnfinishedLoads)
        XCTAssertFalse(state.hasCredentials)
        XCTAssertFalse(LaunchGuard.shouldAskBeforeLoading())
    }
}
