import SwiftUI

/// The fills behind a focused guide row's text.
///
/// The focused row was a third-strength wash of the channel color, and its playing block a
/// half-strength one, with white text over both. On a bright channel (cyan, yellow, white) that
/// is about 2.5 to 3:1, hard to read from the couch. The wash is kept, composited over the guide's
/// own background, and darkened only as far as white text needs to reach 4.5:1: a dark channel
/// is untouched, a bright one gets a darker shade of itself. Never text in the channel color
/// (see `NXColor.readableText(on:)` for the rule when text must sit on a color directly).
enum GuideRowContrast {
    /// What the guide draws its rows on.
    static let background = NXColor.panel
    static let minimum = 4.5

    struct Fills: Equatable {
        /// Behind the whole focused row (channel number, name, the program titles beside the playing one).
        let row: NXRGB
        /// Behind the playing program's block in the focused row.
        let nowPlaying: NXRGB
    }

    /// `channel` is the channel's own color.
    static func fills(for channel: NXRGB) -> Fills {
        Fills(row: shade(rowWash(channel)), nowPlaying: shade(playingWash(channel)))
    }

    /// The wash the focused row always had: a third of the channel color over the guide.
    static func rowWash(_ channel: NXRGB) -> NXRGB { mix(channel, over: background, opacity: 0.32) }

    /// What the playing block looked like on the focused row: half-strength channel color laid over
    /// the row's own wash. That stack, not the block alone over the guide, is what the text sat on.
    static func playingWash(_ channel: NXRGB) -> NXRGB { mix(channel, over: rowWash(channel), opacity: 0.55) }

    static func fills(forHex hex: String) -> Fills {
        fills(for: rgb(fromHex: hex))
    }

    /// `color` at `opacity` over `base`.
    static func mix(_ color: NXRGB, over base: NXRGB, opacity: Double) -> NXRGB {
        NXRGB(r: color.r * opacity + base.r * (1 - opacity),
              g: color.g * opacity + base.g * (1 - opacity),
              b: color.b * opacity + base.b * (1 - opacity))
    }

    /// `fill` itself when white already reads on it; otherwise the same hue scaled toward black by
    /// the least amount that gets white to the minimum.
    static func shade(_ fill: NXRGB, minimum: Double = GuideRowContrast.minimum) -> NXRGB {
        if NXRGB.contrast(NXColor.text, fill) >= minimum { return fill }
        var lo = 0.0, hi = 1.0   // lo reads, hi does not
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if NXRGB.contrast(NXColor.text, scaled(fill, mid)) >= minimum { lo = mid } else { hi = mid }
        }
        return scaled(fill, lo)
    }

    private static func scaled(_ c: NXRGB, _ k: Double) -> NXRGB { NXRGB(r: c.r * k, g: c.g * k, b: c.b * k) }

    // MARK: - Second-tier text on a focused row

    /// What the Watershed placeholder ("BROADCASTS RESUME AT 9 PM") sits on in a focused row: the row's
    /// own fill with the placeholder's 2% white lift over it.
    static func placeholderSurface(for channel: NXRGB) -> NXRGB {
        mix(NXColor.text, over: fills(for: channel).row, opacity: 0.02)
    }

    /// Text-2 (`NXColor.text2`) as it is when it already reads on `surface`; otherwise the same grey
    /// brightened toward white by the least amount that gets it to `minimum`. Text-2 is 4.3 to 4.7:1 on
    /// the focused wash of the pale channels (cream, grey, the yellows), and the placeholder's lift takes
    /// it to 4.1 to 4.4, so on those it steps up a little and stays a different grey from the white
    /// program titles. White was already the answer for the titles; this is the same rule for the one
    /// other text on that wash.
    static func secondaryText(on surface: NXRGB, minimum: Double = GuideRowContrast.minimum) -> NXRGB {
        if NXRGB.contrast(NXColor.text2, surface) >= minimum { return NXColor.text2 }
        var lo = 0.0, hi = 1.0   // lo does not read, hi (white) does
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if NXRGB.contrast(mix(NXColor.text, over: NXColor.text2, opacity: mid), surface) >= minimum { hi = mid } else { lo = mid }
        }
        return mix(NXColor.text, over: NXColor.text2, opacity: hi)
    }

    /// The Watershed placeholder's text color on a focused row of this channel color.
    static func placeholderText(forHex hex: String) -> NXRGB {
        let channel = rgb(fromHex: hex)
        return secondaryText(on: placeholderSurface(for: channel))
    }

    static func rgb(fromHex hex: String) -> NXRGB {
        let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return NXRGB(0xFFFFFF) }
        return NXRGB(value)
    }
}
