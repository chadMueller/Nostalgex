import SwiftUI

/// The slate a station puts up during the watershed: this channel has real content, every
/// bit of it is 18/R-rated (or stronger) right now, and the Watershed setting is holding it
/// until 9 PM. See `PlaybackFailureCard`, which this deliberately echoes — same card, same
/// type, different tone: this is not a failure, nothing is broken, and there is nothing to
/// go and look at. It clears itself the moment the gate lifts or the viewer turns the
/// setting off.
struct WatershedCard: View {
    /// The windowed guide surface gets smaller type than the full-screen player.
    var compact: Bool = false

    private let accent = Color("BrandCyan")

    private var headlineSize: CGFloat { compact ? 26 : 38 }
    private var detailSize: CGFloat { compact ? 16 : 22 }
    private var nextSize: CGFloat { compact ? 13 : 17 }

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            Text("BROADCASTS WILL RESUME AT 9 PM")
                .font(.custom("DMMono-Medium", size: headlineSize))
                .foregroundStyle(accent)
                .multilineTextAlignment(.center)

            Text("This channel's 18 and R-rated titles wait for 9 PM, like broadcast TV. Everything in its pool right now falls in that window.")
                .font(.custom("DMMono-Regular", size: detailSize))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: compact ? 520 : 900)

            Text("Turn off Watershed in Settings to watch now.")
                .font(.custom("DMMono-Regular", size: nextSize))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, compact ? 32 : 72)
        .padding(.vertical, compact ? 28 : 48)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 14)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 10 : 14)
                        .stroke(accent.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(compact ? 24 : 60)
        // The card states a fact and leaves; VoiceOver should read it as one sentence.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Broadcasts will resume at 9 PM. This channel's 18 and R-rated titles wait for 9 PM, like broadcast TV.")
    }
}
