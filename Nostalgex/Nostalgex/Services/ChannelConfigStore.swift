import Foundation

/// Live channel rules (Trello N-074). The guide is built from the channels.json on nostalgex.app when a good
/// copy has been fetched, so a fix to a channel's rules reaches Apple TVs without an App Store build.
///
/// - Fetched at launch (when the kept copy is missing or a day old) and about every 24 hours after.
/// - Parsed by the same `ChannelConfigLoader` as the bundled file, and kept only when it passes `verdict`:
///   it parses, it has channels, its optional `formatVersion` is at most 1 (missing counts as 1), and its
///   content `version` is not older than the copy this build carries. The same rule as Android and Roku.
/// - The last good copy is kept in the app's caches (`LocalStore`). A bad download never replaces it.
/// - Built from: the kept copy if it still passes, else the bundled one.
/// - Applied only where the guide is rebuilt anyway (`loadLibrary`, a snapshot restore); a fetch writes the
///   file and nothing else, so a new copy never lands mid-programme.
///
/// channels.json has no `formatVersion` today (live is content `version` 50). It is read so a future format
/// change can go to the site without breaking the builds already out there.
enum ChannelConfigStore {
    static let liveURL = URL(string: "https://www.nostalgex.app/channels.json")!
    /// The newest channels.json format this build reads.
    static let maxFormatVersion = 1
    /// How soon a new channels.json can be noticed: the check runs at launch, on return to the foreground and from the
    /// 15 minute background loop, but never more than once in this long. An unchanged file is a 304 (ETag), so the
    /// check itself costs almost nothing. The one number to change (Chad, 2026-11-16: "sooner than 24 hours").
    static let checkInterval: TimeInterval = 3600
    /// A background refresh (a kept copy exists, nothing waits on it).
    static let timeout: TimeInterval = 10
    /// A fetch the launch waits on, because there is no kept copy yet (a first install): short, so a slow or
    /// missing network costs onboarding no more than this and the bundled copy is used.
    static let blockingTimeout: TimeInterval = 3
    static let lastFetchKey = "nostalgex_live_config_fetched_at"
    static let etagKey = "nostalgex_live_config_etag"
    static let appliedVersionKey = "nostalgex_channels_applied_version"

    static var cacheURL: URL? { LocalStore.rootDirectory?.appendingPathComponent("channels-live.json") }

    enum Verdict: Equatable {
        case accepted(version: Int)
        case invalid
        case noChannels
        case olderThanBundled(live: Int, bundled: Int)
        case unsupportedFormat(Int)
    }

    private struct Header: Decodable {
        let version: Int?
        let formatVersion: Int?
    }

    /// Whether a downloaded or kept channels.json may be built from.
    static func verdict(for data: Data, bundledVersion: Int, appVersion: String) -> Verdict {
        guard let header = try? JSONDecoder().decode(Header.self, from: data), let version = header.version else { return .invalid }
        let format = header.formatVersion ?? 1
        guard format <= maxFormatVersion else { return .unsupportedFormat(format) }
        guard let result = ChannelConfigLoader.loadConfig(from: data) else { return .invalid }
        guard !result.channels.isEmpty else { return .noChannels }
        guard version >= bundledVersion else { return .olderThanBundled(live: version, bundled: bundledVersion) }
        return .accepted(version: version)
    }

