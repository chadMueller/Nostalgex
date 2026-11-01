import XCTest
import SwiftUI
@testable import Nostalgex

final class PreferenceSyncMergeTests: XCTestCase {
    private let keys = PreferenceSync.syncedKeys
    private let bundles = PreferenceSync.enabledBundlesKey
    private let collections = PreferenceSync.enabledCollectionsKey
    private let retro = PreferenceSync.retroModeKey
    private let subLang = PreferenceSync.subtitleLanguageKey

    func testLaunchWithNothingLocalAdoptsCloud() {
        let plan = PreferenceSyncMerge.plan(
            local: [:],
            cloud: [bundles: ["nostalgex", "decades"], retro: false],
            keys: keys, trigger: .launch)
        XCTAssertEqual(plan.applyLocally[bundles] as? [String], ["decades", "nostalgex"])
        XCTAssertEqual(plan.applyLocally[retro] as? Bool, false)
        XCTAssertTrue(plan.pushToCloud.isEmpty)
    }

    func testLaunchWithNothingInCloudSeedsCloudFromLocal() {
        let plan = PreferenceSyncMerge.plan(
            local: [retro: true, subLang: "en"], cloud: [:], keys: keys, trigger: .launch)
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertEqual(plan.pushToCloud[retro] as? Bool, true)
        XCTAssertEqual(plan.pushToCloud[subLang] as? String, "en")
    }

    func testExternalChangeCloudWinsWhenBothPresent() {
        let plan = PreferenceSyncMerge.plan(
            local: [retro: true, bundles: ["nostalgex"]],
            cloud: [retro: false, bundles: ["nostalgex", "kids"]],
            keys: keys, trigger: .external(changedKeys: [retro, bundles]))
        XCTAssertEqual(plan.applyLocally[retro] as? Bool, false)
        XCTAssertEqual(plan.applyLocally[bundles] as? [String], ["kids", "nostalgex"])
        XCTAssertTrue(plan.pushToCloud.isEmpty)
    }

    func testExternalChangeOnlyTouchesChangedKeys() {
        let plan = PreferenceSyncMerge.plan(
            local: [retro: true, subLang: "en"],
            cloud: [retro: false, subLang: "fr"],
            keys: keys, trigger: .external(changedKeys: [subLang]))
        XCTAssertNil(plan.applyLocally[retro])
        XCTAssertEqual(plan.applyLocally[subLang] as? String, "fr")
    }

    func testExternalRemovalNeitherClearsLocalNorPushes() {
        let plan = PreferenceSyncMerge.plan(
            local: [retro: true], cloud: [:], keys: keys, trigger: .external(changedKeys: [retro]))
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(plan.pushToCloud.isEmpty)
    }

    func testSameValuesProduceNoWork() {
        let plan = PreferenceSyncMerge.plan(
            local: [bundles: ["b", "a"], retro: true],
            cloud: [bundles: ["a", "b", "a"], retro: true],
            keys: keys, trigger: .launch)
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(plan.pushToCloud.isEmpty)
    }

    func testUnknownCollectionIdsAreKeptVerbatim() {
        let fromOtherServer = "otherServerMachineID:12345"
        let plan = PreferenceSyncMerge.plan(
            local: [collections: ["mine:1"]],
            cloud: [collections: ["mine:1", fromOtherServer]],
            keys: keys, trigger: .external(changedKeys: [collections]))
        XCTAssertEqual(plan.applyLocally[collections] as? [String], ["mine:1", fromOtherServer])
    }

    func testEmptyCollectionsSyncButEmptyBundlesNever() {
        let plan = PreferenceSyncMerge.plan(
            local: [collections: ["a"], bundles: ["nostalgex"]],
            cloud: [collections: [String](), bundles: [String]()],
            keys: keys, trigger: .external(changedKeys: [collections, bundles]))
        XCTAssertEqual(plan.applyLocally[collections] as? [String], [])
        XCTAssertNil(plan.applyLocally[bundles], "an empty lineup from iCloud must never be applied")
    }

    func testWrongTypesAreIgnored() {
        let plan = PreferenceSyncMerge.plan(
            local: [:],
            cloud: [retro: "yes", bundles: 42, subLang: ""],
            keys: keys, trigger: .launch)
        XCTAssertTrue(plan.applyLocally.isEmpty)
    }

