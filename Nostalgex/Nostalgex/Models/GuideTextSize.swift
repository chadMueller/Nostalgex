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

/// Type sizes (points, DM Mono Medium) for the text the guide grid draws.
///
/// Only text changes. The row stays 80 points and the header 60, the channel column
/// stays 220, and program blocks are laid out by ProgramRowLayout from times alone, so
/// LARGE never moves a row or a block.
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

    /// The sizes the guide drew before GUIDE TEXT SIZE existed. Must not change.
    static let normal = GuideTextMetrics(
        title: 20, timeLabel: 20, channelHeading: 18,
        number: 20, numberWidth: 36, name: 18, placeholder: 18
    )

    /// Roku's LARGE (GuideText.brs): titles and times 26, heading 22, number 24 in a
    /// 44-point box, name 20. The channel column cannot widen, so the number and name
    /// grow least and the name gives up characters to the ellipsis.
    static let large = GuideTextMetrics(
        title: 26, timeLabel: 26, channelHeading: 22,
        number: 24, numberWidth: 44, name: 20, placeholder: 22
    )
}
