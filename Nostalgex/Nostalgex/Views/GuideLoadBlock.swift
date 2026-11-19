import SwiftUI

/// The loading pattern's empty guide state (Chad, 2026-11-15; the same on every platform): while a library is read in
/// front of the guide (a server or library switch, RESCAN LIBRARY), the guide area holds one centred block. A yellow
/// title, what has been read so far in text-2, the library being read under it, and a cyan bar that moves. A stalled
/// read says so here too, with STOP WAITING, never over the video.
struct GuideLoadBlock: View {
    @Environment(AppState.self) private var appState
    @FocusState private var stopWaitingFocused: Bool

    private var detail: String {
        LoadNotice.detailLine(phase: appState.libraryLoadPhase, scanDetail: appState.guideLoadDetail)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text((appState.guideLoadInPlace ?? .loading).title)
                .font(NXFont.heading)
                .foregroundStyle(Color.nxYellow)
                .tracking(1)
                .lineLimit(1)
            if appState.scanItemsFound > 0 || appState.libraryLoadPhase > .scanningLibrary {
                Text(LoadNotice.readLine(read: appState.scanItemsFound))
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .lineLimit(1)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            GuideLoadBar()
                .padding(.top, 8)
            if appState.isLoadStalling {
                Text("Still waiting on your server. Nothing has come back for a while.")
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                // Takes focus as it appears, as on the full-screen loading view.
                Button("STOP WAITING") { appState.stopWaitingForLibraryScan() }
                    .buttonStyle(OnboardingButtonStyle(role: .primary, fullWidth: false, fontSize: 24))
                    .focused($stopWaitingFocused)
                    .onAppear {
                        // After the frame it appears in, or the focus engine keeps the focus it had.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { stopWaitingFocused = true }
                    }
                Text("Keeps whatever has loaded so far and finishes the rest later.")
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NXColor.guide.color)
        .accessibilityIdentifier("guideLoadBlock")
    }
}

/// A cyan segment sliding along a faint track: it moves while the read goes on, and says nothing it does not know.
private struct GuideLoadBar: View {
    @State private var forward = false
    private let track: CGFloat = 420
    private let segment: CGFloat = 120

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.15))
            Capsule().fill(Color.nxCyan)
                .frame(width: segment)
                .offset(x: forward ? track - segment : 0)
        }
        .frame(width: track, height: 4)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: true)) { forward = true }
        }
        .accessibilityHidden(true)
    }
}
