import SwiftUI
import os

/// The "Enjoying Nostalgex?" banner below the guide.
///
/// It takes focus when it appears, landing on RATE so rating is one press (owner's
/// call, 2026-10-13: "make it easy to rate"). Any way out (NOT NOW, RATE, Up back to
/// the guide, Menu, or 8 untouched seconds) dismisses it, and AppState then puts focus
/// back on the live channel row. Moving between the two buttons counts as touching it
/// and stops the timer. Whether it may appear at all is `RatingNudgePolicy`'s call.
struct RatingNudgeBanner: View {
    @Environment(AppState.self) var appState
    @Environment(\.openURL) private var openURL
    @FocusState private var focused: Choice?

    private enum Choice: Hashable { case rate, notNow }

    private static let log = Logger(subsystem: "com.muellhaus.nostalgex", category: "rating")

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Enjoying Nostalgex?")
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(.white)
                Text("A star rating helps other people find it. Back brings you right here.")
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.8))
                if RatingNudgePolicy.showsScrollHint {
                    Text(RatingNudgePolicy.scrollHint)
                        .font(.custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            Spacer(minLength: 24)

            HStack(spacing: 16) {
                choiceButton("RATE", choice: .rate) {
                    appState.ratingNudgeRateTapped()
                    let variant = AppStoreLink.activeVariant
                    let url = variant.url
                    openURL(url) { accepted in
                        print("[Plex90] Rating nudge: RATE opened variant=\(variant.rawValue) \(url.absoluteString) accepted=\(accepted)")
                        Self.log.notice("RATE opened variant=\(variant.rawValue, privacy: .public) \(url.absoluteString, privacy: .public) accepted=\(accepted, privacy: .public)")
                        Analytics.track(.ratingNudgeOpened(accepted: accepted, variant: variant.rawValue))
                    }
                }
                .accessibilityIdentifier("ratingNudgeRate")
                .accessibilityHint("Opens Nostalgex in the App Store to leave a star rating")

                choiceButton("NOT NOW", choice: .notNow) {
                    appState.dismissRatingNudge()
                }
                .accessibilityIdentifier("ratingNudgeNotNow")
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .frame(maxWidth: 1240)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.12).opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color("BrandCyan").opacity(focused == nil ? 0.25 : 0.5), lineWidth: 1.5)
        )
        .focusSection()
        .defaultFocus($focused, .rate)
        .onAppear {
            // The safe default. On hardware a single async request was not enough:
            // the banner slides in and the guide restores its own focus on the way back
            // from fullscreen, so ask again until it lands (or the banner is gone).
            requestFocus(attempt: 0)
        }
        .onChange(of: focused) { oldValue, newValue in
            print("[Plex90] Rating nudge focus: \(String(describing: oldValue)) -> \(String(describing: newValue))")
            switch (oldValue, newValue) {
            case (.some(let from), .some(let to)) where from != to:
                // The viewer moved between the buttons: they are deciding, so stop the clock.
                appState.ratingNudgeDismissTask?.cancel()
            case (.some, .none):
                // Focus left the banner (Up to the guide): that is a no.
                appState.dismissRatingNudge()
            default:
                break
            }
        }
        .onExitCommand { appState.dismissRatingNudge() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ratingNudgeBanner")
    }

    /// Tries at 0, 0.35 and 0.9 seconds: after the slide-in transition and after the
    /// guide's own return-from-fullscreen focus restore. Stops once focus is on the banner.
    private func requestFocus(attempt: Int) {
        let delays: [Double] = [0, 0.35, 0.9]
        guard attempt < delays.count else {
            print("[Plex90] Rating nudge focus: gave up, focused=\(String(describing: focused))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            guard appState.isRatingNudgeVisible else { return }
            if focused == nil { focused = .rate }
            print("[Plex90] Rating nudge focus: attempt \(attempt + 1), focused=\(String(describing: focused))")
            if focused == nil { requestFocus(attempt: attempt + 1) }
        }
    }

    private func choiceButton(_ title: String, choice: Choice, action: @escaping () -> Void) -> some View {
        let isFocused = focused == choice
        return Button(action: action) {
            Text(title)
                .font(.custom("DMMono-Medium", size: 22))
                .foregroundStyle(isFocused ? .white : .white.opacity(0.6))
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isFocused ? .white.opacity(0.10) : .white.opacity(0.02))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isFocused ? Color("BrandCyan") : .clear, lineWidth: 3)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focused, equals: choice)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
