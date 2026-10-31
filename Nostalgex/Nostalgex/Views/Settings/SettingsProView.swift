import SwiftUI

/// NOSTALGEX PRO: a status and showcase screen only. Pro-gated settings themselves
/// live in their own categories as locked rows (SettingsToggleRow.proLocked).
///
/// PLACEHOLDER (N-028): no StoreKit or entitlement code. Every line of copy here is a
/// stand-in until the real Pro copy exists. Do not ship this tab as it reads now: it
/// stays off the rail while `SettingsFeatures.showProTab` is off.
struct SettingsProView: View {
    let focus: FocusState<SettingsFocus?>.Binding
    @State private var showUpsell = false

    static let firstRowID = "pro_status"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsToggleRow(
                title: "PRO STATUS",
                subtitle: "Placeholder. Shows whether Pro is active on this Apple TV.",
                detail: "PLACEHOLDER",
                isOn: true,
                isFocused: isFocused("pro_status"),
                showToggle: false
            ) {
                showUpsell = true
            }
            .settingsRow("pro_status", focus: focus)

            SettingsSectionHeader(
                title: "LOCKED ROW EXAMPLE",
                subtitle: "How a Pro-only setting reads inside any category"
            )
            .padding(.top, 24)

            SettingsToggleRow(
                title: "EXAMPLE PRO SETTING",
                subtitle: "Placeholder row. Select opens the Pro screen instead of switching.",
                isOn: false,
                isFocused: isFocused("pro_example"),
                proLocked: true,
                onLockedTap: { showUpsell = true }
            ) {}
            .settingsRow("pro_example", focus: focus)
        }
        .sheet(isPresented: $showUpsell) {
            ProUpsellSheet()
        }
    }

    private func isFocused(_ id: String) -> Bool {
        focus.wrappedValue == .row(id)
    }
}

/// Where a locked row's select goes. PLACEHOLDER (N-028): nothing to buy, one button.
struct ProUpsellSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.10),
                    Color(red: 0.05, green: 0.05, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Text("NOSTALGEX PRO")
                        .font(.custom("DMMono-Medium", size: 40))
                        .foregroundStyle(.white)
                    ProLockBadge()
                }

                Text("Placeholder screen. Nothing can be bought here.")
                    .font(.custom("DMMono-Regular", size: 22))
                    .foregroundStyle(.white.opacity(0.7))

                SettingsToggleRow(
                    title: "CLOSE",
                    subtitle: nil,
                    isOn: true,
                    isFocused: closeFocused,
                    showToggle: false
                ) {
                    dismiss()
                }
                .focused($closeFocused)
                .frame(maxWidth: 520)
                .accessibilityIdentifier("proUpsellClose")
            }
            // Fill the sheet like the picker sheets do, instead of a small card.
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .defaultFocus($closeFocused, true)
    }
}
