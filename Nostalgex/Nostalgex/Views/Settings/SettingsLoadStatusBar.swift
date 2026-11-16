import SwiftUI

/// The loading pattern's status line at the foot of SERVERS & ACCOUNTS and CHANNELS & BUNDLES (`SettingsLoadStatus`).
/// Not focusable and not in the scroll, so it never moves a row or takes focus; it sits over the pane's bottom margin.
struct SettingsLoadStatusBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let status = SettingsLoadStatus.current(
            inPlaceLoad: appState.isLoading && appState.guideLoadInPlace != nil,
            backgroundRefresh: appState.isBackgroundRefreshing,
            phase: appState.libraryLoadPhase,
            titlesRead: appState.scanItemsFound,
            scanDetail: appState.guideLoadDetail,
            readyTitles: appState.guideReadyTitles)
        Group {
            if let status {
                HStack(spacing: 28) {
                    Text(status.title)
                        .font(NXFont.captionMedium)
                        .foregroundStyle(Color.nxYellow)
                        .lineLimit(1)
                    if let read = status.readLine {
                        Text(read).font(NXFont.captionRegular).foregroundStyle(Color.nxText2).lineLimit(1)
                    }
                    if let detail = status.detailLine {
                        Text(detail).font(NXFont.captionRegular).foregroundStyle(Color.nxText2.opacity(0.8))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .frame(height: 56)
                .background(RoundedRectangle(cornerRadius: NXLayout.rowRadius).fill(Color(red: 0.04, green: 0.06, blue: 0.12)))
                .overlay(RoundedRectangle(cornerRadius: NXLayout.rowRadius).stroke(Color.nxCyan.opacity(0.5), lineWidth: 1.5))
                .padding(.horizontal, 72)
                .padding(.bottom, 8)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settingsLoadStatus")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: status)
        .allowsHitTesting(false)
    }
}
