import SwiftUI

/// THEME (Settings > PLAYBACK & PICTURE): the colors and type of the guide screen and the
/// Now Playing panel. NOSTALGEX is the app as it has always looked; the others are loose
/// nods to cable and satellite guides from the late 90s and 2000s, built from tvOS's own
/// fonts. No logos or brand art.
///
/// Every style is optional. A nil field means "draw it the NOSTALGEX way", and NOSTALGEX
/// sets nothing, so the default theme takes exactly the code paths the app took before
/// themes existed. Settings, the connect screen and the player's picture are never themed.
///
/// Per Apple TV, never synced. Saved under `storageKey`; nothing saved, or anything
/// unknown, is NOSTALGEX.
struct GuideTheme: Identifiable, Equatable {
    let id: String
    let label: String

    // MARK: Type

    /// PostScript names. nil keeps DM Mono and VT323.
    var boldFont: String? = nil
    var regularFont: String? = nil
    /// Applied to every themed size, for faces that run smaller or larger than DM Mono.
    var fontScale: CGFloat = 1
    /// A hard black drop under text, the way old character generators outlined it.
    var textShadow: Color? = nil

    // MARK: Top of the guide screen

    var infoBackground: [Color]? = nil
    var infoTitle: Color? = nil
    var infoBody: Color? = nil
    /// Stands in for the channel's own color in the info panel and Now Playing panel.
    var accent: Color? = nil
    var navText: Color? = nil
    var navFocused: Color? = nil

    // MARK: Guide grid

    /// Behind the grid; shows in the gaps between cells.
    var gridBackground: Color? = nil
    var headerBackground: Color? = nil
    var headerText: Color? = nil
    var channelColumn: Color? = nil
    var channelColumnFocused: Color? = nil
    var channelText: Color? = nil
    var channelTextFocused: Color? = nil
    /// Program cells, one color per row, repeating. Replaces the channel-color tint.
    var cellColors: [Color]? = nil
    var cellText: Color? = nil
    var pastCellText: Color? = nil
    var focusedCell: Color? = nil
    var focusedCellText: Color? = nil
    /// Space between cells, so each one reads as its own box.
    var cellGap: CGFloat = 0
    var nowLine: Color? = nil

    // MARK: Now Playing panel

    var panelBackground: [Color]? = nil
    /// The accent on the panel's dark backdrop, when `accent` is meant for a light info panel.
    var panelAccent: Color? = nil
    var panelRow: Color? = nil
    var panelRowFocused: Color? = nil
    var panelText: Color? = nil
    var panelFocusBorder: Color? = nil

    static func == (a: GuideTheme, b: GuideTheme) -> Bool { a.id == b.id }

    // MARK: Fonts

    /// The themed font for a spot that draws `nostalgexName` at `size` today.
    /// Medium and VT323 map to the bold face, Regular to the regular face.
    func font(_ nostalgexName: String, size: CGFloat) -> Font {
        guard let boldFont else { return .custom(nostalgexName, size: size) }
        let name = nostalgexName.hasSuffix("-Regular") && !nostalgexName.hasPrefix("VT323")
            ? (regularFont ?? boldFont) : boldFont
        return .custom(name, size: (size * fontScale).rounded())
    }

    /// The channel's color, or the theme's accent.
    func accent(for channel: Channel) -> Color { accent ?? channel.color }

    /// The program-cell color for a row, if the theme sets one.
    func cellColor(row: Int) -> Color? {
        guard let cellColors, !cellColors.isEmpty else { return nil }
        return cellColors[row % cellColors.count]
    }
}

// MARK: - The themes

extension GuideTheme {
    static let storageKey = "nostalgex_guide_theme"

    static let nostalgex = GuideTheme(id: "nostalgex", label: "NOSTALGEX")

    /// A 2000s satellite box: royal blue cells, a pale top band, a yellow selection.
    static let satellite = GuideTheme(
        id: "satellite", label: "SATELLITE",
        boldFont: "Helvetica-Bold", regularFont: "HelveticaNeue-Medium",
        infoBackground: [Color(hex: "#DCEAF8"), Color(hex: "#5C9BE6")],
        infoTitle: Color(hex: "#13306E"), infoBody: Color(hex: "#13306E"),
        accent: Color(hex: "#13306E"),
        navText: Color(hex: "#13306E").opacity(0.7), navFocused: Color(hex: "#C2410C"),
        gridBackground: Color(hex: "#0A1D52"),
        headerBackground: Color(hex: "#0A1D52"), headerText: .white,
        channelColumn: Color(hex: "#123A9C"), channelColumnFocused: Color(hex: "#1E4FC8"), channelText: .white,
        cellColors: [Color(hex: "#1E4FC8")], cellText: .white, pastCellText: .white.opacity(0.6),
        focusedCell: Color(hex: "#F6B21B"), focusedCellText: Color(hex: "#13306E"),
        cellGap: 3, nowLine: .white,
        panelBackground: [Color(hex: "#0A1D52").opacity(0.95), .clear], panelAccent: Color(hex: "#F6B21B"),
        panelRow: Color(hex: "#1E4FC8"), panelRowFocused: Color(hex: "#F6B21B"),
        panelText: .white, panelFocusBorder: Color(hex: "#F6B21B")
    )

