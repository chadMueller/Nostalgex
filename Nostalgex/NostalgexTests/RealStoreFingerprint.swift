import Foundation
import CryptoKit
import Security
@testable import Nostalgex

/// A byte-level fingerprint of everything the app keeps for its real user, read from the
/// real locations directly (never through `LocalStore` or `AppDefaults`, which a harness
/// redirects). Two captures around a harness run must be equal: that is the proof the run
/// left the real stores alone.
///
/// App-owned (compared, and a difference fails the proof):
/// - `Library/Caches/Nostalgex/**`: library snapshot, daily manifests, music cache, soak files;
/// - `Library/Caches/<bundle id>/**`: the URL loading system's HTTP cache;
/// - the App Group's `Library/Caches/**`: the Top Shelf snapshot;
/// - the app's UserDefaults domain, as a sorted XML property list;
/// - the app's Keychain items (service `com.muellhaus.nostalgex`), data hashed;
/// - iCloud key-value store, as the app sees it.
///
/// Everything else under the container (Documents, the rest of Library, tmp) is listed too,
/// but only reported: the system writes there on its own (UI snapshots, for one).
struct RealStoreFingerprint: Equatable {
    var appFiles: [String: String] = [:]
    var otherFiles: [String: String] = [:]
    var defaults = Data()
    var keychain: [String: String] = [:]
    var keychainStatus: OSStatus = 0
    var kvs = Data()

    static let keychainService = "com.muellhaus.nostalgex"

    static func == (a: Self, b: Self) -> Bool {
        a.appFiles == b.appFiles && a.defaults == b.defaults && a.keychain == b.keychain
            && a.keychainStatus == b.keychainStatus && a.kvs == b.kvs
    }

    static func capture() -> RealStoreFingerprint {
        var fp = RealStoreFingerprint()
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.muellhaus.nostalgex"

        var appRoots: [(String, URL)] = [
            ("caches/Nostalgex", caches.appendingPathComponent("Nostalgex", isDirectory: true)),
            ("caches/\(bundleID)", caches.appendingPathComponent(bundleID, isDirectory: true)),
        ]
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: TopShelfStore.appGroupID) {
            appRoots.append(("group/Library/Caches", group.appendingPathComponent("Library/Caches", isDirectory: true)))
        }
        for (label, root) in appRoots {
            hashTree(root, label: label, into: &fp.appFiles)
        }
        // The rest of the container, minus the harness's own root and suite, for the report.
        var other: [String: String] = [:]
        hashTree(home, label: "home", into: &other)
        let skip = ["home/Library/Caches/Nostalgex/", "home/Library/Caches/\(bundleID)/",
                    "home/Library/Caches/\(HarnessIsolation.containerName)/",
                    "home/Library/Preferences/nostalgex.harness.", "home/Library/Preferences/\(bundleID).plist"]
        fp.otherFiles = other.filter { key, _ in !skip.contains { key.hasPrefix($0) } }

        let domain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        fp.defaults = (try? PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)) ?? Data()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        fp.keychainStatus = SecItemCopyMatching(query as CFDictionary, &result)
        for item in (result as? [[String: Any]]) ?? [] {
            let account = item[kSecAttrAccount as String] as? String ?? "?"
            let data = item[kSecValueData as String] as? Data ?? Data()
            let modified = (item[kSecAttrModificationDate as String] as? Date)?.timeIntervalSince1970 ?? 0
            fp.keychain[account] = sha(data) + "@\(modified)"
        }

        let kvs = NSUbiquitousKeyValueStore.default.dictionaryRepresentation
        fp.kvs = (try? PropertyListSerialization.data(fromPropertyList: kvs, format: .xml, options: 0)) ?? Data()
        return fp
    }

    /// One line per difference, app-owned first.
    func differences(from later: RealStoreFingerprint) -> (app: [String], other: [String]) {
        var app: [String] = []
        for key in Set(appFiles.keys).union(later.appFiles.keys).sorted() where appFiles[key] != later.appFiles[key] {
            app.append("file \(key): \(appFiles[key] ?? "absent") -> \(later.appFiles[key] ?? "absent")")
        }
        if defaults != later.defaults { app.append("UserDefaults domain changed (\(defaults.count) -> \(later.defaults.count) bytes)") }
        if keychain != later.keychain || keychainStatus != later.keychainStatus {
            app.append("Keychain changed (status \(keychainStatus) -> \(later.keychainStatus), \(keychain.count) -> \(later.keychain.count) items)")
        }
        if kvs != later.kvs { app.append("iCloud key-value store changed") }
        var other: [String] = []
        for key in Set(otherFiles.keys).union(later.otherFiles.keys).sorted() where otherFiles[key] != later.otherFiles[key] {
            other.append("\(key): \(otherFiles[key] ?? "absent") -> \(later.otherFiles[key] ?? "absent")")
        }
        return (app, other)
    }

    var summary: String {
        "appFiles=\(appFiles.count) defaultsBytes=\(defaults.count) keychainItems=\(keychain.count) (status \(keychainStatus)) kvsBytes=\(kvs.count) otherFiles=\(otherFiles.count)"
    }

    private static func hashTree(_ root: URL, label: String, into out: inout [String: String]) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [], errorHandler: { _, _ in true }) else { return }
        let base = root.standardizedFileURL.path
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count))
            let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
            out["\(label)\(rel.hasPrefix("/") ? rel : "/" + rel)"] = "\(data.count):\(sha(data))"
        }
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Isolation for one harness test: switches `HarnessIsolation` on unless the process
/// already has it (a device run turns it on at launch), and off again only if it did.
struct HarnessScope {
    let activatedHere: Bool

    static func begin(_ name: String) -> HarnessScope {
        guard !HarnessIsolation.isActive else { return HarnessScope(activatedHere: false) }
        HarnessIsolation.activate(name: name)
        return HarnessScope(activatedHere: true)
    }

    func end() {
        if activatedHere { HarnessIsolation.deactivate(wipe: true) }
    }
}
