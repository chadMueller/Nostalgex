import SwiftUI
import Observation

// The views of the guide's package stripes (see `GuideStripes`).

/// The guide list's scroll position, for the sticky names. Only `GuideStripeOverlay` reads it, so a scroll
/// redraws the labels and not the guide.
@MainActor
@Observable
final class GuideScrollMetrics {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
}

struct GuideScrollSnapshot: Equatable {
    var offset: CGFloat
    var viewport: CGFloat
}

/// One row's piece of the stripe, drawn in the slot at the left of the row.
struct GuideStripeCell: View {
    let cell: GuideStripes.RowCell
    /// A row and its divider.
    let height: CGFloat
    let background: Color

    var body: some View {
        ZStack(alignment: .top) {
            if let hex = cell.hex {
                Color(hex: hex)
            } else {
                Color.white.opacity(0.10)
            }
            if cell.startsRun {
                background.frame(height: 2)
            }
        }
        .frame(width: GuideStripes.stripeWidth, height: height)
        .accessibilityHidden(true)
    }
}

/// The names written up the stripe, and the ring when the stripe has focus. Sticky: each name sits in the
/// part of its package that is on screen, so it stays readable while the viewer scrolls through the
/// package's channels. Never takes a touch or a focus; the stripe's own focus target is separate.
struct GuideStripeOverlay: View {
    let groups: [GuideStripeGroup]
    let rowPitch: CGFloat
    let leading: CGFloat
    let metrics: GuideScrollMetrics
    /// The run that is shown with the focus ring, while the stripe has focus.
    let focusedGroup: Int?

    private static let font = NXFont.captionMedium
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the focused stripe lifts out of its slot, over the row's left edge.
    private static let liftWidth: CGFloat = 38

    var body: some View {
        let labels = GuideStripes.labels(
            groups: groups, rowPitch: rowPitch, leading: leading, offset: metrics.offset, viewport: metrics.viewport
        )
        ZStack(alignment: .topLeading) {
            // The focused package lifts: brighter colour, wider than its slot, a heavy outline and a glow.
            if let focusedGroup, groups.indices.contains(focusedGroup), let name = groups[focusedGroup].name,
               let span = GuideStripes.visibleSpan(
                of: groups[focusedGroup], rowPitch: rowPitch, leading: leading, offset: metrics.offset, viewport: metrics.viewport
               ) {
                let lifted = GuideStripes.Palette.focusedHex(for: GuideStripes.Palette.hex(for: name))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: lifted))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color("BrandCyan"), lineWidth: 5)
                    )
                    .shadow(color: Color("BrandCyan").opacity(0.9), radius: 14)
                    .frame(width: Self.liftWidth, height: span.height)
                    .offset(y: span.top)
                    .transition(reduceMotion ? .identity : .opacity)
            }
            ForEach(labels, id: \.groupIndex) { label in
                let isFocusedLabel = label.groupIndex == focusedGroup
                let hex = isFocusedLabel
                    ? GuideStripes.Palette.focusedHex(for: GuideStripes.Palette.hex(for: label.name))
                    : GuideStripes.Palette.hex(for: label.name)
                Text(label.name)
                    .font(Self.font)
                    .tracking(1)
                    .foregroundStyle(GuideStripes.Palette.nameIsBlack(onHex: hex) ? Color.black : Color.nxText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: max(label.height - 16, 0), height: GuideStripes.stripeWidth)
                    .rotationEffect(.degrees(-90))
                    .frame(width: isFocusedLabel ? Self.liftWidth : GuideStripes.stripeWidth, height: label.height)
                    .offset(y: label.top)
            }
        }
        .frame(width: Self.liftWidth + 20, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focusedGroup)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
