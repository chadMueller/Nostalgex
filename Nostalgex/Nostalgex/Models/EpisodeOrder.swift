import Foundation

/// EPISODE ORDER (I-103): how a channel picks the episodes of a show. One setting for the whole app, in
/// CHANNELS & BUNDLES. Movies are never affected: a film is its own group in the day's ordering.
///
/// CLASSIC RERUNS is the default. Until 1.0.34 its two episodes were any two of the show; they are now two
/// consecutive ones (Chad, 2026-11-19), which is why DailyManifestStore.schemaVersion went to 4. More orders can
/// be added as cases. Mirrors `episodeOrder` in scripts/nostalgex-daily-manifest.js.
enum EpisodeOrder: String, CaseIterable {
    /// Two consecutive episodes of a show back to back, from a random spot in the series.
    case classicReruns = "classic"
    /// One episode at a time, picked at random.
    case shuffle

    static let defaultsKey = "nostalgex_episode_order"

    /// The saved choice. Read where a day is packed, on any thread.
    static var current: EpisodeOrder {
        get { AppDefaults.standard.string(forKey: defaultsKey).flatMap(EpisodeOrder.init(rawValue:)) ?? .classicReruns }
        set {
            if newValue == .classicReruns { AppDefaults.standard.removeObject(forKey: defaultsKey) }
            else { AppDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
        }
    }

    /// Added to a day's pool fingerprint, so a day packed under another order is packed again. Empty for
    /// CLASSIC RERUNS: its fingerprint is the one every stored day already carries.
    var fingerprintSuffix: String { self == .classicReruns ? "" : "|order=\(rawValue)" }

    var title: String {
        switch self {
        case .classicReruns: return "CLASSIC RERUNS"
        case .shuffle: return "SHUFFLE"
        }
    }

    var explanation: String {
        switch self {
        case .classicReruns: return "Two episodes of a show back to back, in order. Movie channels are not affected."
        case .shuffle: return "One episode at a time, picked at random. Movie channels are not affected."
        }
    }

    /// The next choice when the row is pressed.
    var next: EpisodeOrder {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
