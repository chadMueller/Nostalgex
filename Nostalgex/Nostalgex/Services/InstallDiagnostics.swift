import Foundation
import os

/// Answers one question when a sign-in vanishes: did the app's storage survive, or was
/// the whole container reset? Two independent witnesses are stamped on first launch —
/// a UserDefaults value and a file in Application Support. If both are fresh, the
/// container was recreated (reinstall). If the file is old but defaults are fresh,
/// UserDefaults is not persisting on this device. If both are old, storage held and
/// the credential itself was removed.
enum InstallDiagnostics {
    static let log = Logger(subsystem: "com.muellhaus.nostalgex", category: "auth")

    /// Unified log for Console.app plus stdout for an attached debugger or devicectl --console.
    static func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
        print("[Plex90] \(message)")
    }

    static func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        print("[Plex90] \(message)")
    }

    private static let firstRunKey = "nostalgex_first_run_at"
    private static let launchCountKey = "nostalgex_launch_count"

    private static var stampURL: URL? {
        LocalStore.rootDirectory?.appendingPathComponent("install.stamp")
    }

    /// The stamp file is the second witness LaunchGuard uses before treating a launch as a
    /// fresh install.
    static var installStampExists: Bool {
        stampURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Call once per process launch, before credentials are read.
    static func recordLaunch() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: firstRunKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: firstRunKey)
        }
        defaults.set(defaults.integer(forKey: launchCountKey) + 1, forKey: launchCountKey)
        if let url = stampURL, !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: url)
        }
        log.notice("launch \(summary(), privacy: .public)")
    }

    /// One line for the connect screen and the system log.
    static func summary() -> String {
        let defaults = UserDefaults.standard
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let firstRun = defaults.object(forKey: firstRunKey) as? Double
        let fileStamp = stampURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(Double.init)
        let launches = defaults.integer(forKey: launchCountKey)
        let statuses = KeychainService.lastLoadStatuses()
        let mirror = defaults.string(forKey: "nostalgex_credential_mirror.plex_token") != nil
        let marker = defaults.bool(forKey: "nostalgex_has_held_sign_in")
        return "B\(build) · DEFAULTS \(age(firstRun)) · FILE \(age(fileStamp)) · LAUNCH \(launches) · KC \(statuses["plex_token"].map(String.init) ?? "none") · MIRROR \(mirror ? "Y" : "N") · MARKER \(marker ? "Y" : "N")"
    }

    private static func age(_ epoch: Double?) -> String {
        guard let epoch else { return "none" }
        let minutes = Int(Date().timeIntervalSince1970 - epoch) / 60
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 48 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}