    /// "1.0.34" newer than "1.0.33"; missing parts count as 0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static func bundledData() -> Data? {
        guard let url = Bundle.main.url(forResource: "channels", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    static func version(of data: Data?) -> Int {
        guard let data, let h = try? JSONDecoder().decode(Header.self, from: data) else { return 0 }
        return h.version ?? 0
    }

    struct Active {
        let result: ChannelConfigResult
        let data: Data?
        /// "live" or "bundled", for the log.
        let source: String
        /// The content `version` of what the guide is built from.
        var version: Int { ChannelConfigStore.version(of: data) }
    }

    /// The config the guide is built from: the kept live copy when it still passes, else the bundled one.
    static func active(bundled: Data? = bundledData(), cached: Data? = cacheURL.flatMap { try? Data(contentsOf: $0) },
                       appVersion: String = appVersion) -> Active {
        let bundledVersion = version(of: bundled)
        if let cached, case .accepted = verdict(for: cached, bundledVersion: bundledVersion, appVersion: appVersion),
           let result = ChannelConfigLoader.loadConfig(from: cached) {
            return Active(result: result, data: cached, source: "live")
        }
        if let bundled, let result = ChannelConfigLoader.loadConfig(from: bundled) {
            return Active(result: result, data: bundled, source: "bundled")
        }
        return Active(result: ChannelConfigResult(channels: [], bundles: [], exclusiveRules: []), data: nil, source: "none")
    }

    /// The kept copy is missing, or the last check was `checkInterval` ago or more.
    static func isDue(now: Date = Date(), defaults: UserDefaults = AppDefaults.standard) -> Bool {
        let cachedExists = cacheURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return isCheckDue(lastCheck: defaults.double(forKey: lastFetchKey), keptCopyExists: cachedExists, now: now)
    }

    static func isCheckDue(lastCheck: TimeInterval, keptCopyExists: Bool, now: Date) -> Bool {
        !keptCopyExists || lastCheck <= 0 || now.timeIntervalSince1970 - lastCheck >= checkInterval
    }

    /// The version the guide in memory was last built from. Never stored on an install that predates this: then it is
    /// the bundled copy's, so an app update with newer bundled rules does not force a rebuild, and a live copy newer
    /// than the bundled one is applied once.
    static func appliedVersion(defaults: UserDefaults = AppDefaults.standard, bundledVersion: Int) -> Int {
        let v = defaults.integer(forKey: appliedVersionKey)
        return v > 0 ? v : bundledVersion
    }

    static func recordApplied(version: Int, defaults: UserDefaults = AppDefaults.standard) {
        defaults.set(version, forKey: appliedVersionKey)
    }

    /// A check already running (a launch and a foreground return can land together).
    private static let inFlight = NSLock()
    nonisolated(unsafe) private static var checking = false

    /// What a finished download does to the kept copy: a passing file replaces it, anything else leaves it.
    /// Returns the verdict for the log and the tests.
    @discardableResult
    static func store(downloaded data: Data, bundledVersion: Int, appVersion: String, to url: URL?) -> Verdict {
        let v = verdict(for: data, bundledVersion: bundledVersion, appVersion: appVersion)
        if case .accepted = v, let url {
            try? data.write(to: url, options: .atomic)
        }
        return v
    }

    /// The request: conditional when a kept copy came with an ETag, so an unchanged file answers 304 with no body.
    static func request(etag: String?, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: liveURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return req
    }

    /// Asks nostalgex.app for channels.json and keeps it when it passes. Never throws, never waits longer than
    /// `timeout`. Tests never reach the network: XCTest runs keep the bundled rules. The ETag is sent only while
    /// a kept copy exists to go with it, and kept only for a copy that passed.
    static func refresh(session: URLSession = .shared, timeout: TimeInterval = ChannelConfigStore.timeout) async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        inFlight.lock()
        if checking { inFlight.unlock(); return }
        checking = true
        inFlight.unlock()
        defer { inFlight.lock(); checking = false; inFlight.unlock() }
        let keptCopyExists = cacheURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let etag = keptCopyExists ? AppDefaults.standard.string(forKey: etagKey) : nil
        do {
            let (data, response) = try await session.data(for: request(etag: etag, timeout: timeout))
            let http = response as? HTTPURLResponse
            AppDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastFetchKey)
            if http?.statusCode == 304 {
                print("[Plex90] CONFIG: live channels.json unchanged (304)")
                return
            }
            guard http?.statusCode == 200 else {
                print("[Plex90] CONFIG: live channels.json answered \(http?.statusCode ?? 0), keeping what we have")
                return
            }
            let v = store(downloaded: data, bundledVersion: version(of: bundledData()), appVersion: appVersion, to: cacheURL)
            if case .accepted = v {
                AppDefaults.standard.set(http?.value(forHTTPHeaderField: "ETag"), forKey: etagKey)
            }
            print("[Plex90] CONFIG: live channels.json \(v)")
        } catch {
            // Offline or slow: the next check is an hour away, not at the next foreground return.
            AppDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastFetchKey)
            print("[Plex90] CONFIG: live channels.json failed: \(error.localizedDescription), keeping what we have")
        }
    }
}
