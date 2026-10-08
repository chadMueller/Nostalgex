import SwiftUI

/// The slate a station puts up when it cannot show you the programme.
///
/// It replaces a silent skip. Before this, a programme that would not play was simply
/// swapped for the next one, which from the sofa is indistinguishable from the app being
/// broken, and it hid the one fact the person needed: whether to go and look at their
/// server, or at the file.
///
/// Deliberately not a dialog. Nothing here is focusable, so the remote keeps working and
/// the card sits over the video the way the tuning static does. It clears itself when the
/// next programme starts.
struct PlaybackFailureCard: View {
    let failure: PlaybackFailure
    /// The windowed guide surface gets smaller type than the full-screen player.
    var compact: Bool = false

    /// Amber when the server is the thing to go and look at, red when the file or the
    /// device is. The colour is the fastest version of the same sentence.
    private var accent: Color {
        Color(hex: failure.isServerSide ? "#FFB020" : "#FF2244")
    }

    private var headlineSize: CGFloat { compact ? 26 : 38 }
    private var detailSize: CGFloat { compact ? 16 : 22 }
    private var nextSize: CGFloat { compact ? 13 : 17 }

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            Text(failure.headline)
                .font(.custom("DMMono-Medium", size: headlineSize))
                .foregroundStyle(accent)
                .multilineTextAlignment(.center)

            Text(failure.detail)
                .font(.custom("DMMono-Regular", size: detailSize))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: compact ? 520 : 900)

            Text("Moving on to the next programme.")
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
        .accessibilityLabel("\(failure.headline). \(failure.detail)")
    }
}