    func testKeysOutsideTheSyncedListAreNeverConsidered() {
        let plan = PreferenceSyncMerge.plan(
            local: ["plex_token": "secret", "nostalgex_last_scan_date": "2026-10-13"],
            cloud: ["plex_server_url": "http://10.0.0.2:32400"],
            keys: keys, trigger: .launch)
        XCTAssertTrue(plan.applyLocally.isEmpty)
        XCTAssertTrue(plan.pushToCloud.isEmpty)
    }

    // A second TV switching sync on joins the household. On hardware (2026-10-13) the
    // old "this TV wins" rule let the living room's 1-bundle default lineup overwrite
    // the basement's 5 bundles.
    func testTurnOnJoinsTheHouseholdAndPushesOnlyWhatTheCloudLacks() {
        let plan = PreferenceSyncMerge.plan(
            local: [bundles: ["nostalgex"], retro: false, subLang: "de"],
            cloud: [bundles: ["decades", "kids", "nostalgex"], retro: true],
            keys: keys, trigger: .turnOn)
        XCTAssertEqual(plan.applyLocally[bundles] as? [String], ["decades", "kids", "nostalgex"], "the household lineup wins")
        XCTAssertEqual(plan.applyLocally[retro] as? Bool, true)
        XCTAssertNil(plan.pushToCloud[bundles])
        XCTAssertNil(plan.pushToCloud[retro])
        XCTAssertEqual(plan.pushToCloud[subLang] as? String, "de", "a key iCloud has no value for is seeded")
    }

    func testFirstTVToTurnOnSeedsAnEmptyCloud() {
        let plan = PreferenceSyncMerge.plan(
            local: [bundles: ["nostalgex", "kids"], retro: true], cloud: [:], keys: keys, trigger: .turnOn)
        XCTAssertEqual(plan.pushToCloud[bundles] as? [String], ["kids", "nostalgex"])
        XCTAssertEqual(plan.pushToCloud[retro] as? Bool, true)
        XCTAssertTrue(plan.applyLocally.isEmpty)
    }

    func testFranchisesKeyIsSyncedAsAStringSetThatMayBeEmpty() {
        XCTAssertTrue(keys.contains(PreferenceSync.enabledFranchisesKey))
        XCTAssertEqual(PreferenceSync.enabledFranchisesKey, AppState.enabledFranchisesKey)
        XCTAssertEqual(PreferenceSync.kind(of: PreferenceSync.enabledFranchisesKey), .stringSet(allowEmpty: true))
        let plan = PreferenceSyncMerge.plan(
            local: [PreferenceSync.enabledFranchisesKey: ["b", "a"]], cloud: [:], keys: keys, trigger: .launch)
        XCTAssertEqual(plan.pushToCloud[PreferenceSync.enabledFranchisesKey] as? [String], ["a", "b"])
    }

    func testDisabledFranchisesKeySyncsAlongsideTheEnabledOne() {
        // Without it, a TV that never saw the viewer switch STAR TREK off would put the
        // default-on channel back.
        XCTAssertTrue(keys.contains(PreferenceSync.disabledFranchisesKey))
        XCTAssertEqual(PreferenceSync.disabledFranchisesKey, "nostalgex_disabled_franchises")
        XCTAssertEqual(PreferenceSync.disabledFranchisesKey, AppState.disabledFranchisesKey)
        XCTAssertEqual(PreferenceSync.kind(of: PreferenceSync.disabledFranchisesKey), .stringSet(allowEmpty: true))
    }

    func testSyncSwitchItselfIsNeverASyncedKey() {
        XCTAssertFalse(keys.contains(PreferenceSync.syncEnabledKey))
        XCTAssertNil(PreferenceSync.kind(of: PreferenceSync.syncEnabledKey))
    }

    func testSnapshotRestorePrefersSavedLineupPlusDiscoveredCategories() {
        let preferred = AppState.preferredBundleIDsAfterSnapshot(
            stored: ["nostalgex", "kids"],
            snapshotWithDiscoveries: ["nostalgex", "collections-franchises"],
            discoveredCategoryBundleIDs: ["collections-franchises"])
        XCTAssertEqual(preferred, ["nostalgex", "kids", "collections-franchises"])
        XCTAssertEqual(
            AppState.preferredBundleIDsAfterSnapshot(stored: nil, snapshotWithDiscoveries: ["x"], discoveredCategoryBundleIDs: []),
            ["x"])
    }
}

