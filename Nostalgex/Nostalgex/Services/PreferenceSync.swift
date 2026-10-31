import Foundation

/// The slice of `NSUbiquitousKeyValueStore` that `PreferenceSync` uses, so tests can
/// swap in an in-memory store and assert exactly what would have gone to iCloud.
protocol UbiquitousKeyValueStoring: AnyObject {
    func object(forKey aKey: String) -> Any?
    func set(_ anObject: Any?, forKey aKey: String)
    func removeObject(forKey aKey: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {}

/// Plain dictionary store. Used under XCTest (the host app has no iCloud entitlement
/// there) and by the unit tests. Every read, write and synchronize is counted so a test
/// can prove the store was never touched while sync is off.
final class InMemoryKeyValueStore: UbiquitousKeyValueStoring {
    var values: [String: Any] = [:]
    private(set) var writes: [(key: String, value: Any?)] = []
    private(set) var reads: [String] = []
    private(set) var synchronizeCount = 0

    init(_ values: [String: Any] = [:]) { self.values = values }

    func object(forKey aKey: String) -> Any? {
        reads.append(aKey)
        return values[aKey]
    }
    func set(_ anObject: Any?, forKey aKey: String) {
        writes.append((aKey, anObject))
        values[aKey] = anObject
    }
    func removeObject(forKey aKey: String) {
        writes.append((aKey, nil))
        values[aKey] = nil
    }
    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }
}

/// Receives preference values that arrived from another Apple TV.
@MainActor
protocol PreferenceSyncApplying: AnyObject {
    /// Values are already validated and keyed by their UserDefaults key.
    func applyIncomingPreferences(_ values: [String: Any])
}

/// Pure merge rules, kept free of stores and notifications so they can be unit tested.
enum PreferenceSyncMerge {
    enum Trigger: Equatable {
        /// App launch, before AppState reads its defaults.
        case launch
        /// Another device changed these keys (server change or initial sync).
        case external(changedKeys: [String])
        /// The iCloud account on this TV changed. Re-pull everything.
        case accountChange
        /// The viewer switched sync on in Settings. Merges like launch: a TV joining a
        /// household that already syncs takes the household's lineup.
        case turnOn
    }

    struct Plan {
        /// Cloud values this TV should adopt (written to UserDefaults and applied to AppState).
        var applyLocally: [String: Any] = [:]
        /// Local values iCloud does not have yet.
        var pushToCloud: [String: Any] = [:]
    }

    /// - local-empty adopts cloud.
    /// - both present: cloud wins. The local copy of the store already holds this TV's
    ///   own last writes, so a cloud value that differs came from another TV later.
    ///   On `turnOn` too: the second TV switched on used to push its own lineup and
    ///   overwrite the first TV's (seen on hardware, 2026-10-13). The first TV to turn
    ///   sync on finds iCloud empty and seeds it; every TV after that joins.
    /// - cloud-empty, local present: push local (launch, account change and turn-on
    ///   only; an external change that removes a key never clears this TV's choice).
    /// - Ids are taken verbatim. A collection or bundle id this TV's server does not
    ///   have is kept in the set and simply matches nothing here.
    static func plan(local: [String: Any], cloud: [String: Any], keys: [String], trigger: Trigger) -> Plan {
        var plan = Plan()
        let considered: [String]
        switch trigger {
        case .launch, .accountChange, .turnOn:
            considered = keys
        case .external(let changed):
            considered = keys.filter { changed.contains($0) }
        }
        for key in considered {
            let l = local[key].flatMap { normalized($0, for: key) }
            let c = cloud[key].flatMap { normalized($0, for: key) }
            if let c {
                if let l, isEqual(l, c) { continue }
                plan.applyLocally[key] = c
            } else if let l {
                if case .external = trigger { continue }
                plan.pushToCloud[key] = l
            }
        }
        return plan
    }

    /// Returns the value in canonical form, or nil if it is the wrong type or unusable.
    /// String arrays come back sorted so two TVs that hold the same set compare equal.
    static func normalized(_ value: Any, for key: String) -> Any? {
        switch PreferenceSync.kind(of: key) {
        case .stringSet(let allowEmpty):
            guard let arr = value as? [String] else { return nil }
            let set = Array(Set(arr.filter { !$0.isEmpty })).sorted()
            if set.isEmpty && !allowEmpty { return nil }
            return set
        case .bool:
            if let b = value as? Bool { return b }
            if let n = value as? NSNumber { return n.boolValue }
            return nil
        case .string:
            guard let s = value as? String, !s.isEmpty else { return nil }
            return s
        case nil:
            return nil
        }
    }

