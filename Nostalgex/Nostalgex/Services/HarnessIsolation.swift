import Foundation

/// The app's UserDefaults. Every setting, counter and flag the app keeps goes through here
/// rather than `UserDefaults.standard`, so a DEBUG test harness can point the whole app at
/// a suite of its own (`HarnessIsolation`). A release build always gets `.standard`.
enum AppDefaults {
    #if DEBUG
    nonisolated(unsafe) static var override: UserDefaults?
    static var standard: UserDefaults { override ?? .standard }
    #else
    static var standard: UserDefaults { .standard }
    #endif
}

#if DEBUG
/// Storage isolation for test harnesses that drive the real app on a real Apple TV
/// (N-033). While active, everything the app persists goes under one harness root and one
/// UserDefaults suite, and nothing reaches the app's real stores:
///
/// - files: `LocalStore.rootDirectory` (library snapshot, daily manifests, music cache,
///   install stamp, soak files) and the Top Shelf snapshot live under the harness root;
/// - settings: `AppDefaults.standard` is a suite named after the harness;
/// - credentials: `KeychainService` keeps them in memory, never in the Keychain;
/// - iCloud: `PreferenceSync.shared` uses an in-memory store (it already does under XCTest).
///
/// Two ways in. A harness test calls `activate(name:)` and `deactivate()` around its run.
/// For a device run, `TEST_RUNNER_NOSTALGEX_HARNESS_ROOT=<name>` makes the test host app
/// activate it as the very first thing it does, before it reads a setting or a sign-in, so
/// the host's own launch (which would otherwise restore the real snapshot and load the real
/// library) runs isolated too.
enum HarnessIsolation {
    static let environmentKey = "NOSTALGEX_HARNESS_ROOT"
    /// The real root's sibling, so the real stores (`Caches/Nostalgex`) never contain it.
    static let containerName = "NostalgexHarness"

    nonisolated(unsafe) private(set) static var root: URL?
    nonisolated(unsafe) private(set) static var suiteName: String?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memoryCredentials: [String: String] = [:]
    nonisolated(unsafe) private static var previousURLCache: URLCache?

    static var isActive: Bool { root != nil }

    /// Called first in `NostalgexApp.init`. Does nothing unless the environment asks.
    static func activateFromEnvironmentIfRequested() {
        guard let name = ProcessInfo.processInfo.environment[environmentKey], !name.isEmpty else { return }
        activate(name: name)
    }

    /// Points the app's stores at `Caches/NostalgexHarness/<name>` and the suite
    /// `nostalgex.harness.<name>`. Returns the root.
    @discardableResult
    static func activate(name: String) -> URL {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent(containerName, isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "nostalgex.harness." + safe
        lock.lock()
        root = dir
        suiteName = suite
        memoryCredentials = [:]
        lock.unlock()
        AppDefaults.override = UserDefaults(suiteName: suite)
        // Every URLSession made from here on caches in memory only, so no response, and no
        // cache lookup, touches the app's real Caches/<bundle id> HTTP cache.
        if previousURLCache == nil { previousURLCache = URLCache.shared }
        URLCache.shared = URLCache(memoryCapacity: 8 * 1_048_576, diskCapacity: 0)
        return dir
    }

    /// Back to the real stores. `wipe` deletes the harness root and its suite.
    static func deactivate(wipe: Bool) {
        lock.lock()
        let dir = root
        let suite = suiteName
        root = nil
        suiteName = nil
        memoryCredentials = [:]
        lock.unlock()
        AppDefaults.override = nil
        if let previousURLCache { URLCache.shared = previousURLCache }
        previousURLCache = nil
        guard wipe else { return }
        if let suite {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Where `LocalStore` keeps files while active.
    static var localStoreRoot: URL? { root?.appendingPathComponent("Nostalgex", isDirectory: true) }

    /// Where the Top Shelf snapshot goes while active, in place of the App Group container.
    static var topShelfContainer: URL? { root?.appendingPathComponent("AppGroup", isDirectory: true) }

    // MARK: Credentials, in memory while active

    static func saveCredential(key: String, value: String) {
        lock.lock(); memoryCredentials[key] = value; lock.unlock()
    }

    static func loadCredential(key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return memoryCredentials[key]
    }

    static func deleteCredential(key: String) {
        lock.lock(); memoryCredentials[key] = nil; lock.unlock()
    }
}
#endif
