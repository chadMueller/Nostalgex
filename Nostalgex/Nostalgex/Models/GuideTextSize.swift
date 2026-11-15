import CoreGraphics
import Foundation

/// GUIDE TEXT SIZE (Settings > PLAYBACK & PICTURE): three steps, SMALLER, DEFAULT and LARGER,
/// for a couch nearer or further from the screen. Built-in sizes, no choice of fonts. The step also sets the
/// bundle list and the Now Playing panel (`GuideTextMetrics.packageRowText` and its neighbours), so the
/// whole guide screen moves together.
///
/// Saved under `storageKey` as "small", "normal" or "large". The middle step is labelled DEFAULT but keeps the raw
/// value "normal", and "large" is the raw value the old LARGE always had, so a saved choice, iCloud sync and the other platforms (which only know "normal" and "large") keep
/// working. Nothing saved, or anything unknown, is DEFAULT, so a TV that never chose draws as the default.
/// Case order is the order the Settings row cycles in.
enum GuideTextSize: String, CaseIterable {
    case small
    case normal
    case large

    static let storageKey = "nostalgex_guide_text_size"

    init(stored: String?) {
        self = stored.flatMap(GuideTextSize.init(rawValue:)) ?? .normal
    }

    /// The step saved on this TV right now. The bundle list and the Now Playing panel read this when they draw;
    /// `AppState.guideTextSize` writes it the moment the Settings row changes.
    static var current: GuideTextSize { GuideTextSize(stored: AppDefaults.standard.string(forKey: storageKey)) }

    /// What the Settings row shows.
    var label: String {
        switch self {
        case .small: return "SMALLER"
        case .normal: return "DEFAULT"
        case .large: return "LARGER"
        }
    }

    /// SMALLER > DEFAULT > LARGER > SMALLER, what select does on the Settings row.
    var next: GuideTextSize {
        let all = GuideTextSize.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var metrics: GuideTextMetrics {
        switch self {
        case .small: return .small
        case .normal: return .normal
        case .large: return .large
        }
    }
}

/// Type sizes (points, DM Mono Medium) for the text the guide draws, one set per step.
///
/// The row and the header are 64 and 58 at SMALLER and DEFAULT and grow at LARGER (`rowHeight`, `headerHeight`); the
/// channel column stays 340, and program blocks are laid out by ProgramRowLayout from times alone.
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
    /// The bundle list's row text and its BUNDLES heading (the guide's left rail).
    let packageRowText: CGFloat
    let packageHeading: CGFloat
    /// The Now Playing panel: row labels and values, the channel line, the UP NEXT chip and title, the hint line
    /// (`panelText`); the item title (`panelTitle`); and the CH tag in VT323 (`panelTag`).
    let panelText: CGFloat
    let panelTitle: CGFloat
    let panelTag: CGFloat
    /// The guide's row (and the bundle list's), and the time header over it. SMALLER and DEFAULT keep the guide's own
    /// 64 pt row and 58 pt header (Chad 2026-11-10: the grid read too big at the shared 76). LARGER grows them with its
    /// text so it keeps the same room around a line (Chad 2026-11-15: "larger should increase the row as well"): 20 pt in
    /// 64 leaves 22 pt above and below, 29 pt in 76 leaves 23.5; the 22 pt times in a 58 pt header leave 18, the 29 pt
    /// times in 66 leave 18.5.
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    var packageRowHeight: CGFloat { rowHeight }

    /// DEFAULT (raw value "normal"): row text (titles, numbers, names) at 20 pt and times, the heading and the placeholder at
    /// 22 pt. Both are below the app's 25 pt floor, an exception for the guide only (Chad 2026-11-10, then pulled back
    /// about 10% on 2026-11-13: "the type guide feels overly too big"; it was 22 and 25). The number box holds three
    /// digits at 20 pt (36 pt: 39.6 measured at 22 with DM Mono, scaled). The bundle list and the Now Playing text
    /// are 20 pt, the BUNDLES heading 22; the item title keeps body size (29).
    static let normal = GuideTextMetrics(
        title: 20, timeLabel: 22, channelHeading: 22,
        number: 20, numberWidth: 36, name: 20, placeholder: 22,
        packageRowText: 20, packageHeading: 22,
        panelText: 20, panelTitle: NXType.body, panelTag: 28,
        rowHeight: 64, headerHeight: 58
    )

    /// A visible step down from DEFAULT, a bit more than the 2 pt DEFAULT took from 22 and 25 (Chad 2026-11-14: "the
    /// smaller should be smaller"; 18 and 20 read as a nudge on the Simulator): row text 17 pt (85% of 20), times,
    /// heading and placeholder 19 pt (86% of 22). The floor: one point is 1/1080 of the screen height, so 17 pt is
    /// 1.6% of it, a 12 px capital in DM Mono Medium, and below that the strokes get too thin to read from a couch.
    /// The box holds three digits at 17 pt (30.6 pt scaled, so 31). The Now Playing item title steps to 25 and the
    /// CH tag to 24.
    static let small = GuideTextMetrics(
        title: 17, timeLabel: 19, channelHeading: 19,
        number: 17, numberWidth: 31, name: 17, placeholder: 19,
        packageRowText: 17, packageHeading: 19,
        panelText: 17, panelTitle: 25, panelTag: 24,
        rowHeight: 64, headerHeight: 58
    )

    /// LARGER, what LARGE always was: the guide at body (29) everywhere, the channel column cannot widen so the name
    /// gives up characters to the ellipsis. The bundle list and the Now Playing panel stay at 22 pt, as they were
    /// at LARGE. Roku's LARGE is its own (GuideText.brs): the two no longer share numbers.
    static let large = GuideTextMetrics(
        title: NXType.body, timeLabel: NXType.body, channelHeading: NXType.body,
        number: NXType.body, numberWidth: 54, name: NXType.body, placeholder: NXType.body,
        packageRowText: 22, packageHeading: NXType.caption,
        panelText: 22, panelTitle: NXType.body, panelTag: 28,
        rowHeight: 76, headerHeight: 66
    )
}
