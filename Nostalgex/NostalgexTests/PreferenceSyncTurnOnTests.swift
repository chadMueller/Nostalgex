import XCTest
@testable import Nostalgex

/// N-036: turning iCloud sync on can push a new TV's defaults over the other TVs' lineup.
///
/// `NSUbiquitousKeyValueStore` is a local copy that iCloud fills in the background. On a TV
/// that has not downloaded yet it reads as empty, even when the household has a lineup in
/// iCloud. `setEnabled(true)` read that empty copy, found nothing in the cloud for any key
/// it had a value for, and pushed the lot: the new TV's first-load defaults went up as the
/// latest write and every other TV took them (seen on hardware 2026-10-13 for the
/// second-TV case; the launch path got a hold for it, turn-on did not).
///
/// `FakeICloud` is what makes that visible: a server, and one local copy per TV that stays
/// empty until `downloadInitial()`, uploads on `synchronize()`, last write wins, and tells
/// the other TVs that have downloaded.
@MainActor
final class PreferenceSyncTurnOnTests: XCTestCase {

    private let bundles = PreferenceSync.enabledBundlesKey
    private let retro = PreferenceSync.retroModeKey
    private let household = ["decades", "kids", "nostalgex", "premium"]

    // MARK: Fake iCloud

    private final class FakeICloud {
        var server: [String: Any] = [:]
        var devices: [Device] = []

        final class Device: UbiquitousKeyValueStoring {
            unowned let cloud: FakeICloud
            private(set) var cache: [String: Any] = [:]
            private var unsent: [String: Any?] = [:]
            private(set) var downloaded = false
            private(set) var uploads: [String] = []
            /// The TV's PreferenceSync, told about changes the way the notification does.
            var onChange: ((_ reason: Int, _ keys: [String]) -> Void)?

            init(cloud: FakeICloud) { self.cloud = cloud; cloud.devices.append(self) }

            func object(forKey aKey: String) -> Any? { cache[aKey] }
            func set(_ anObject: Any?, forKey aKey: String) { cache[aKey] = anObject; unsent[aKey] = .some(anObject) }
            func removeObject(forKey aKey: String) { cache[aKey] = nil; unsent[aKey] = .some(nil) }
            @discardableResult func synchronize() -> Bool { cloud.upload(from: self); return true }

            /// This TV already has what the server holds (it has been on, or downloaded).
            func startDownloaded() { cache = cloud.server; downloaded = true }

            /// The first download arrives: the server's values reach this TV's copy.
            func downloadInitial() {
                downloaded = true
                for (k, v) in cloud.server { cache[k] = v }
                onChange?(NSUbiquitousKeyValueStoreInitialSyncChange, Array(cloud.server.keys))
            }

            fileprivate func take(_ changes: [String: Any?]) {
                for (k, v) in changes { cache[k] = v ?? nil }
                onChange?(NSUbiquitousKeyValueStoreServerChange, Array(changes.keys))
            }
            fileprivate func noteUploaded(_ keys: [String]) { uploads.append(contentsOf: keys); unsent = [:] }
            fileprivate var pending: [String: Any?] { unsent }
        }

        func upload(from device: Device) {
            let changes = device.pending
            guard !changes.isEmpty else { return }
            for (k, v) in changes { server[k] = v ?? nil }
            device.noteUploaded(Array(changes.keys))
            for other in devices where other !== device && other.downloaded { other.take(changes) }
        }
    }

    private struct TV {
        let device: FakeICloud.Device
        let defaults: UserDefaults
        let sync: PreferenceSync
        func bundles(_ key: String) -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    }

    private func makeTV(_ cloud: FakeICloud, name: String, syncing: Bool, downloaded: Bool, holdTimeout: TimeInterval? = nil) -> TV {
        let defaults = UserDefaults(suiteName: "n036-\(name)-\(UUID().uuidString)")!
        if syncing { defaults.set(true, forKey: PreferenceSync.syncEnabledKey) }
        let device = FakeICloud.Device(cloud: cloud)
        if downloaded { device.startDownloaded() }
        let sync = PreferenceSync(cloud: device, defaults: defaults, observeNotifications: false, keys: PreferenceSync.syncedKeys,
                                  holdTimeout: holdTimeout ?? TimeInterval(PreferenceSync.holdTimeoutSeconds))
        device.onChange = { [weak sync] reason, keys in sync?.handleExternalChange(reason: reason, changedKeys: keys) }
        return TV(device: device, defaults: defaults, sync: sync)
    }

    /// The household: iCloud holds a four-package lineup and Retro Mode off, set on another TV.
    private func householdCloud() -> FakeICloud {
        let cloud = FakeICloud()
        cloud.server = [bundles: household, retro: false]
        return cloud
    }

