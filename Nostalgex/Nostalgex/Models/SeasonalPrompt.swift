import Foundation

/// Decides whether to offer a seasonal bundle, and remembers the answer.
///
/// Seasonal bundles are never switched on for people. A bundle coming into season only
/// earns the right to ask once, and "no" is respected for the rest of that season —
/// the offer comes back next year unless the answer was "never".
///
/// Pure on purpose: the guide shows whatever `bundleToOffer` returns, and every branch
/// here is unit-tested rather than discovered next October.
enum SeasonalPrompt {

    /// What the viewer chose in the confirmation dialog.
    enum Answer {
        case yes      // turn the bundle on for this season
        case notNow   // stay quiet until this season ends
        case never    // never offer this bundle again
    }

    /// Storage keys. The season key carries the year so a "no" this October does not
    /// silence next October. Every season ends by December 31 (TIS THE SEASON runs from a
    /// week before US Thanksgiving), so one calendar year holds one season.
    static func neverKey(_ bundleID: String) -> String { "nostalgex_seasonal_never_\(bundleID)" }
    static func dismissedKey(_ bundleID: String, year: Int) -> String {
        "nostalgex_seasonal_dismissed_\(bundleID)_\(year)"
    }

    /// The one seasonal bundle worth offering right now, or nil.
    ///
    /// A bundle qualifies when it is seasonal (`activeMonths` set), currently in season,
    /// not already enabled, and not silenced. When several qualify, config order wins so
    /// the viewer is asked one thing at a time.
    static func bundleToOffer(
        bundles: [ChannelBundle],
        enabledBundleIDs: Set<String>,
        now: Date,
        calendar: Calendar = ChannelBundle.seasonCalendar,
        isSilenced: (String) -> Bool
    ) -> ChannelBundle? {
        bundles.first { bundle in
            bundle.activeMonths != nil
                && bundle.isInSeason(on: now, calendar: calendar)
                && !enabledBundleIDs.contains(bundle.id)
                && !isSilenced(bundle.id)
        }
    }

    /// The invite's headline. TIS THE SEASON starts in November, so it only says
    /// December in December. Mirrors `inviteHeadline` in scripts/nostalgex-season.js.
    static func headline(for bundle: ChannelBundle, now: Date,
                         calendar: Calendar = ChannelBundle.seasonCalendar) -> String {
        switch bundle.id {
        case "seasonal":
            return "IT'S OCTOBER. ARE YOU READY TO SCREAM?"
        case "tis-the-season":
            return calendar.component(.month, from: now) == 12
                ? "IT'S DECEMBER. DECK THE CHANNELS."
                : "THE HOLIDAYS ARE HERE. DECK THE CHANNELS."
        default:
            return "\(bundle.name) IS IN SEASON."
        }
    }

    /// Whether this bundle has been silenced, either forever or for the current season.
    static func isSilenced(
        bundleID: String,
        now: Date,
        defaults: UserDefaults = AppDefaults.standard,
        calendar: Calendar = .current
    ) -> Bool {
        if defaults.bool(forKey: neverKey(bundleID)) { return true }
        let year = calendar.component(.year, from: now)
        return defaults.bool(forKey: dismissedKey(bundleID, year: year))
    }

    /// Records the viewer's answer. Returns true when the bundle should be switched on.
    @discardableResult
    static func record(
        _ answer: Answer,
        bundleID: String,
        now: Date,
        defaults: UserDefaults = AppDefaults.standard,
        calendar: Calendar = .current
    ) -> Bool {
        switch answer {
        case .yes:
            return true
        case .notNow:
            defaults.set(true, forKey: dismissedKey(bundleID, year: calendar.component(.year, from: now)))
            return false
        case .never:
            defaults.set(true, forKey: neverKey(bundleID))
            return false
        }
    }
}
