import CoreGraphics
import Foundation

/// GUIDE TEXT SIZE (Settings > PLAYBACK & PICTURE): NORMAL, the guide as it has always
/// been drawn, or LARGE, for a couch further from the screen. Two built-in sizes, no
/// choice of fonts. Same choice and same LARGE sizes as Roku's (I-060).
///
/// Saved as "normal" or "large" under `storageKey`. Nothing saved, or anything else, is
/// NORMAL, so a TV that never chose draws exactly as before.
enum GuideTextSize: String, CaseIterable {
    case normal
    case large

    static let storageKey = "nostalgex_guide_text_size"

    init(stored: String?) {
        self = stored == GuideTextSize.large.rawValue ? .large : .normal
    }

    /// What the Settings row shows.
    var label: String { rawValue.uppercased() }

    var metrics: GuideTextMetrics {
        switch self {
        case .normal: return .normal
        case .large: return .large
        }
    }
}

/// Type sizes (points, DM Mono Medium) for the text the guide grid draws, all from the shared type scale
/// (`NXType`, Chad 2026-11-10): nothing is below the 25 pt floor, and a program's title and a channel's number
/// and name are caption (25) in NORMAL and body (29) in LARGE.
///
/// Only text changes with the setting. The row stays `NXLayout.rowHeight` (76) and the header 58, the channel
/// column stays 340, and program blocks are laid out by ProgramRowLayout from times alone, so LARGE never moves a
/// row or a block.
struct GuideTextMetrics: Equatable {
    /// A program's title in its block.
    let title: CGFloat
    /// The time labels across the header.
    let timeLabel: CGFloat
    /// The CHANNEL heading over the channel column.
    let channelHeading: CGFloat
    /// A row's channel number, and the right-aligned box it sits in.
    let number: CGFloat
    let numberWidth: CGFloat
    /// The channel name after the number.
    let name: CGFloat
    /// BROADCASTS RESUME AT 9 PM, on a row Watershed has emptied.
    let placeholder: CGFloat

    /// Everything at the 25 pt floor (caption), Chad 2026-11-10: body (29) read too big in the grid.
    /// The box holds three digits at 25 pt (45 pt measured with DM Mono).
    static let normal = GuideTextMetrics(
        title: NXType.caption, timeLabel: NXType.caption, channelHeading: NXType.caption,
        number: NXType.caption, numberWidth: 46, name: NXType.caption, placeholder: NXType.caption
    )

    /// One step up the scale for a couch further from the screen: everything at body (29). The channel column
    /// cannot widen, so the name gives up characters to the ellipsis. Roku's LARGE is still its own
    /// (GuideText.brs): the two no longer share numbers.
    static let large = GuideTextMetrics(
        title: NXType.body, timeLabel: NXType.body, channelHeading: NXType.body,
        number: NXType.body, numberWidth: 54, name: NXType.body, placeholder: NXType.body
    )
}
