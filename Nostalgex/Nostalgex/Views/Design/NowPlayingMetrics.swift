import SwiftUI

// The Now Playing panel at the guide's scale (Chad, 2026-11-10, "everything is still very big, match it with the guide
// text size"): 22 pt for row labels and values, the channel line, the UP NEXT chip and title and the hint line; the item
// title at the heading size (29), so the hierarchy is size and white against text-2, not a bigger title. The row is the
// guide's 64 pt. The shared tokens (NXType, NXFont, NXLayout) and the Settings scale are untouched.
// DM Mono is declared here, once, so NowPlayingPanel.swift keeps to the "no literal font sizes" rule.

enum NowPlayingType {
    /// Row labels and values, the channel line, the UP NEXT chip and title, the hint line, list entries.
    static let text: CGFloat = GuideTextMetrics.packageRowText
    /// The item title.
    static let title: CGFloat = 29
    /// The CH tag in VT323. 31 read as large as the 22 pt text beside it; 28 is one step down.
    static let tag: CGFloat = 28
}

enum NowPlayingFont {
    static let textMedium = Font.custom("DMMono-Medium", size: NowPlayingType.text)
    static let textRegular = Font.custom("DMMono-Regular", size: NowPlayingType.text)
    static let title = Font.custom("DMMono-Medium", size: NowPlayingType.title)
    static let tag = Font.custom("VT323-Regular", size: NowPlayingType.tag)
    static let icon = Font.system(size: NowPlayingType.text, weight: .semibold)
}

enum NowPlayingLayout {
    static let rowHeight: CGFloat = GuideTextMetrics.rowHeight
    static let rowPaddingX: CGFloat = 18
    static let rowGap: CGFloat = 8
    static let columnWidth: CGFloat = 440
    static let columnGap: CGFloat = 28
    static let posterWidth: CGFloat = 120
    static let posterHeight: CGFloat = 180
}