    static func isEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (x as [String], y as [String]): return Set(x) == Set(y)
        case let (x as Bool, y as Bool): return x == y
        case let (x as String, y as String): return x == y
        default: return false
        }
    }
}

/// Mirrors every Settings choice (lineup, Retro Mode, guide text size, stream quality,
/// subtitles, audio, Report Playback) to iCloud key-value storage so every Apple TV on
/// the same Apple ID is set up the same way.
///
/// Sync is off until the viewer turns it on in Settings (`syncEnabledKey`, a per-TV
/// flag that is never itself synced). While it is off nothing is read from or written
/// to the ubiquitous store, and launch neither pulls nor seeds.
///
/// Only the keys in `syncedKeys` ever reach iCloud. Server addresses, tokens, user ids
/// and everything in the Keychain stay on the device, as do the sync switch itself and
/// caches (scan dates, snapshots, manifests).
@MainActor
final class PreferenceSync {
    enum ValueKind: Equatable {
        case stringSet(allowEmpty: Bool)
        case bool
        case string
    }

    /// Per-device switch. Lives in UserDefaults only; never goes to iCloud.
    nonisolated static let syncEnabledKey = "nostalgex_icloud_sync_enabled"

    nonisolated static let enabledBundlesKey = "nostalgex_enabled_bundles"
    nonisolated static let enabledCollectionsKey = "nostalgex_enabled_collections"
    nonisolated static let enabledFranchisesKey = "nostalgex_enabled_franchises"
    /// Explicit offs, so a default-on franchise (STAR TREK) the viewer removed stays
    /// removed on every TV. See `FranchiseDictionary.isOn`.
    nonisolated static let disabledFranchisesKey = "nostalgex_disabled_franchises"
    nonisolated static let retroModeKey = "nostalgex_retro_mode"
    nonisolated static let guideTextSizeKey = GuideTextSize.storageKey
    nonisolated static let subtitlesFullscreenKey = "nostalgex_subtitles_fullscreen"
    nonisolated static let autoSubsForeignAudioKey = "nostalgex_auto_subs_foreign_audio"
    nonisolated static let subtitleLanguageKey = "nostalgex_subtitle_language"
    nonisolated static let audioLanguageKey = "nostalgex_audio_language"
    nonisolated static let streamQualityKey = StreamQuality.storageKey
    nonisolated static let reportPlaybackKey = PlaybackReportingPreferences.legacyKey
    nonisolated static let nowPlayingKey = PlaybackReportingPreferences.nowPlayingKey
    nonisolated static let markWatchedKey = PlaybackReportingPreferences.markWatchedKey

    nonisolated static let syncedKeys: [String] = [
        enabledBundlesKey,
        enabledCollectionsKey,
        enabledFranchisesKey,
        disabledFranchisesKey,
        retroModeKey,
        guideTextSizeKey,
        subtitlesFullscreenKey,
        autoSubsForeignAudioKey,
        subtitleLanguageKey,
        audioLanguageKey,
        streamQualityKey,
        reportPlaybackKey,
        nowPlayingKey,
        markWatchedKey,
    ]

    nonisolated static func kind(of key: String) -> ValueKind? {
        switch key {
        case enabledBundlesKey: return .stringSet(allowEmpty: false)   // never an empty lineup
        case enabledCollectionsKey, enabledFranchisesKey, disabledFranchisesKey: return .stringSet(allowEmpty: true)
        case retroModeKey, subtitlesFullscreenKey, autoSubsForeignAudioKey, reportPlaybackKey, nowPlayingKey, markWatchedKey: return .bool
        case subtitleLanguageKey, audioLanguageKey, streamQualityKey, guideTextSizeKey: return .string
        default: return nil
        }
    }

    static let shared: PreferenceSync = {
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let store: UbiquitousKeyValueStoring = underTests ? InMemoryKeyValueStore() : NSUbiquitousKeyValueStore.default
        return PreferenceSync(cloud: store, defaults: .standard, observeNotifications: !underTests)
    }()

    let cloud: UbiquitousKeyValueStoring
    let defaults: UserDefaults
    weak var applier: PreferenceSyncApplying?

    /// The keys this instance syncs. Normally `syncedKeys`; a DEBUG launch argument can
    /// narrow it for hardware tests (see `debugKeyFilter`).
    private(set) var activeKeys: [String]

    /// True while incoming values are being written, so the `didSet`s that fire as a
    /// result do not echo them straight back to iCloud.
    private(set) var isApplyingRemote = false

