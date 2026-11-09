import Foundation

/// The channel names a focused package row lists under its description on CHANNEL PACKAGES
/// (discussion #217). Names only, no channel numbers, in the package's own order: the order of
/// `channelIDs` in channels.json. Every shipped package lists them by ascending channel number,
/// which is how the website's lineup sorts them (`scripts/generate-lineup-html.mjs`), so the two
/// agree; `PackageChannelListingTests` pins that.
///
/// One rule decides which channels are short of content, and the amber count on the row is
/// read from this same list (`badge`), so the count names exactly what it counts:
///
/// - a package that is off lists its channels and marks none: with no library check made for
///   it, an off package is an invitation, never a warning;
/// - a package that is still building marks none, the row says it is finding channels;
/// - a package with nothing on air at all marks none: the row says "Not enough content to
///   build this package" and dims, which already says every channel is short;
/// - otherwise the channels without enough content are marked, and `badge` is how many.
///
/// Nothing here is stored: the names come from channels.json through
/// `AppState.bundleChannelAvailability(for:)`. Pure, so it is unit tested without a library.
struct PackageChannelListing: Equatable {
    struct Entry: Equatable {
        let id: Int
        let name: String
        /// Short of content: drawn amber, and counted by the row's amber badge.
        let isShort: Bool
    }

    let entries: [Entry]

    /// - Parameter availability: every channel of the package in config order, flagged by
    ///   whether it has enough content to air (`AppState.bundleChannelAvailability`).
    init(availability: [(id: Int, name: String, hasContent: Bool)], enabled: Bool, building: Bool) {
        let available = availability.filter(\.hasContent).count
        let marksShortChannels = enabled && !building && available > 0
        entries = availability.map { channel in
            Entry(id: channel.id, name: channel.name, isShort: marksShortChannels && !channel.hasContent)
        }
    }

    var names: [String] { entries.map(\.name) }

    /// The channels drawn amber.
    var shortChannels: [Entry] { entries.filter(\.isShort) }

    /// The number on the row's amber badge, nil when no channel is short.
    var badge: Int? {
        let count = shortChannels.count
        return count > 0 ? count : nil
    }

    /// What VoiceOver reads after the row's title for the amber count. "Titles", the word the
    /// on-screen line and the WHY ARE SOME CHANNELS MISSING? page use.
    var badgeLabel: String? {
        guard let count = badge else { return nil }
        return count == 1 ? "1 channel has not enough titles yet" : "\(count) channels have not enough titles yet"
    }

    /// The row's VoiceOver hint: the channels in order, then which of them are short, because amber is
    /// colour only on screen. Nil when there are no names, so a row with no list has no hint at all.
    var spokenChannels: String? {
        guard !entries.isEmpty else { return nil }
        var text = "Channels: " + names.joined(separator: ", ") + "."
        if !shortChannels.isEmpty {
            text += " Not enough titles yet: " + shortChannels.map(\.name).joined(separator: ", ") + "."
        }
        return text
    }
}