@MainActor
final class PreferenceSyncServiceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "PreferenceSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A service for a TV whose viewer has already switched sync on.
    private func enabledSync(_ store: InMemoryKeyValueStore) -> PreferenceSync {
        defaults.set(true, forKey: PreferenceSync.syncEnabledKey)
        return PreferenceSync(cloud: store, defaults: defaults, observeNotifications: false, keys: PreferenceSync.syncedKeys)
    }

    /// Everything that must stay on the device. None of these may ever reach iCloud.
    static let neverSyncedKeys = [
        // Credentials, server and account identity
        "plex_server_url", "plex_token", "plex_servers", "backend_kind", "jellyfin_user_id",
        "plex90_client_id",
        // The per-TV sync switch itself
        PreferenceSync.syncEnabledKey,
        // Caches and load state
        "nostalgex_last_scan_date", "nostalgex_last_load_at_unix", "nostalgex_completed_initial_load",
        "nostalgex_has_held_sign_in",
        // Rating nudge and tip ledger
        "nostalgex_rating_nudge_has_launched", "nostalgex_rating_nudge_sessions",
        "nostalgex_rating_nudge_shown_version", "tipJar.thankedTransactionIDs",
    ]

    // MARK: Off by default

    func testSyncIsOffByDefault() {
        let store = InMemoryKeyValueStore()
        let sync = PreferenceSync(cloud: store, defaults: defaults, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertNil(defaults.object(forKey: PreferenceSync.syncEnabledKey), "the default is absent, not a stored false")
    }

    func testWhileOffNothingTouchesTheStore() {
        defaults.set(true, forKey: PreferenceSync.retroModeKey)
        defaults.set(["nostalgex"], forKey: PreferenceSync.enabledBundlesKey)
        let store = InMemoryKeyValueStore([PreferenceSync.retroModeKey: false, PreferenceSync.subtitleLanguageKey: "fr"])
        let sync = PreferenceSync(cloud: store, defaults: defaults, observeNotifications: false, keys: PreferenceSync.syncedKeys)

        sync.bootstrap()
        sync.record(PreferenceSync.retroModeKey, value: true)
        sync.record(PreferenceSync.enabledBundlesKey, value: ["nostalgex", "kids"])
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.retroModeKey, PreferenceSync.subtitleLanguageKey])
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange, changedKeys: [])
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreAccountChange, changedKeys: [])

        XCTAssertTrue(store.reads.isEmpty, "read \(store.reads)")
        XCTAssertTrue(store.writes.isEmpty, "wrote \(store.writes.map(\.key))")
        XCTAssertEqual(store.synchronizeCount, 0)
        XCTAssertFalse(sync.holdingOutgoing, "the new-TV hold only exists for a TV that syncs")
        XCTAssertEqual(defaults.object(forKey: PreferenceSync.retroModeKey) as? Bool, true, "local untouched")
        XCTAssertNil(defaults.string(forKey: PreferenceSync.subtitleLanguageKey), "cloud value not adopted")
    }

    // MARK: Turning on and off

    func testTurnOnAdoptsTheHouseholdLineupAndSeedsOnlyMissingKeys() {
        defaults.set(["nostalgex"], forKey: PreferenceSync.enabledBundlesKey)
        defaults.set(false, forKey: PreferenceSync.retroModeKey)
        defaults.set("de", forKey: PreferenceSync.audioLanguageKey)
        let store = InMemoryKeyValueStore([
            PreferenceSync.enabledBundlesKey: ["decades", "kids", "nostalgex"],
            PreferenceSync.retroModeKey: true,
            PreferenceSync.subtitleLanguageKey: "fr",
        ])
        let sync = PreferenceSync(cloud: store, defaults: defaults, observeNotifications: false, keys: PreferenceSync.syncedKeys)

        sync.setEnabled(true)

        XCTAssertTrue(sync.isEnabled)
        XCTAssertEqual(defaults.bool(forKey: PreferenceSync.syncEnabledKey), true)
        XCTAssertEqual(Set(defaults.stringArray(forKey: PreferenceSync.enabledBundlesKey) ?? []), ["decades", "kids", "nostalgex"], "the household lineup wins")
        XCTAssertEqual(defaults.object(forKey: PreferenceSync.retroModeKey) as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: PreferenceSync.subtitleLanguageKey), "fr")
        XCTAssertEqual(Set(store.values[PreferenceSync.enabledBundlesKey] as? [String] ?? []), ["decades", "kids", "nostalgex"], "iCloud untouched")
        XCTAssertEqual(store.writes.map(\.key), [PreferenceSync.audioLanguageKey], "only the key iCloud lacked is pushed")
        XCTAssertGreaterThan(store.synchronizeCount, 0)
    }

    func testTurnOnWithNothingLocalAdoptsTheCloud() {
        let store = InMemoryKeyValueStore([PreferenceSync.enabledBundlesKey: ["decades"], PreferenceSync.retroModeKey: false])
        let sync = PreferenceSync(cloud: store, defaults: defaults, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        sync.setEnabled(true)
        XCTAssertEqual(defaults.stringArray(forKey: PreferenceSync.enabledBundlesKey), ["decades"])
        XCTAssertEqual(defaults.object(forKey: PreferenceSync.retroModeKey) as? Bool, false)
        XCTAssertTrue(store.writes.isEmpty, "nothing to push")
    }

    func testTurnOffStopsListeningAndLeavesBothSidesAlone() {
        defaults.set(true, forKey: PreferenceSync.retroModeKey)
        let store = InMemoryKeyValueStore([PreferenceSync.retroModeKey: true])
        let sync = enabledSync(store)
        sync.bootstrap()
        let writesAtOff = store.writes.count
        let readsAtOff = store.reads.count

        sync.setEnabled(false)

        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(defaults.bool(forKey: PreferenceSync.syncEnabledKey), false)
        sync.record(PreferenceSync.retroModeKey, value: false)
        store.values[PreferenceSync.retroModeKey] = false
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange, changedKeys: [PreferenceSync.retroModeKey])
        XCTAssertEqual(store.writes.count, writesAtOff, "iCloud left as it was")
        XCTAssertEqual(store.reads.count, readsAtOff, "no reads once off")
        XCTAssertEqual(defaults.object(forKey: PreferenceSync.retroModeKey) as? Bool, true, "local left as it was")
    }

    func testSettingTheSameStateTwiceIsANoOp() {
        let store = InMemoryKeyValueStore([PreferenceSync.retroModeKey: false])
        let sync = PreferenceSync(cloud: store, defaults: defaults, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        sync.setEnabled(false)
        XCTAssertTrue(store.reads.isEmpty)
        XCTAssertEqual(store.synchronizeCount, 0)
        sync.setEnabled(true)
        let synchronizesAfterOn = store.synchronizeCount
        sync.setEnabled(true)
        XCTAssertEqual(store.synchronizeCount, synchronizesAfterOn, "a second turn-on must not re-run the merge")
    }

    func testLaunchAfterTurningOnPullsAndSeedsLikeBefore() {
        defaults.set(true, forKey: PreferenceSync.retroModeKey)
        let store = InMemoryKeyValueStore([PreferenceSync.subtitleLanguageKey: "de"])
        let sync = enabledSync(store)
        sync.bootstrap()
        XCTAssertEqual(defaults.string(forKey: PreferenceSync.subtitleLanguageKey), "de")
        XCTAssertEqual(store.values[PreferenceSync.retroModeKey] as? Bool, true)
    }

    // MARK: Never-synced keys

    func testBootstrapNeverPushesNeverSyncedKeys() {
        for key in Self.neverSyncedKeys where key != PreferenceSync.syncEnabledKey { defaults.set("value", forKey: key) }
        defaults.set(false, forKey: PreferenceSync.retroModeKey)
        let store = InMemoryKeyValueStore()
        let sync = enabledSync(store)

        sync.bootstrap()

        XCTAssertEqual(store.writes.map(\.key), [PreferenceSync.retroModeKey])
        for key in Self.neverSyncedKeys { XCTAssertNil(store.values[key], key) }
    }

    func testTurnOnNeverPushesNeverSyncedKeys() {
        for key in Self.neverSyncedKeys where key != PreferenceSync.syncEnabledKey { defaults.set("value", forKey: key) }
        let store = InMemoryKeyValueStore()
        let sync = PreferenceSync(cloud: store, defaults: defaults, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        sync.setEnabled(true)
        for key in Self.neverSyncedKeys { XCTAssertNil(store.values[key], key) }
        XCTAssertFalse(store.reads.contains(PreferenceSync.syncEnabledKey))
    }

    func testRecordRefusesKeysOutsideTheSyncedList() {
        let store = InMemoryKeyValueStore()
        let sync = enabledSync(store)
        for key in Self.neverSyncedKeys { sync.record(key, value: "value") }
        XCTAssertTrue(store.writes.isEmpty)
    }

    // MARK: Behaviour once on (unchanged from before the switch existed)

    func testBootstrapAdoptsCloudBeforeDefaultsAreRead() {
        let store = InMemoryKeyValueStore([
            PreferenceSync.enabledBundlesKey: ["nostalgex", "decades"],
            PreferenceSync.retroModeKey: false,
        ])
        let sync = enabledSync(store)

        sync.bootstrap()

        XCTAssertEqual(Set(defaults.stringArray(forKey: PreferenceSync.enabledBundlesKey) ?? []), ["nostalgex", "decades"])
        XCTAssertEqual(defaults.object(forKey: PreferenceSync.retroModeKey) as? Bool, false)
        XCTAssertTrue(store.writes.isEmpty, "adopting must not write anything back")
        XCTAssertFalse(sync.holdingOutgoing)
    }

    func testNewTVHoldsWritesUntilICloudDelivers() {
        let store = InMemoryKeyValueStore()
        let sync = enabledSync(store)
        sync.bootstrap()
        XCTAssertTrue(sync.holdingOutgoing)

        // First load writes default lineup and retro mode on this empty install.
        defaults.set(["nostalgex"], forKey: PreferenceSync.enabledBundlesKey)
        sync.record(PreferenceSync.enabledBundlesKey, value: ["nostalgex"])
        defaults.set(true, forKey: PreferenceSync.retroModeKey)
        sync.record(PreferenceSync.retroModeKey, value: true)
        XCTAssertTrue(store.writes.isEmpty)

        // The household's lineup arrives; it wins, and only the key iCloud lacked is pushed.
        store.values[PreferenceSync.enabledBundlesKey] = ["nostalgex", "kids"]
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange,
                                  changedKeys: [PreferenceSync.enabledBundlesKey])

        XCTAssertFalse(sync.holdingOutgoing)
        XCTAssertEqual(Set(defaults.stringArray(forKey: PreferenceSync.enabledBundlesKey) ?? []), ["nostalgex", "kids"])
        XCTAssertEqual(store.writes.map(\.key), [PreferenceSync.retroModeKey])
    }

    func testQuotaViolationAppliesNothing() {
        let store = InMemoryKeyValueStore([PreferenceSync.retroModeKey: false])
        defaults.set(true, forKey: PreferenceSync.retroModeKey)
        let sync = enabledSync(store)
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreQuotaViolationChange,
                                  changedKeys: [PreferenceSync.retroModeKey])
        XCTAssertEqual(defaults.object(forKey: PreferenceSync.retroModeKey) as? Bool, true)
    }

    func testAccountChangeRepullsEverything() {
        let store = InMemoryKeyValueStore([PreferenceSync.subtitleLanguageKey: "de"])
        defaults.set("en", forKey: PreferenceSync.subtitleLanguageKey)
        defaults.set(true, forKey: PreferenceSync.retroModeKey)
        let sync = enabledSync(store)
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreAccountChange, changedKeys: [])
        XCTAssertEqual(defaults.string(forKey: PreferenceSync.subtitleLanguageKey), "de")
        XCTAssertEqual(store.values[PreferenceSync.retroModeKey] as? Bool, true, "seeds the new account")
    }
}

