import SwiftUI

/// The channel names a focused package row grows to show (discussion #217). One small, dim run of
/// names under the row's description, separated by commas and wrapping like any other text; the ones
/// short of content are amber, with one line saying what amber means. Names only, never a channel
/// number.
///
/// Drawn only while the row has focus (`SettingsToggleRow`), so the page is no longer than
/// before while a viewer scrolls past, and the list is not read on every row of the page.
struct PackageChannelNames: View {
    let listing: PackageChannelListing
    /// Whether the package is on: its names read brighter than an off package's.
    let isOn: Bool

    private static let font = Font.custom("DMMono-Regular", size: 18)
    private static let amber = Color(hex: "#FFB020")

    /// The colour a name is drawn in: amber when it is short of content, otherwise white, brighter
    /// for a package that is on than for one that is off.
    static func nameColor(isShort: Bool, isOn: Bool) -> Color {
        isShort ? amber : Color.white.opacity(isOn ? 0.7 : 0.45)
    }

    /// The names in package order, joined by ", ". The spaces inside a name do not break, so a line can
    /// end only after a comma, and each name carries its own colour.
    static func attributed(listing: PackageChannelListing, isOn: Bool) -> AttributedString {
        var text = AttributedString()
        let last = listing.entries.count - 1
        for (index, entry) in listing.entries.enumerated() {
            var name = AttributedString(entry.name.replacingOccurrences(of: " ", with: "\u{00A0}"))
            name.foregroundColor = nameColor(isShort: entry.isShort, isOn: isOn)
            text += name
            if index < last {
                var separator = AttributedString(", ")
                separator.foregroundColor = Color.white.opacity(isOn ? 0.45 : 0.3)
                text += separator
            }
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.attributed(listing: listing, isOn: isOn))
                .font(Self.font)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("packageChannelNames")

            if !listing.shortChannels.isEmpty {
                Text("Amber: not enough titles yet")
                    .font(Self.font)
                    .foregroundStyle(Self.amber)
                    .accessibilityIdentifier("packageChannelNamesLegend")
            }
        }
    }
}
