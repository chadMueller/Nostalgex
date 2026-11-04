import XCTest
@testable import Nostalgex

/// A harness that drives the real app on a real Apple TV must not touch the app's real
/// stores: the TV is someone's, signed in, with a library snapshot, schedules, settings and
/// an iCloud-synced lineup (N-033). `HarnessIsolation` moves all of it under a harness root;
/// these prove it, byte for byte, with `RealStoreFingerprint` read from the real locations.
@MainActor
final class HarnessIsolationTests: XCTestCase {

    override func tearDown() {
        if HarnessIsolation.isActive { HarnessIsolation.deactivate(wipe: true) }
        super.tearDown()
    }

    /// While active, every store points into the harness root; afterwards, back to the real ones.
    func testActivationMovesEveryStoreAndDeactivationPutsThemBack() throws {
        let realRoot = try XCTUnwrap(LocalStore.rootDirectory)
        let key = "nostalgex_harness_isolation_probe"
        XCTAssertNil(UserDefaults.standard.object(forKey: key))

        let root = HarnessIsolation.activate(name: "unit")
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