    /// A brand-new TV (nothing local, nothing cloud yet) holds its outgoing writes until
    /// iCloud has had a chance to deliver the household's values, so the defaults an
    /// empty install writes on first load never overwrite the lineup other TVs set up.
    private(set) var holdingOutgoing = false
    private var pendingKeys: [String] = []
    private var holdReleaseTask: Task<Void, Never>?
    nonisolated static let holdTimeoutSeconds: UInt64 = 30

    /// The viewer's per-TV choice. Read from `defaults` at init; changed through
    /// `setEnabled`. Nothing touches `cloud` while this is false.
    private(set) var isEnabled: Bool

    private var didBootstrap = false
    private let observesNotifications: Bool
    private var observer: NSObjectProtocol?

    init(cloud: UbiquitousKeyValueStoring, defaults: UserDefaults, observeNotifications: Bool, keys: [String]? = nil) {
        self.cloud = cloud
        self.defaults = defaults
        self.activeKeys = keys ?? Self.debugKeyFilter() ?? Self.syncedKeys
        self.observesNotifications = observeNotifications
        self.isEnabled = defaults.bool(forKey: Self.syncEnabledKey)
        if isEnabled { startObserving() }
    }

    private func startObserving() {
        guard observesNotifications, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud as? NSUbiquitousKeyValueStore,
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated {
                self?.handleExternalChange(reason: reason, changedKeys: keys)
            }
        }
    }

    private func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // MARK: - On / off

    /// Turning on adopts what iCloud already holds (another TV's lineup), pushes the
    /// keys iCloud has no value for yet, then starts listening.
    /// Turning off stops listening and leaves both iCloud and the local values as they are.
    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        defaults.set(on, forKey: Self.syncEnabledKey)
        guard on else {
            stopObserving()
            holdReleaseTask?.cancel()
            holdReleaseTask = nil
            holdingOutgoing = false
            pendingKeys = []
            print("[Sync] turned off: iCloud values left as they are")
            return
        }
        cloud.synchronize()
        let local = localValues()
        let remote = cloudValues()
        print("[Sync] turned on: local \(Self.describe(local)) cloud \(Self.describe(remote))")
        let plan = PreferenceSyncMerge.plan(local: local, cloud: remote, keys: activeKeys, trigger: .turnOn)
        push(plan.pushToCloud, label: "turned on")
        apply(plan.applyLocally)
        startObserving()
    }

    // MARK: - Launch

    /// Call once before `AppState` is created. Pulls whatever iCloud has into
    /// UserDefaults so AppState's initial reads see the household's values, and seeds
    /// iCloud with any local values it lacks. A no-op while sync is off.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        guard isEnabled else {
            print("[Sync] launch: sync is off on this TV, iCloud untouched")
            return
        }
        cloud.synchronize()
        // tvOS has no iCloud Drive, so this token can be nil even when the TV is signed
        // into iCloud and key-value sync works. Logged as a hint, not a verdict.
        let hasToken = FileManager.default.ubiquityIdentityToken != nil
        print("[Sync] launch: ubiquity token \(hasToken ? "present" : "nil"), keys \(activeKeys.count)")

        let local = localValues()
        let remote = cloudValues()
        print("[Sync] launch: local \(Self.describe(local)) cloud \(Self.describe(remote))")
        if local.isEmpty && remote.isEmpty && !activeKeys.isEmpty {
            startHolding()
        }
        let plan = PreferenceSyncMerge.plan(local: local, cloud: remote, keys: activeKeys, trigger: .launch)
        for (key, value) in plan.applyLocally {
            defaults.set(value, forKey: key)
            print("[Sync] in (launch) \(key)=\(Self.describe(value))")
        }
        push(plan.pushToCloud, label: "launch seed")
    }

    // MARK: - Outgoing

    /// Called from the `didSet`/save paths of the synced AppState properties, after the
    /// value has been written to UserDefaults.
    func record(_ key: String, value: Any) {
        guard activeKeys.contains(key) else {
            if !Self.syncedKeys.contains(key) {
                print("[Sync] refused to sync \(key): not a synced preference")
            }
            return
        }
        guard isEnabled, !isApplyingRemote else { return }
        guard let normalized = PreferenceSyncMerge.normalized(value, for: key) else { return }
        if holdingOutgoing {
            if !pendingKeys.contains(key) { pendingKeys.append(key) }
            print("[Sync] out held (waiting for iCloud) \(key)=\(Self.describe(normalized))")
            return
        }
        if let existing = cloud.object(forKey: key).flatMap({ PreferenceSyncMerge.normalized($0, for: key) }),
           PreferenceSyncMerge.isEqual(existing, normalized) {
            return
        }
        cloud.set(normalized, forKey: key)
        print("[Sync] out \(key)=\(Self.describe(normalized))")
    }

    private func push(_ values: [String: Any], label: String) {
        guard !values.isEmpty else { return }
        for key in values.keys.sorted() {
            cloud.set(values[key], forKey: key)
            print("[Sync] out (\(label)) \(key)=\(Self.describe(values[key]!))")
        }
        cloud.synchronize()
    }

    private func startHolding() {
        holdingOutgoing = true
        print("[Sync] new TV with nothing in iCloud yet: holding writes up to \(Self.holdTimeoutSeconds)s")
        holdReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.holdTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.releaseHold(reason: "timeout")
        }
    }

    private func releaseHold(reason: String) {
        guard holdingOutgoing else { return }
        holdingOutgoing = false
        holdReleaseTask?.cancel()
        holdReleaseTask = nil
        let keys = pendingKeys
        pendingKeys = []
        print("[Sync] hold released (\(reason)), \(keys.count) pending")
        var values: [String: Any] = [:]
        for key in keys where cloud.object(forKey: key) == nil {
            if let v = defaults.object(forKey: key).flatMap({ PreferenceSyncMerge.normalized($0, for: key) }) {
                values[key] = v
            }
        }
        push(values, label: "after hold")
    }

    // MARK: - Incoming

    func handleExternalChange(reason: Int?, changedKeys: [String]) {
        guard isEnabled else {
            print("[Sync] in notification ignored: sync is off on this TV")
            return
        }
        let reasonName: String
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange: reasonName = "server change"
        case NSUbiquitousKeyValueStoreInitialSyncChange: reasonName = "initial sync"
        case NSUbiquitousKeyValueStoreQuotaViolationChange: reasonName = "quota violation"
        case NSUbiquitousKeyValueStoreAccountChange: reasonName = "account change"
        default: reasonName = "unknown (\(reason.map(String.init) ?? "nil"))"
        }
        print("[Sync] in notification: \(reasonName), keys \(changedKeys)")

        let trigger: PreferenceSyncMerge.Trigger
        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            print("[Sync] iCloud key-value quota exceeded; nothing applied")
            return
        case NSUbiquitousKeyValueStoreAccountChange:
            trigger = .accountChange
        default:
            trigger = .external(changedKeys: changedKeys)
        }
        let plan = PreferenceSyncMerge.plan(local: localValues(), cloud: cloudValues(), keys: activeKeys, trigger: trigger)
        apply(plan.applyLocally)
        if trigger == .accountChange { push(plan.pushToCloud, label: "account change") }
        releaseHold(reason: reasonName)
    }

    /// Writes incoming values to UserDefaults and AppState without echoing them back.
    func apply(_ values: [String: Any]) {
        guard !values.isEmpty else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for key in values.keys.sorted() {
            defaults.set(values[key], forKey: key)
            print("[Sync] in \(key)=\(Self.describe(values[key]!))")
        }
        applier?.applyIncomingPreferences(values)
    }

    // MARK: - Helpers

    func localValues() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in activeKeys {
            if let v = defaults.object(forKey: key).flatMap({ PreferenceSyncMerge.normalized($0, for: key) }) {
                out[key] = v
            }
        }
        return out
    }

    func cloudValues() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in activeKeys {
            if let v = cloud.object(forKey: key).flatMap({ PreferenceSyncMerge.normalized($0, for: key) }) {
                out[key] = v
            }
        }
        return out
    }

    nonisolated static func describe(_ value: Any) -> String {
        if let dict = value as? [String: Any] {
            if dict.isEmpty { return "{}" }
            return "{" + dict.keys.sorted().map { "\($0.replacingOccurrences(of: "nostalgex_", with: ""))=\(describe(dict[$0]!))" }.joined(separator: ", ") + "}"
        }
        if let arr = value as? [String] { return "[\(arr.count) ids]" }
        return "\(value)"
    }

    /// DEBUG only: `-NostalgexSyncOnly <key>` narrows syncing to one key (or `none`) so a
    /// hardware test can prove the round trip without converging every preference on
    /// the test TVs.
    private static func debugKeyFilter() -> [String]? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-NostalgexSyncOnly"), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        if value == "none" { return [] }
        return syncedKeys.filter { value.split(separator: ",").map(String.init).contains($0) }
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// Removes every synced key from iCloud without touching this TV's preferences.
    /// Only reaches iCloud when sync is on; the probe turns it on first if it needs to.
    func debugClearCloud() {
        guard isEnabled else {
            print("[Sync] probe: sync is off, nothing cleared")
            return
        }
        for key in Self.syncedKeys where cloud.object(forKey: key) != nil {
            cloud.removeObject(forKey: key)
            print("[Sync] probe: removed \(key) from iCloud")
        }
        cloud.synchronize()
    }
    #endif
}
