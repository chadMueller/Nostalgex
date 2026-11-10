import Foundation

/// GUIDE TIMEOUT (Settings > PLAYBACK & PICTURE): after this long with no remote press on the
/// guide, the playing channel goes fullscreen.
///
/// The guide holds the Apple TV awake while its preview plays (`ScreenAwakePolicy`), so tvOS's
/// screensaver never starts there. Left alone, the logo, header and grid lines sit still on the
/// screen for hours, which can burn into an OLED. Fullscreen video keeps moving, so it doesn't.
///
/// Per Apple TV, like OPEN ON LAST CHANNEL: burn-in is a property of the screen, so iCloud never
/// carries it. Nothing saved, or anything unknown, is the default.
enum GuideTimeout: String, CaseIterable {
    case off
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"

    static let storageKey = "nostalgex_guide_timeout"
    /// The one line to change to make the guide stay up by default.
    static let defaultValue: GuideTimeout = .fiveMinutes

    init(stored: String?) {
        self = stored.flatMap(GuideTimeout.init(rawValue:)) ?? GuideTimeout.defaultValue
    }

    static func current(defaults: UserDefaults = AppDefaults.standard) -> GuideTimeout {
        GuideTimeout(stored: defaults.string(forKey: storageKey))
    }

    /// What the Settings row shows.
    var label: String {
        switch self {
        case .off: return "OFF"
        case .fiveMinutes: return "5 MIN"
        case .fifteenMinutes: return "15 MIN"
        }
    }

    /// The next choice when the row is selected: OFF, 5 MIN, 15 MIN, OFF.
    var next: GuideTimeout {
        let all = GuideTimeout.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Seconds, or nil for OFF. `-uiTestGuideTimeoutSeconds N` replaces any non-OFF value so a
    /// UI test can watch it fire without waiting five minutes.
    var interval: TimeInterval? {
        let base: TimeInterval
        switch self {
        case .off: return nil
        case .fiveMinutes: base = 5 * 60
        case .fifteenMinutes: base = 15 * 60
        }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uiTestGuideTimeoutSeconds"), i + 1 < args.count,
           let seconds = TimeInterval(args[i + 1]) {
            return seconds
        }
        return base
    }

    /// Whether the guide should hand over to fullscreen now. Only while the guide is the
    /// screen in front of the viewer and a channel is playing: Settings, the loading screen
    /// and an empty guide are left alone (tvOS's own screensaver covers a guide with nothing
    /// playing, because nothing holds the TV awake then).
    static func shouldGoFullscreen(
        interval: TimeInterval?,
        lastActivity: Date,
        now: Date,
        guideIsFrontmost: Bool,
        isPlaying: Bool
    ) -> Bool {
        guard let interval, guideIsFrontmost, isPlaying else { return false }
        return now.timeIntervalSince(lastActivity) >= interval
    }
}