    /// What a new TV has after its first load: the default package, written locally, and
    /// Retro Mode on, its default.
    private func giveFirstLoadDefaults(_ tv: TV) {
        tv.defaults.set(["nostalgex"], forKey: bundles)
        tv.defaults.set(true, forKey: retro)
    }

    // MARK: The overwrite

    /// The new TV turns sync on before its first iCloud download has arrived. The household's
    /// lineup must survive, and the new TV must end up with it.
    func testTurningOnBeforeTheFirstDownloadDoesNotOverwriteTheHouseholdLineup() {
        let cloud = householdCloud()
        let tvA = makeTV(cloud, name: "A", syncing: true, downloaded: true)
        tvA.defaults.set(household, forKey: bundles)
        tvA.defaults.set(false, forKey: retro)
        let tvB = makeTV(cloud, name: "B", syncing: false, downloaded: false)
        giveFirstLoadDefaults(tvB)

        tvB.sync.setEnabled(true)
        tvB.device.downloadInitial()

        XCTAssertEqual(Set(cloud.server[bundles] as? [String] ?? []), Set(household), "iCloud: the new TV's default package replaced the household lineup")
        XCTAssertEqual(cloud.server[retro] as? Bool, false, "iCloud: Retro Mode")
        XCTAssertEqual(tvA.bundles(bundles), Set(household), "the other TV lost its lineup")
        XCTAssertEqual(tvA.defaults.object(forKey: retro) as? Bool, false, "the other TV's Retro Mode changed")
        XCTAssertEqual(tvB.bundles(bundles), Set(household), "the new TV should join the household's lineup")
        XCTAssertEqual(tvB.defaults.object(forKey: retro) as? Bool, false)
    }

    /// The first TV to turn sync on finds iCloud empty and seeds it: once the download has
    /// come back empty, its lineup goes up. Nothing goes up before that.
    func testTheFirstTVSeedsAnEmptyICloudOnlyOnceItsDownloadComesBack() {
        let cloud = FakeICloud()
        let tv = makeTV(cloud, name: "first", syncing: false, downloaded: false)
        giveFirstLoadDefaults(tv)

        tv.sync.setEnabled(true)
        XCTAssertTrue(cloud.server.isEmpty, "the push is held until iCloud has had its say: \(cloud.server.keys)")

        tv.device.downloadInitial()
        XCTAssertEqual(Set(cloud.server[bundles] as? [String] ?? []), ["nostalgex"], "empty iCloud, so this TV seeds it")
        XCTAssertEqual(cloud.server[retro] as? Bool, true)
    }

    func testTurningOffDuringTheHoldPushesNothing() {
        let cloud = FakeICloud()
        let tv = makeTV(cloud, name: "off", syncing: false, downloaded: false)
        giveFirstLoadDefaults(tv)

        tv.sync.setEnabled(true)
        tv.sync.setEnabled(false)
        tv.device.downloadInitial()

        XCTAssertTrue(cloud.server.isEmpty, "sync was off again before anything arrived: \(cloud.server.keys)")
    }

    /// iCloud really is empty and nothing ever arrives: the wait ends on its own and this
    /// TV seeds it.
    func testTheHoldEndsOnItsOwnWhenNothingEverArrives() async throws {
        let cloud = FakeICloud()
        let tv = makeTV(cloud, name: "timeout", syncing: false, downloaded: false, holdTimeout: 0.3)
        giveFirstLoadDefaults(tv)

        tv.sync.setEnabled(true)
        XCTAssertTrue(cloud.server.isEmpty)
        XCTAssertTrue(tv.sync.holdingOutgoing)

        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertFalse(tv.sync.holdingOutgoing)
        XCTAssertEqual(Set(cloud.server[bundles] as? [String] ?? []), ["nostalgex"], "the wait is over: this TV seeds iCloud")
    }

    /// iCloud already shows the household: that is the download having arrived, so there is
    /// nothing to wait for. The household wins and only a key iCloud lacks goes up.
    func testTurningOnWithTheDownloadAlreadyHereDoesNotWait() {
        let cloud = householdCloud()
        let tv = makeTV(cloud, name: "here", syncing: false, downloaded: true)
        giveFirstLoadDefaults(tv)
        tv.defaults.set("de", forKey: PreferenceSync.audioLanguageKey)

        tv.sync.setEnabled(true)

        XCTAssertFalse(tv.sync.holdingOutgoing)
        XCTAssertEqual(tv.bundles(bundles), Set(household), "joins the household")
        XCTAssertEqual(Set(cloud.server[bundles] as? [String] ?? []), Set(household), "iCloud untouched")
        XCTAssertEqual(cloud.server[PreferenceSync.audioLanguageKey] as? String, "de", "the key iCloud lacked is pushed at once")
    }
}
