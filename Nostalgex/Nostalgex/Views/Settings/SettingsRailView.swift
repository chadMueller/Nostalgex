import SwiftUI

/// The fixed left rail of the Settings screen (N-028). Same focus grammar as the
/// guide's BundleJumpSidebar (accent bar that thickens on focus, rounded glow
/// border, NoHighlightButtonStyle), in Settings' cyan instead of the guide's yellow.
///
/// No ScrollView: six rows fit on screen (five while the Pro tab is hidden), and a ScrollView would clip the glow at
/// its edges. Pro adds rows inside categories, not categories, so this stays short.
struct SettingsRailView: View {
    /// The category the detail pane is showing. Stays marked while focus is in the
    /// detail pane, so it is clear which tab the rows belong to.
    let selected: SettingsCategory
    let focus: FocusState<SettingsFocus?>.Binding
    /// Select on a rail row: move focus into that category's rows.
    let onActivate: (SettingsCategory) -> Void

    static let width: CGFloat = 470
    private static let rowHeight: CGFloat = 76
    private let accent = Color("BrandCyan")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETTINGS")
                .font(.custom("VT323-Regular", size: 44))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 40)
                .padding(.top, 70)
                .padding(.bottom, 24)

            VStack(spacing: 4) {
                ForEach(SettingsCategory.pinned) { category in
                    row(category)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)

                ForEach(SettingsCategory.unpinned) { category in
                    row(category)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                Color(red: 0.03, green: 0.03, blue: 0.08).opacity(0.95)
                RailScanlines()
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private func row(_ category: SettingsCategory) -> some View {
        let isFocused = focus.wrappedValue == .rail(category)
        let isSelected = selected == category

        return Button {
            onActivate(category)
        } label: {
            HStack(spacing: 18) {
                Rectangle()
                    .fill(isFocused || isSelected ? accent : accent.opacity(0.3))
                    .frame(width: isFocused ? 8 : (isSelected ? 6 : 4))

                Image(systemName: category.sfSymbolPlaceholder)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(isFocused || isSelected ? .white : .white.opacity(0.6))

                Text(category.title)
                    .font(.custom("DMMono-Medium", size: 24))
                    .foregroundStyle(isFocused || isSelected ? .white : .white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)
            }
            .padding(.trailing, 16)
            .frame(height: Self.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isFocused ? accent.opacity(0.22)
                            : (isSelected ? Color.white.opacity(0.06) : .clear)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accent, lineWidth: 3)
                        .shadow(color: accent.opacity(0.7), radius: 14)
                }
            }
            .zIndex(isFocused ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isFocused)
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused(focus, equals: .rail(category))
        .accessibilityIdentifier("settingsRail_\(category.rawValue)")
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A very faint scanline texture for the rail background only (never over rows or
/// hero art). White lines, because CRTOverlayView's black ones vanish on this navy.
private struct RailScanlines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.white.opacity(0.05))
                )
                y += 4
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
