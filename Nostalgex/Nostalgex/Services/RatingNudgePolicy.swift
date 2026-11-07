import Foundation

/// Decides whether the "Enjoying Nostalgex?" banner may appear.
///
/// tvOS has no in-app review prompt (no `requestReview`, no `SKStoreReviewController`),
/// so the nudge is a quiet banner that links to the App Store product page. This type
/// holds every rule and no side effects, so the rules are unit tested directly.
///
/// The banner is only ever considered at one moment: when the viewer leaves fullscreen
/// and lands back on the guide. Everything else here is a gate on that moment.
enum RatingNudgePolicy {
    /// One continuous watch of a programme has to reach this to count as a viewing session.
    static let minimumSessionSeconds: Double = 10 * 60
    /// Qualifying sessions needed, cumulative across launches.
    static let requiredSessions = 3
    /// Untouched, the banner leaves on its own after this long: 8 s, or 12 s when the
    /// scroll hint is on, since there is a second line to read.
    static var autoDismissSeconds: Double { autoDismissSeconds(hintShown: showsScrollHint) }
    static func autoDismissSeconds(hintShown: Bool) -> Double { hintShown ? 12 : 8 }

    /// A second line on the banner and under the Settings RATE tile. On: tested on the
    /// living room Apple TV 2026-11-04, none of the write-review links (`AppStoreLink
    /// .RateLinkVariant` b, c, d) lands on the stars; every one opens the product page
    /// with focus on the download button and the stars below the fold. The line says so,
    /// and the banner stays up 12 s instead of 8 to be read.
    static let showsScrollHint = true
    static let scrollHint = "Then scroll down to the stars"

    /// Debug launch argument that skips the counters and gates. The banner still only
    /// appears on the exit from fullscreen to the guide.
    static let forceLaunchArgument = "-NostalgexForceRatingNudge"

    /// What survives between launches.
    struct Persisted: Equatable {
        var qualifyingSessions: Int = 0
        /// `CFBundleShortVersionString` the banner was last shown on, whatever the
        /// viewer chose.
        var lastShownVersion: String? = nil
        /// The viewer pressed RATE (banner or Settings). tvOS cannot tell us whether a
        /// rating was actually left, so the press is the best signal: never ask again.
        var rated: Bool = false
    }

    /// Facts about the current app launch only.
    struct Launch: Equatable {
        var appVersion: String
        var isFirstLaunch: Bool = false
        var hadPlaybackFailure: Bool = false
        var hadConnectError: Bool = false
        /// Already appeared during this launch (covers the forced path, which skips
        /// the per-version record).
        var shownThisLaunch: Bool = false
        var forced: Bool = false
    }

    static func countsAsViewingSession(watchedSeconds: Double) -> Bool {
        watchedSeconds >= minimumSessionSeconds
    }

    static func shouldShow(persisted: Persisted, launch: Launch) -> Bool {
        if launch.shownThisLaunch { return false }
        if launch.forced { return true }
        if persisted.rated { return false }
        if launch.isFirstLaunch { return false }
        if launch.hadPlaybackFailure || launch.hadConnectError { return false }
        if persisted.lastShownVersion == launch.appVersion { return false }
        return persisted.qualifyingSessions >= requiredSessions
    }
}

/// UserDefaults-backed counters for `RatingNudgePolicy`. UserDefaults rather than a
/// file: tvOS refuses writes to Application Support.
final class RatingNudgeStore {
    static let qualifyingSessionsKey = "nostalgex_rating_nudge_sessions"
    static let lastShownVersionKey = "nostalgex_rating_nudge_shown_version"
    static let hasLaunchedKey = "nostalgex_rating_nudge_has_launched"
    static let ratedKey = "nostalgex_rating_nudge_rated"
    /// Written by the launch analytics on every install since analytics shipped. Its
    /// presence proves an earlier launch for people upgrading from a build without
    /// the nudge, so their first launch of this build is not mistaken for a first install.
    static let legacyLaunchMarkerKey = "nostalgex_first_launch_recorded"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.standard) {
        self.defaults = defaults
    }

    var persisted: RatingNudgePolicy.Persisted {
        RatingNudgePolicy.Persisted(
            qualifyingSessions: defaults.integer(forKey: Self.qualifyingSessionsKey),
            lastShownVersion: defaults.string(forKey: Self.lastShownVersionKey),
            rated: defaults.bool(forKey: Self.ratedKey)
        )
    }

    /// Call once per process, before anything else writes the legacy launch marker.
    /// Returns whether this is the first launch ever, and records that it happened.
    func consumeFirstLaunch() -> Bool {
        let seenBefore = defaults.bool(forKey: Self.hasLaunchedKey)
            || defaults.bool(forKey: Self.legacyLaunchMarkerKey)
        defaults.set(true, forKey: Self.hasLaunchedKey)
        return !seenBefore
    }

    func recordViewingSession() {
        defaults.set(defaults.integer(forKey: Self.qualifyingSessionsKey) + 1, forKey: Self.qualifyingSessionsKey)
    }

    func recordRated() {
        defaults.set(true, forKey: Self.ratedKey)
    }

    func recordShown(version: String) {
        defaults.set(version, forKey: Self.lastShownVersionKey)
    }

    static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
