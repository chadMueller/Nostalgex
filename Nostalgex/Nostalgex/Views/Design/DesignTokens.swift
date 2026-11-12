import SwiftUI

/// The shared type scale and color list (design tokens). One place for what a size or a color
/// is called, so a screen asks for `NXFont.body`, not `size: 22`, and for `NXColor.text2`, not
/// `.white.opacity(0.7)`.
///
/// Rules these hold (Chad, 2026-11-10):
///  - Six type sizes. Nothing the viewer reads is below 25 pt (`NXType.floor`), and nothing the
///    viewer presses is below 29 pt (`NXType.pressFloor`).
///  - Every text color is at least 4.5:1 on every surface it sits on. `DesignTokensTests` checks
///    each pair in `NXColor.textPairs`; add a pair there when a text color lands on a new surface.
///  - White with an opacity is not a text color. Secondary text is `text2`.
///  - A channel's own color is never text (see `NXColor.readableText(on:)` for text on it).
///
/// The proposal is in `nowplaying-mock/tokens.md`. Adopted so far: Settings, the rating banner, the Now
/// Playing panel and the guide grid (its sizes come through `GuideTextMetrics`, so GUIDE TEXT SIZE still
/// works). Not yet: the guide's package list (the left jump rail).

// MARK: - Type

enum NXType {
    static let hero: CGFloat = 96
    static let title: CGFloat = 44
    static let heading: CGFloat = 34
    static let body: CGFloat = 29
    static let caption: CGFloat = 25
    /// VT323, a pixel face with short glyphs: 36 reads about the size of DM Mono 25.
    static let tag: CGFloat = 36

    /// The smallest text anywhere, in points. VT323 is measured by its visual size, so `tag` is exempt.
    static let floor: CGFloat = 25
    /// The smallest text on anything the viewer presses.
    static let pressFloor: CGFloat = 29

    /// The DM Mono sizes, for the test that holds the floor.
    static let dmMonoSizes: [CGFloat] = [hero, title, heading, body, caption]
}

enum NXFont {
    static let hero = Font.custom("DMMono-Medium", size: NXType.hero)
    static let title = Font.custom("DMMono-Medium", size: NXType.title)
    static let heading = Font.custom("DMMono-Medium", size: NXType.heading)
    /// A row's label, a button's label.
    static let bodyMedium = Font.custom("DMMono-Medium", size: NXType.body)
    /// A row's value.
    static let bodyRegular = Font.custom("DMMono-Regular", size: NXType.body)
    /// Section labels, the line under a row, hints, notes.
    static let captionMedium = Font.custom("DMMono-Medium", size: NXType.caption)
    static let captionRegular = Font.custom("DMMono-Regular", size: NXType.caption)
    /// CH tag, countdowns, timestamps, the SETTINGS page title.
    static let tag = Font.custom("VT323-Regular", size: NXType.tag)
    /// A chevron or checkmark that sits beside body text.
    static let icon = Font.system(size: NXType.body, weight: .semibold)
}

// MARK: - Layout

/// The numbers every screen's rows and safe area share (the row spec in `tokens.md`).
enum NXLayout {
    /// One height for every row, on Settings and in the Now Playing panel.
    static let rowHeight: CGFloat = 76
    static let rowGap: CGFloat = 12
    static let rowRadius: CGFloat = 12
    static let rowPaddingX: CGFloat = 28
    /// tvOS title safe area at 1920 x 1080.
    static let safeX: CGFloat = 90
    static let safeY: CGFloat = 60
    /// Selected state: 3 pt cyan outline, a 30 pt glow at 55%, a 3% lift.
    static let selectedOutline: CGFloat = 3
    static let restingOutline: CGFloat = 1.5
    static let glowRadius: CGFloat = 30
    static let glowOpacity: Double = 0.55
    static let lift: CGFloat = 1.03
}

// MARK: - Color

/// A color given as hex, with the math the contrast test needs.
struct NXRGB: Equatable {
    let r: Double, g: Double, b: Double   // 0...1

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    var color: Color { Color(red: r, green: g, blue: b) }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ a: NXRGB, _ b: NXRGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }
}

enum NXColor {
    // Text
    static let text = NXRGB(0xFFFFFF)
    /// The only other text grey: resting values, hints, section labels, chevrons, OFF.
    static let text2 = NXRGB(0xB9C3DE)
    /// Guide programme titles that are not live, not focused: clearly dimmer than text-2 (Chad, 2026-11-10, "the
    /// upcoming is not dimmer"). The text-2 hue pulled toward black to the dimmest value that still holds 4.5:1 on
    /// the lightest thing a guide title sits on (the even-row wash and the past-block wash over the guide's
    /// #0D0D1F): 4.83:1 there, 5.36:1 on the bare guide, 17.2:1 for white, 10.9:1 for text-2.
    static let textDim = NXRGB(0x80879A)
    /// Selection, ON, links, a focused chevron. The same value as the BrandCyan asset.
    static let cyan = NXRGB(0x00D4FF)
    /// Live status only: the sleep countdown, UP NEXT.
    static let yellow = NXRGB(0xFFE500)
    /// Warnings that need attention.
    static let amber = NXRGB(0xFFB020)
    /// Danger as text.
    static let redText = NXRGB(0xFF6B81)
    /// Danger fill or outline only, never text on a row.
    static let red = NXRGB(0xFF2244)
    /// What the guide grid sits on (ChannelGuideView's background), and the two washes a programme title can
    /// have over it: the even row's 3% white, and a past block's 2% white on top of that.
    static let guide = NXRGB(r: 0.05, g: 0.05, b: 0.12)
    static let guideEvenRow = GuideRowContrast.mix(NXRGB(0xFFFFFF), over: guide, opacity: 0.03)
    static let guideEvenRowPast = GuideRowContrast.mix(NXRGB(0xFFFFFF), over: guideEvenRow, opacity: 0.02)

