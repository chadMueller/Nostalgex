import Foundation

/// Keeps the watchdog's last verdicts where a person can read them.
///
/// The watchdog prints exactly why it gave up on a stream — whether the item reached
/// ready, how far the playhead moved, whether a frame decoded, segment and stall counts,
/// HLS error codes — but only to stdout, which nothing sees on a television in someone's
/// basement. Chasing a restart loop on a 4K film took a day of server probes that all came
/// back clean, because the one line that would have said "device" or "server" was never
/// retrievable. Now each verdict also goes to the unified log (Console.app sees it over the
/// network) and the last few are stored so Settings can show them. Logging only: nothing
/// here changes what the player does.
enum PlaybackDiagnostics {
    private static let key = "nostalgex_playback_verdicts_v2"
    private static let legacyKey = "nostalgex_playback_verdicts"
    private static let keep = 5

    /// Record a watchdog or end-of-item decision. `outcome` is what the app did next.
    static func record(outcome: String, title: String, detail: String, defaults: UserDefaults = AppDefaults.standard) {
        defaults.removeObject(forKey: legacyKey)
        let stamp = Self.clock.string(from: Date())
        let line = "\(stamp) \(outcome): \"\(title)\", \(detail)"
        let safeLine = redactSensitiveText(line)
        InstallDiagnostics.note("WATCHDOG VERDICT: \(safeLine)")
        var rows = defaults.stringArray(forKey: key) ?? []
        rows.insert(safeLine, at: 0)
        if rows.count > keep { rows = Array(rows.prefix(keep)) }
        defaults.set(rows, forKey: key)
    }

    /// Newest first. Empty when playback has never been given up on.
    static func recent(defaults: UserDefaults = AppDefaults.standard) -> [String] {
        defaults.removeObject(forKey: legacyKey)
        return (defaults.stringArray(forKey: key) ?? []).map(redactSensitiveText)
    }

    /// The line Settings shows. Short enough to read from the couch, complete enough to
    /// tell a device problem from a server one.
    static func latestForSettings(defaults: UserDefaults = AppDefaults.standard) -> String? {
        recent(defaults: defaults).first
    }

    static func clear(defaults: UserDefaults = AppDefaults.standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    /// Error comments can embed full URLs, userinfo, query credentials, or header dumps.
    /// Strip those before either logging or persistence; never truncate a URL first.
    static func redactSensitiveText(_ text: String) -> String {
        var safe = text
        // Handle encoded URLs/query names from server and AVFoundation error messages.
        for _ in 0..<2 { safe = safe.removingPercentEncoding ?? safe }
        let patterns = [
            #"(?i)\b(?:https?|plex)://[^\s<>"']+"#,
            #"(?i)authorization["']?\s*[:=]\s*[^\r\n,]+"#,
            #"(?i)(?:x[-_]plex[-_]token|x[-_]emby[-_]token|access[-_]?token|api[-_]?key|token|password|secret)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s&,;]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            safe = regex.stringByReplacingMatches(in: safe, range: NSRange(safe.startIndex..., in: safe), withTemplate: "[redacted]")
        }
        return safe
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f
    }()
}
