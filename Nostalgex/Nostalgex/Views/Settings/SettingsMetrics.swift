import SwiftUI

// Settings-local sizes (Chad, 2026-11-10: "everything looks just a little too big").
//
// The shared tokens (NXType, NXFont, NXLayout) stay as they are: the Now Playing panel uses them and is
// right. Settings steps one size down from them. Captions stay at NXType.caption (25, the floor).
// DM Mono is declared here, once, so the Settings views keep to the "no literal font sizes" rule.

enum SettingsType {
    /// A row's label and value. NXType.body is 29.
    static let body: CGFloat = 25
    /// A section or sheet heading, and the hero title. NXType.heading is 34.
    static let heading: CGFloat = 29
    /// VT323, measured by its visual size like NXType.tag (36 for DM Mono 25), so 31 for DM Mono 25 -> 22 scaled.
    static let tag: CGFloat = 31
}

enum SettingsFont {
    static let bodyMedium = Font.custom("DMMono-Medium", size: SettingsType.body)
    static let bodyRegular = Font.custom("DMMono-Regular", size: SettingsType.body)
    static let heading = Font.custom("DMMono-Medium", size: SettingsType.heading)
    static let tag = Font.custom("VT323-Regular", size: SettingsType.tag)
    /// A chevron or arrow that sits beside body text.
    static let icon = Font.system(size: SettingsType.body, weight: .semibold)
}
