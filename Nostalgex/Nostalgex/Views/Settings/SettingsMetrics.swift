import SwiftUI

// The compact scale (Chad, 2026-11-10: "everything looks just a little too big"), read by Settings and by the
// Now Playing panel so the two share one set of sizes. The shared tokens (NXType, NXFont, NXLayout) stay as they
// are, because the guide's LARGE text, the rating banner, the seasonal invite and others still read them.
// This scale is one step down from them. Captions stay at NXType.caption (25, the floor).
// DM Mono is declared here, once, so these views keep to the "no literal font sizes" rule.

enum SettingsType {
    /// A row's label and value. NXType.body is 29.
    static let body: CGFloat = 25
    /// A section or sheet heading, and the hero title. NXType.heading is 34.
    static let heading: CGFloat = 29
    /// A programme title in the Now Playing panel. NXType.title is 44; the same step down as body and heading.
    static let title: CGFloat = 38
    /// VT323, measured by its visual size like NXType.tag (36 for DM Mono 25), so 31 for DM Mono 25 -> 22 scaled.
    static let tag: CGFloat = 31
}

enum SettingsFont {
    static let bodyMedium = Font.custom("DMMono-Medium", size: SettingsType.body)
    static let bodyRegular = Font.custom("DMMono-Regular", size: SettingsType.body)
    static let title = Font.custom("DMMono-Medium", size: SettingsType.title)
    static let heading = Font.custom("DMMono-Medium", size: SettingsType.heading)
    static let tag = Font.custom("VT323-Regular", size: SettingsType.tag)
    /// A chevron or arrow that sits beside body text.
    static let icon = Font.system(size: SettingsType.body, weight: .semibold)
}

/// The row the Now Playing panel draws at the compact scale: the guide's 64 pt row (and the Settings rail's), a
/// 20 pt side padding like a Settings row, a 10 pt gap. NXLayout's 76, 28 and 12 stay for what still reads them.
enum SettingsLayout {
    static let rowHeight: CGFloat = 64
    static let rowPaddingX: CGFloat = 20
    static let rowGap: CGFloat = 10
}
