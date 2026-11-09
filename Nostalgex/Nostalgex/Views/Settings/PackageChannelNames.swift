import SwiftUI

/// The channel names a focused package row grows to show (discussion #217). A small, dim run
/// of names joined by dots under the row's description; the ones short of content are amber,
/// with one line saying what amber means. Names only, never a channel number.
///
/// Drawn only while the row has focus (`SettingsToggleRow`), so the page is no longer than
/// before while a viewer scrolls past, and the list is not read on every row of the page.
struct PackageChannelNames: View {
    let listing: PackageChannelListing
    /// Whether the package is on: its names read brighter than an off package's.
    let isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.attributed(listing: listing, isOn: isOn))
                .font(.custom("DMMono-Regular", size: 18))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("packageChannelNames")

            if !listing.shortChannels.isEmpty {
                Text("Amber: not enough titles yet")
                    .font(.custom("DMMono-Regular", size: 18))
                    .foregroundStyle(Self.amber)
                    .accessibilityIdentifier("packageChannelNamesLegend")
            }
        }
    }

    /// The names in package order, dot separated. A name never breaks across lines (its spaces
    /// are non-breaking) and the dot stays with the name before it, so a line can only end between
    /// two channels.
    static func attributed(listing: PackageChannelListing, isOn: Bool) -> AttributedString {
        let base = Color.white.opacity(isOn ? 0.7 : 0.45)
        let dot = Color.white.opacity(isOn ? 0.35 : 0.25)
        var text = AttributedString()
        let last = listing.entries.count - 1
        for (index, entry) in listing.entries.enumerated() {
            var name = AttributedString(entry.name.replacingOccurrences(of: " ", with: "\u{00A0}"))
            name.foregroundColor = entry.isShort ? amber : base
            text += name
            if index < last {
                var separator = AttributedString("\u{00A0}·")
                separator.foregroundColor = dot
                text += separator
                text += AttributedString(" ")
            }
        }
        return text
    }

    private static var amber: Color { Color(hex: "#FFB020") }

    /// What VoiceOver reads after the row: the names, in order.
    static func spokenNames(_ listing: PackageChannelListing) -> String {
        "Channels: " + listing.names.joined(separator: ", ")
    }
}
