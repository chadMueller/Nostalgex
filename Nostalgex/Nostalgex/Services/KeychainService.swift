import Foundation
import Security
import os

/// Keychain wrapper for credentials (Plex token, server URL, server list).
///
/// A sign-in is written to the keychain once and then left alone. Writes are in-place
/// updates, never delete-then-add, so a crash or force quit mid-write cannot leave a gap.
/// Every value is also mirrored into the app's own container as a last resort: the
/// keychain has dropped sign-ins in the field for reasons no log ever captured, and on
/// tvOS (no user-visible filesystem, no backups the user can browse) the mirror's exposure
/// is negligible next to the cost of asking someone to sign in again.
enum KeychainService {
    private static let serviceName = "com.muellhaus.nostalgex"

    /// Set when a write could not be read back anywhere. Surfaced so a session that will
    /// not survive relaunch is diagnosable rather than silently costing the user their sign-in.
    static let writeVerificationFailedKey = "nostalgex_keychain_write_unverified"

    private static func deviceLocalTwin(_ key: String) -> String { key + ".device_local" }
    private static func mirrorKey(_ key: String) -> String { "nostalgex_credential_mirror." + key }

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        #if DEBUG
        if HarnessIsolation.isActive { HarnessIsolation.saveCredential(key: key, value: value); return true }
        #endif
        let primaryOK = writeInPlace(account: key, value: value,
                                     accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                     label: "AfterFirstUnlock")
        let twinOK = writeInPlace(account: deviceLocalTwin(key), value: value,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  label: "ThisDeviceOnly twin")
        AppDefaults.standard.set(value, forKey: mirrorKey(key))
        let mirrorOK = AppDefaults.standard.string(forKey: mirrorKey(key)) == value

        if primaryOK || twinOK || mirrorOK {
            AppDefaults.standard.removeObject(forKey: writeVerificationFailedKey)
            return true
        }
        AppDefaults.standard.set(true, forKey: writeVerificationFailedKey)
        InstallDiagnostics.log.error("keychain: nothing could persist \(key, privacy: .public)")
        return false
    }

    private static func writeInPlace(account: String, value: String,
                                     accessibility: CFString, label: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        if loadRaw(account: account) == value { return true }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibility
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            InstallDiagnostics.log.error("keychain: save failed \(account, privacy: .public) \(label, privacy: .public) status \(status)")
            return false
        }
        if loadRaw(account: account) == value { return true }
        print("[Keychain] Wrote \(account) using \(label) but could not read it back")
        return false
    }

    static func load(key: String) -> String? {
        #if DEBUG
        if HarnessIsolation.isActive { return HarnessIsolation.loadCredential(key: key) }
        #endif
        if let value = loadRaw(account: key, recordAs: key) {
            backfillMirror(key: key, value: value)
            return value
        }
        if let twin = loadRaw(account: deviceLocalTwin(key)) {
            InstallDiagnostics.log.notice("keychain: primary missing \(key, privacy: .public), served by twin")
            backfillMirror(key: key, value: twin)
            return twin
        }
        if let mirror = AppDefaults.standard.string(forKey: mirrorKey(key)) {
            InstallDiagnostics.log.notice("keychain: missing \(key, privacy: .public) entirely, served by mirror")
            return mirror
        }
        return nil
    }

    /// Installs that signed in before the mirror existed get one on their next launch, so
    /// the next keychain drop is covered without asking anyone to sign in again.
    private static func backfillMirror(key: String, value: String) {
        if AppDefaults.standard.string(forKey: mirrorKey(key)) != value {
            AppDefaults.standard.set(value, forKey: mirrorKey(key))
        }
    }

    private static func loadRaw(account: String, recordAs statusKey: String? = nil) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if let statusKey { recordLoadStatus(status, for: statusKey) }

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                InstallDiagnostics.log.error("keychain: load failed \(account, privacy: .public) status \(status)")
            }
            return nil
        }
        return string
    }

    /// Last observed SecItemCopyMatching status per key, persisted so the connect screen
    /// can say WHY a sign-in vanished instead of needing a debugger attached on a hotel TV.
    /// -25300 = item gone (purged or never written), -25308 = keychain not ready yet,
    /// -34018 = missing entitlement (simulator artifact).
    static let loadStatusesKey = "nostalgex_keychain_load_statuses"

    private static func recordLoadStatus(_ status: OSStatus, for key: String) {
        var dict = AppDefaults.standard.dictionary(forKey: loadStatusesKey) as? [String: Int] ?? [:]
        dict[key] = Int(status)
        AppDefaults.standard.set(dict, forKey: loadStatusesKey)
    }

    static func lastLoadStatuses() -> [String: Int] {
        AppDefaults.standard.dictionary(forKey: loadStatusesKey) as? [String: Int] ?? [:]
    }

    /// Statuses worth retrying shortly after launch rather than concluding the sign-in is
    /// gone: the keychain can refuse reads for a beat while the device finishes waking.
    static func isTransientLoadStatus(_ status: Int) -> Bool {
        status == Int(errSecInteractionNotAllowed) || status == -34018
    }

    static func delete(key: String) {
        #if DEBUG
        if HarnessIsolation.isActive { HarnessIsolation.deleteCredential(key: key); return }
        #endif
        for account in [key, deviceLocalTwin(key)] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
        AppDefaults.standard.removeObject(forKey: mirrorKey(key))
    }
}