/// AppState wired to a fake store. AppState writes UserDefaults.standard directly, so the
/// synced keys (and the per-TV switch) are saved and restored around each test. The
/// fixture starts with sync ON, the way a viewer who flipped the Settings row has it;
/// the off-by-default cases build their own.
@MainActor
final class PreferenceSyncAppStateTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private var store: InMemoryKeyValueStore!
    private var sync: PreferenceSync!
    private var state: AppState!

    private static let touchedKeys = PreferenceSync.syncedKeys + ["nostalgex_sync_plex_activity", PreferenceSync.syncEnabledKey]

    override func setUp() {
        for key in Self.touchedKeys {
            if let v = UserDefaults.standard.object(forKey: key) { saved[key] = v }
        }
        UserDefaults.standard.set(true, forKey: PreferenceSync.syncEnabledKey)
        store = InMemoryKeyValueStore()
        sync = PreferenceSync(cloud: store, defaults: .standard, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        state = AppState(preferenceSync: sync)
    }

    override func tearDown() {
        state = nil
        for key in Self.touchedKeys {
            if let v = saved[key] { UserDefaults.standard.set(v, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    // MARK: The switch

    func testFreshAppStateHasSyncOffAndWritesNothingToTheStore() {
        UserDefaults.standard.removeObject(forKey: PreferenceSync.syncEnabledKey)
        let offStore = InMemoryKeyValueStore([PreferenceSync.retroModeKey: false])
        let offSync = PreferenceSync(cloud: offStore, defaults: .standard, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        let offState = AppState(preferenceSync: offSync)

        XCTAssertFalse(offState.iCloudSyncEnabled)
        offState.retroMode.toggle()
        offState.preferredAudioLanguageCode = "ja"
        offState.enabledFranchiseIDs = ["ghostbusters"]
        offState.saveFranchisePreferences()
        offSync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange, changedKeys: [PreferenceSync.retroModeKey])

        XCTAssertTrue(offStore.reads.isEmpty, "read \(offStore.reads)")
        XCTAssertTrue(offStore.writes.isEmpty, "wrote \(offStore.writes.map(\.key))")
        XCTAssertEqual(offStore.synchronizeCount, 0)
    }

    func testTurningTheRowOnJoinsTheHousehold() {
        UserDefaults.standard.removeObject(forKey: PreferenceSync.syncEnabledKey)
        let onStore = InMemoryKeyValueStore()
        let onSync = PreferenceSync(cloud: onStore, defaults: .standard, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        let onState = AppState(preferenceSync: onSync)
        XCTAssertFalse(onState.iCloudSyncEnabled)
        // This TV has a retro mode choice; another TV put the opposite in iCloud.
        let retroBefore = onState.retroMode
        UserDefaults.standard.set(retroBefore, forKey: PreferenceSync.retroModeKey)
        onStore.values[PreferenceSync.retroModeKey] = !retroBefore

        onState.iCloudSyncEnabled = true

        XCTAssertTrue(onSync.isEnabled)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: PreferenceSync.syncEnabledKey), true)
        XCTAssertEqual(onStore.values[PreferenceSync.retroModeKey] as? Bool, !retroBefore, "the household's value stays in iCloud")
        XCTAssertEqual(onState.retroMode, !retroBefore, "and comes down to this TV")

        onState.iCloudSyncEnabled = false
        XCTAssertFalse(onSync.isEnabled)
        XCTAssertEqual(onStore.values[PreferenceSync.retroModeKey] as? Bool, !retroBefore, "turning off leaves iCloud as it is")
        XCTAssertEqual(onState.retroMode, !retroBefore)
    }

    func testStateMirrorsAnAlreadyEnabledService() {
        XCTAssertTrue(state.iCloudSyncEnabled)
        XCTAssertTrue(sync.isEnabled)
    }

    // MARK: Franchises

    func testFranchiseSwitchesGoToICloudAndComeBack() {
        state.enabledFranchiseIDs = ["ghostbusters", "alien"]
        state.saveFranchisePreferences()
        XCTAssertEqual(store.values[PreferenceSync.enabledFranchisesKey] as? [String], ["alien", "ghostbusters"])

        let writesBefore = store.writes.count
        store.values[PreferenceSync.enabledFranchisesKey] = ["alien", "from-another-library"]
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.enabledFranchisesKey])

        XCTAssertEqual(state.enabledFranchiseIDs, ["alien", "from-another-library"], "unknown ids are kept")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AppState.enabledFranchisesKey), ["alien", "from-another-library"])
        XCTAssertEqual(store.writes.count, writesBefore, "an incoming value must not be written back to iCloud")
    }

    func testAnExplicitOffArrivingFromAnotherTVIsKept() {
        state.disabledFranchiseIDs = []
        state.saveFranchisePreferences()
        XCTAssertEqual(store.values[PreferenceSync.disabledFranchisesKey] as? [String], [])

        store.values[PreferenceSync.disabledFranchisesKey] = ["dict:STAR TREK"]
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.disabledFranchisesKey])

        XCTAssertEqual(state.disabledFranchiseIDs, ["dict:STAR TREK"])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AppState.disabledFranchisesKey), ["dict:STAR TREK"])
    }

    // MARK: Behaviour once on

    func testLocalChangesGoToICloudThroughTheExistingDidSets() {
        state.retroMode.toggle()
        state.preferredAudioLanguageCode = "ja"
        XCTAssertEqual(store.values[PreferenceSync.retroModeKey] as? Bool, state.retroMode)
        XCTAssertEqual(store.values[PreferenceSync.audioLanguageKey] as? String, "ja")
    }

    func testGuideTextSizeSyncsBothWaysLikeRetroMode() {
        state.guideTextSize = .large
        XCTAssertEqual(store.values[PreferenceSync.guideTextSizeKey] as? String, "large")
        let writes = store.writes.count
        store.values[PreferenceSync.guideTextSizeKey] = "normal"
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.guideTextSizeKey])
        XCTAssertEqual(state.guideTextSize, .normal)
        XCTAssertEqual(store.writes.count, writes, "an incoming value was echoed back")
    }

    func testNeverSyncedPreferencesStayLocal() {
        state.serverURL = "http://192.168.1.20:32400"
        state.token = "secret-token"
        let allowed = Set(PreferenceSync.syncedKeys)
        for write in store.writes { XCTAssertTrue(allowed.contains(write.key), write.key) }
        XCTAssertNil(store.values["plex_server_url"])
        XCTAssertNil(store.values["plex_token"])
    }

    func testIndependentReportingChoicesSyncBothWaysWithoutEcho() {
        state.setPlaybackReporting(showNowPlaying: true, markWatched: false)
        XCTAssertEqual(store.values[PreferenceSync.nowPlayingKey] as? Bool, true)
        XCTAssertEqual(store.values[PreferenceSync.markWatchedKey] as? Bool, false)
        XCTAssertEqual(store.values[PreferenceSync.reportPlaybackKey] as? Bool, false)
        let writes = store.writes.count
        store.values[PreferenceSync.nowPlayingKey] = false
        store.values[PreferenceSync.markWatchedKey] = true
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.nowPlayingKey, PreferenceSync.markWatchedKey])
        XCTAssertFalse(state.showNowPlaying)
        XCTAssertTrue(state.markWatched)
        XCTAssertEqual(store.writes.count, writes)
    }

    func testChangingOneReportingChoicePublishesTheCompletePairAfterMigration() {
        state.setPlaybackReporting(showNowPlaying: true, markWatched: true)
        // A legacy opt-in has migrated locally, but its v2 keys are not in iCloud yet.
        store.values.removeValue(forKey: PreferenceSync.nowPlayingKey)
        store.values.removeValue(forKey: PreferenceSync.markWatchedKey)
        state.markWatched = false
        XCTAssertEqual(store.values[PreferenceSync.nowPlayingKey] as? Bool, true)
        XCTAssertEqual(store.values[PreferenceSync.markWatchedKey] as? Bool, false)
        XCTAssertEqual(store.values[PreferenceSync.reportPlaybackKey] as? Bool, false)
    }

    func testIncomingLegacyTrueCannotOverrideExplicitNewOff() {
        state.setPlaybackReporting(showNowPlaying: true, markWatched: false)
        store.values[PreferenceSync.reportPlaybackKey] = true
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.reportPlaybackKey])
        XCTAssertTrue(state.showNowPlaying)
        XCTAssertFalse(state.markWatched)
    }

    func testDelayedLegacyCloudChoiceFillsOnlyMissingNewChoices() {
        UserDefaults.standard.removeObject(forKey: PreferenceSync.nowPlayingKey)
        UserDefaults.standard.removeObject(forKey: PreferenceSync.markWatchedKey)
        store.values[PreferenceSync.reportPlaybackKey] = true
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange,
                                  changedKeys: [PreferenceSync.reportPlaybackKey])
        XCTAssertTrue(state.showNowPlaying)
        XCTAssertTrue(state.markWatched)
        XCTAssertEqual(UserDefaults.standard.object(forKey: PreferenceSync.nowPlayingKey) as? Bool, true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: PreferenceSync.markWatchedKey) as? Bool, true)
    }

    func testStreamQualityIsASyncedString() {
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(StreamQuality.storageKey))
        XCTAssertEqual(PreferenceSync.kind(of: StreamQuality.storageKey), .string)
        XCTAssertEqual(PreferenceSync.reportPlaybackKey, AppState.syncPlexActivityDefaultsKey)
    }

    func testIncomingChangeIsAppliedWithoutEcho() {
        let target = !state.retroMode
        store.values[PreferenceSync.retroModeKey] = target
        store.values[PreferenceSync.subtitlesFullscreenKey] = true
        let writesBefore = store.writes.count

        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.retroModeKey, PreferenceSync.subtitlesFullscreenKey])

        XCTAssertEqual(state.retroMode, target)
        XCTAssertTrue(state.subtitlesInFullscreenEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: PreferenceSync.retroModeKey) as? Bool, target)
        XCTAssertEqual(store.writes.count, writesBefore, "an incoming value must not be written back to iCloud")
    }

    func testIncomingBundlesRebuildTheLineupLikeASettingsToggle() {
        func channel(_ id: Int) -> Channel {
            Channel(id: id, number: id, name: "CH\(id)", color: .blue, category: nil,
                    rules: nil, timeRestrictions: nil, minItems: 0, itemPool: [])
        }
        state.allChannels = [channel(1), channel(2)]
        state.bundles = [
            ChannelBundle(id: "nostalgex", name: "A", description: "", channelIDs: [1], activeMonths: nil, enabled: true),
            ChannelBundle(id: "kids", name: "B", description: "", channelIDs: [2], activeMonths: nil, enabled: false),
        ]
        state.enabledBundleIDs = ["nostalgex"]
        state.applyBundleFilter()
        XCTAssertEqual(state.channels.map(\.id), [1])
        let writesBefore = store.writes.count

        store.values[PreferenceSync.enabledBundlesKey] = ["nostalgex", "kids", "collections-from-other-server"]
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.enabledBundlesKey])

        XCTAssertEqual(state.channels.map(\.id), [1, 2])
        XCTAssertTrue(state.bundles.allSatisfy(\.enabled))
        XCTAssertTrue(state.enabledBundleIDs.contains("collections-from-other-server"), "unknown ids are kept")
        XCTAssertEqual(store.writes.count, writesBefore)
    }

    // On hardware (2026-10-13) each TV's launch rewrote the lineup in iCloud from its own
    // snapshot restore and collection bookkeeping, so the last TV to load won. Only a
    // toggle the viewer makes may reach iCloud.
    func testOnlyTheViewersOwnToggleSendsTheLineupToICloud() {
        state.bundles = [
            ChannelBundle(id: "nostalgex", name: "A", description: "", channelIDs: [1], activeMonths: nil, enabled: true),
            ChannelBundle(id: "kids", name: "B", description: "", channelIDs: [2], activeMonths: nil, enabled: false),
        ]
        state.enabledBundleIDs = ["nostalgex", "collections-franchises"]
        state.saveBundlePreferences()
        state.syncCollectionCategoryBundlesWithDiscoveries()
        state.materializeDynamicChannels()
        XCTAssertFalse(store.writes.contains { $0.key == PreferenceSync.enabledBundlesKey }, "load-time saves stay on this TV")
        XCTAssertEqual(Set(UserDefaults.standard.stringArray(forKey: PreferenceSync.enabledBundlesKey) ?? []),
                       ["nostalgex", "collections-franchises"], "but are still saved locally")

        state.toggleBundle(state.bundles[1])
        XCTAssertEqual(Set(store.values[PreferenceSync.enabledBundlesKey] as? [String] ?? []),
                       ["nostalgex", "kids", "collections-franchises"])
    }

    func testIncomingCollectionIdsFromAnotherServerAreKeptButMatchNothing() {
        store.values[PreferenceSync.enabledCollectionsKey] = ["otherServer:99"]
        sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange,
                                  changedKeys: [PreferenceSync.enabledCollectionsKey])
        XCTAssertEqual(state.enabledCollectionKeys, ["otherServer:99"])
        XCTAssertTrue(state.discoveredCollections.isEmpty)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: PreferenceSync.enabledCollectionsKey), ["otherServer:99"])
    }
}