    /// Late-90s digital cable: a cream info card, periwinkle cells, a red selection.
    static let cableBox = GuideTheme(
        id: "cable_box", label: "CABLE BOX",
        boldFont: "Futura-CondensedExtraBold", regularFont: "Futura-CondensedMedium", fontScale: 1.2,
        infoBackground: [Color(hex: "#F7E9A6"), Color(hex: "#F4F0DC")],
        infoTitle: .black, infoBody: Color(hex: "#1B1B3A"),
        accent: Color(hex: "#1D2A6B"),
        navText: Color(hex: "#1D2A6B").opacity(0.7), navFocused: Color(hex: "#C62828"),
        gridBackground: Color(hex: "#1D2A6B"),
        headerBackground: Color(hex: "#1D2A6B"), headerText: .white,
        channelColumn: Color(hex: "#D9DCF2"), channelColumnFocused: Color(hex: "#0E1A4F"), channelText: Color(hex: "#0E1A4F"), channelTextFocused: .white,
        cellColors: [Color(hex: "#3F57B5")], cellText: .white, pastCellText: .white.opacity(0.6),
        focusedCell: Color(hex: "#D9302A"), focusedCellText: .white,
        cellGap: 2, nowLine: Color(hex: "#F7E9A6"),
        panelBackground: [Color(hex: "#1D2A6B").opacity(0.95), .clear], panelAccent: Color(hex: "#F7E9A6"),
        panelRow: Color(hex: "#3F57B5"), panelRowFocused: Color(hex: "#D9302A"),
        panelText: .white, panelFocusBorder: Color(hex: "#F7E9A6")
    )

    /// The scrolling preview channel: deep blue, yellow outlined type, blue and maroon rows.
    static let y1998 = GuideTheme(
        id: "1998", label: "1998",
        boldFont: "DINCondensed-Bold", regularFont: "DINCondensed-Bold", fontScale: 1.35,
        textShadow: .black,
        infoBackground: [Color(hex: "#1636C8"), Color(hex: "#07136A")],
        infoTitle: Color(hex: "#F7E64A"), infoBody: .white,
        accent: Color(hex: "#F7E64A"),
        navText: Color(hex: "#F7E64A").opacity(0.7), navFocused: .white,
        gridBackground: Color(hex: "#0A1878"),
        headerBackground: Color(hex: "#2A4BD0"), headerText: Color(hex: "#F7E64A"),
        channelColumn: Color(hex: "#0C1E8C"), channelColumnFocused: Color(hex: "#2A4BD0"), channelText: Color(hex: "#F7E64A"),
        cellColors: [Color(hex: "#3C8FE0"), Color(hex: "#7A2030")], cellText: .white, pastCellText: .white.opacity(0.65),
        focusedCell: Color(hex: "#8CC8FF"), focusedCellText: Color(hex: "#07136A"),
        cellGap: 4, nowLine: Color(hex: "#F7E64A"),
        panelBackground: [Color(hex: "#07136A").opacity(0.95), .clear],
        panelRow: Color(hex: "#2A4BD0"), panelRowFocused: Color(hex: "#3C8FE0"),
        panelText: .white, panelFocusBorder: Color(hex: "#F7E64A")
    )

    /// An early-2000s on-screen guide: navy, purple and blue cells, a pale yellow selection.
    static let y2k = GuideTheme(
        id: "y2k", label: "Y2K",
        boldFont: "HelveticaNeue-Medium", regularFont: "HelveticaNeue",
        infoBackground: [Color(hex: "#101A5A"), Color(hex: "#0A0F3A")],
        infoTitle: .white, infoBody: .white.opacity(0.85),
        accent: Color(hex: "#F2E86A"),
        navText: .white.opacity(0.6), navFocused: Color(hex: "#F2E86A"),
        gridBackground: .black,
        headerBackground: Color(hex: "#2A3A8A"), headerText: .white,
        channelColumn: Color(hex: "#3B2A7A"), channelColumnFocused: Color(hex: "#5A44B0"), channelText: .white,
        cellColors: [Color(hex: "#1C2C8C"), Color(hex: "#3A2A80")], cellText: .white, pastCellText: .white.opacity(0.55),
        focusedCell: Color(hex: "#F2E86A"), focusedCellText: .black,
        cellGap: 2, nowLine: Color(hex: "#F2E86A"),
        panelBackground: [Color(hex: "#0A0F3A").opacity(0.95), .clear],
        panelRow: Color(hex: "#1C2C8C"), panelRowFocused: Color(hex: "#F2E86A"),
        panelText: .white, panelFocusBorder: Color(hex: "#F2E86A")
    )

    static let all: [GuideTheme] = [.nostalgex, .satellite, .cableBox, .y1998, .y2k]

    init(stored: String?) {
        self = GuideTheme.all.first { $0.id == stored } ?? .nostalgex
    }

    static func current(defaults: UserDefaults = AppDefaults.standard) -> GuideTheme {
        GuideTheme(stored: defaults.string(forKey: storageKey))
    }

    /// The next theme when the Settings row is selected, wrapping to NOSTALGEX.
    var next: GuideTheme {
        let all = GuideTheme.all
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

extension View {
    /// The theme's hard text shadow, or nothing at all for a theme without one.
    @ViewBuilder
    func themeTextShadow(_ color: Color?) -> some View {
        if let color {
            self.shadow(color: color, radius: 0, x: 2, y: 2)
        } else {
            self
        }
    }
}