    /// Text on a solid cyan fill.
    static let onCyan = NXRGB(0x00101A)

    // Surfaces
    static let panel = NXRGB(0x0A0F1E)
    static let row = NXRGB(0x141B33)
    static let selectedRow = NXRGB(0x0B2A3A)
    /// A row that is chosen but not under the cursor.
    static let chosenNeutral = NXRGB(0x2B3760)
    /// A resting row's outline (a boundary, not text).
    static let restingOutline = NXRGB(0x3A4670)

    /// Every text color on every surface it can sit on, with the least contrast it may have.
    /// `DesignTokensTests` fails when one drops below 4.5:1.
    static let textPairs: [(name: String, fg: NXRGB, bg: NXRGB, minimum: Double)] = {
        let surfaces: [(String, NXRGB)] = [("panel", panel), ("row", row), ("selectedRow", selectedRow)]
        var pairs: [(String, NXRGB, NXRGB, Double)] = []
        for (sn, s) in surfaces {
            for (tn, t) in [("text", text), ("text2", text2), ("cyan", cyan), ("yellow", yellow), ("amber", amber), ("redText", redText)] {
                pairs.append(("\(tn) on \(sn)", t, s, 4.5))
            }
        }
        pairs.append(("text on chosenNeutral", text, chosenNeutral, 4.5))
        pairs.append(("text2 on chosenNeutral", text2, chosenNeutral, 4.5))
        pairs.append(("onCyan on cyan", onCyan, cyan, 4.5))
        // The guide's dim title colour on everything a non-live title sits on.
        for (sn, s) in [("guide", guide), ("guideEvenRow", guideEvenRow), ("guideEvenRowPast", guideEvenRowPast)] {
            pairs.append(("textDim on \(sn)", textDim, s, 4.5))
        }
        return pairs
    }()

    /// Text on a solid channel-colored fill: black or white, whichever reads better (always at least
    /// 4.5:1, since the better of the two is at least 4.58:1 against any color).
    static func readableText(on fill: NXRGB) -> NXRGB {
        NXRGB.contrast(text, fill) >= NXRGB.contrast(NXRGB(0x000000), fill) ? text : NXRGB(0x000000)
    }
}

extension Color {
    static let nxText = NXColor.text.color
    static let nxText2 = NXColor.text2.color
    static let nxTextDim = NXColor.textDim.color
    static let nxCyan = NXColor.cyan.color
    static let nxYellow = NXColor.yellow.color
    static let nxAmber = NXColor.amber.color
    static let nxRedText = NXColor.redText.color
    static let nxRed = NXColor.red.color
    static let nxOnCyan = NXColor.onCyan.color
    static let nxPanel = NXColor.panel.color
    static let nxRow = NXColor.row.color
    static let nxSelectedRow = NXColor.selectedRow.color
    static let nxChosenNeutral = NXColor.chosenNeutral.color
    static let nxRestingOutline = NXColor.restingOutline.color
}

// MARK: - The row, resting and selected

/// The one row surface (Settings and the Now Playing panel):
/// resting is the row fill with a quiet 1.5 pt outline; selected is the cyan-tinted fill, a
/// 3 pt solid cyan outline, a cyan glow and a 3% lift. One row at a time is selected.
/// `isStatic` is a row that only informs (a single audio track): no fill, a dashed outline,
/// and the focus engine skips it.
struct NXRowSurface: ViewModifier {
    let isSelected: Bool
    var cornerRadius: CGFloat = NXLayout.rowRadius
    var isStatic: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isStatic ? Color.clear : (isSelected ? Color.nxSelectedRow : Color.nxRow))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.nxCyan : Color.nxRestingOutline,
                        style: StrokeStyle(lineWidth: isSelected ? NXLayout.selectedOutline : NXLayout.restingOutline,
                                           dash: isStatic ? [8, 6] : [])
                    )
            )
            .shadow(color: isSelected ? Color.nxCyan.opacity(NXLayout.glowOpacity) : .clear,
                    radius: isSelected ? NXLayout.glowRadius : 0)
            .scaleEffect(isSelected ? NXLayout.lift : 1)
            .zIndex(isSelected ? 1 : 0)
    }
}

extension View {
    func nxRowSurface(isSelected: Bool, cornerRadius: CGFloat = NXLayout.rowRadius, isStatic: Bool = false) -> some View {
        modifier(NXRowSurface(isSelected: isSelected, cornerRadius: cornerRadius, isStatic: isStatic))
    }
}
