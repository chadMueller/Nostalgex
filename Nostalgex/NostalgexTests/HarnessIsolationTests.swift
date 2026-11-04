import XCTest
@testable import Nostalgex

/// A harness that drives the real app on a real Apple TV must not touch the app's real
/// stores: the TV is someone's, signed in, with a library snapshot, schedules, settings and
/// an iCloud-synced lineup (N-033). `HarnessIsolation` moves all of it under a harness root;
/// these prove it, byte for byte, with `RealStoreFingerprint` read from the real locations.
@MainActor
final class HarnessIsolationTests: XCTestCase {

    /// True only while isolation is on because this test switched it on.
    private var activatedHere = false

    /// A device run launched with `TEST_RUNNER_NOSTALGEX_HARNESS_ROOT` has isolation on for
    /// the whole process. These tests switch it off and wipe it, so if they ran there, every
    /// class after this one (`LibrarySnapshotStore.clear()`, `DailyManifestStore.clearAll()`)
    /// would hit the TV's real stores. Skip instead; `HarnessIsolationPreexistingTests` proves it.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(HarnessIsolation.isActive,
                      "isolation was already on at launch; these tests would switch it off")
    }

    /// Switches off only what this test switched on, the way `HarnessScope` does.
    override func tearDown() {
        if activatedHere, HarnessIsolation.isActive { HarnessIsolation.deactivate(wipe: true) }
        activatedHere = false
        super.tearDown()
    }

    /// While active, every store points into the harness root; afterwards, back to the real ones.
    func testActivationMovesEveryStoreAndDeactivationPutsThemBack() throws {
        let realRoot = try XCTUnwrap(LocalStore.rootDirectory)
        let key = "nostalgex_harness_isolation_probe"
        XCTAssertNil(UserDefaults.standard.object(forKey: key))

        let root = HarnessIsolation.activate(name: "unit")
        activatedHere = true
        XCTAssertTrue(try XCTUnwrap(LocalStore.rootDirectory).path.hasPrefix(root.path))
        XCTAssertTrue(try XCTUnwrap(TopShelfStore.containerURL).path.hasPrefix(root.path))
        AppDefaults.standard.set(true, forKey: key)
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "a harness setting never reaches the app's domain")
        XCTAssertTrue(KeychainService.save(key: key, value: "v"))
        XCTAssertEqual(KeychainService.load(key: key), "v")
        XCTAssertNil(UserDefaults.standard.object(forKey: "nostalgex_credential_mirror." + key))
        let state = AppState()
        XCTAssertFalse(state.preferenceSync === PreferenceSync.shared, "a harness AppState never takes over the shared sync")

        HarnessIsolation.deactivate(wipe: true)
        activatedHere = false
        XCTAssertEqual(LocalStore.rootDirectory, realRoot)
        XCTAssertNil(AppDefaults.standard.object(forKey: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "the harness root is wiped")
    }

    /// Control: the fingerprint sees a one-byte file in the real store, so equal means equal.
    func testTheFingerprintSeesAChangeInTheRealStore() throws {
        let realRoot = try XCTUnwrap(LocalStore.rootDirectory)
        let probe = realRoot.appendingPathComponent("fingerprint-control.tmp")
        let before = RealStoreFingerprint.capture()
        try Data([1]).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        let during = RealStoreFingerprint.capture()
        XCTAssertNotEqual(before, during)
        XCTAssertEqual(before.differences(from: during).app.count, 1)
        try FileManager.default.removeItem(at: probe)
        XCTAssertEqual(before, RealStoreFingerprint.capture())
    }
}

/// An isolation that was already on when `HarnessIsolationTests` came round (a device run
/// turns it on at launch) comes through that class's setUp and tearDown still on: same root,
/// same suite, its files and settings intact. On the simulator this switches isolation on
/// itself to stand in for the launch; on a device run it uses the one the launch made.
@MainActor
final class HarnessIsolationPreexistingTests: XCTestCase {

    func testAnIsolationAlreadyOnSurvivesHarnessIsolationTests() throws {
        let scope = HarnessScope.begin("preexisting")
        defer { scope.end() }
        let root = try XCTUnwrap(HarnessIsolation.root)
        let suite = try XCTUnwrap(HarnessIsolation.suiteName)
        let marker = root.appendingPathComponent("preexisting.marker")
        let key = "nostalgex_harness_preexisting_probe"
        try Data([7]).write(to: marker)
        AppDefaults.standard.set(true, forKey: key)
        defer {
            AppDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: marker)
        }

        let other = HarnessIsolationTests(selector: NSSelectorFromString("testActivationMovesEveryStoreAndDeactivationPutsThemBack"))
        XCTAssertThrowsError(try other.setUpWithError(), "the class skips while isolation is on") {
            XCTAssertTrue($0 is XCTSkip, "\($0)")
        }
        other.tearDown()

        XCTAssertTrue(HarnessIsolation.isActive, "still isolated")
        XCTAssertEqual(HarnessIsolation.root, root)
        XCTAssertEqual(HarnessIsolation.suiteName, suite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the harness root was not wiped")
        XCTAssertTrue(AppDefaults.standard.bool(forKey: key), "settings still go to the harness suite")
        XCTAssertTrue(try XCTUnwrap(LocalStore.rootDirectory).path.hasPrefix(root.path), "stores still point into the harness root")
    }
}
