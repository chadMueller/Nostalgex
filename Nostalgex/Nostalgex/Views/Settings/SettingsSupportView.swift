import SwiftUI
import StoreKit

/// SUPPORT NOSTALGEX: RATE plus the tip tiles, or RATE alone when tips are unavailable.
struct SettingsSupportView: View {
    @Environment(AppState.self) var appState
    @Environment(\.openURL) private var openURL
    let focus: FocusState<SettingsFocus?>.Binding

    private let tipJar = TipJar.shared
    /// The tip tile picked, which opens the quantity sheet.
    @State private var tipToConfirm: Product?
    /// Set by TIP in the quantity sheet; the purchase starts once the sheet is gone.
    @State private var pendingTip: (product: Product, quantity: Int)?

    static let firstRowID = "rate"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showTips {
                supportGrid
            } else {
                // RATE alone keeps the full-width row it always had.
                SettingsToggleRow(
                    title: "RATE NOSTALGEX",
                    subtitle: appState.hasTappedRate ? "Thanks for rating. Rate again anytime" : "Opens the App Store on your Apple TV",
                    isOn: true,
                    isFocused: isFocused("rate"),
                    showToggle: false
                ) {
                    rateTapped()
                }
                .settingsRow("rate", focus: focus)
                .accessibilityHint("Opens Nostalgex in the App Store to leave a star rating")
            }
        }
        .fullScreenCover(item: $tipToConfirm, onDismiss: {
            guard let tip = pendingTip else { return }
            pendingTip = nil
            Task { await tipJar.purchase(tip.product, quantity: tip.quantity) }
        }) { product in
            TipQuantityView(
                product: product,
                onConfirm: { quantity in
                    pendingTip = (product, quantity)
                    tipToConfirm = nil
                },
                onCancel: { tipToConfirm = nil }
            )
        }
    }

    private func isFocused(_ id: String) -> Bool {
        focus.wrappedValue == .row(id)
    }

    /// Tips never show in demo mode, and never as an error: no products, no tiles.
    private var showTips: Bool {
        !appState.isDemoMode && tipJar.tipsAvailable
    }

    private func rateTapped() {
        Analytics.track(.rateTapped)
        appState.recordRatingTapped()
        openURL(AppStoreLink.productPage)
    }

    /// RATE plus the three tips as one row of four equal tiles.
    @ViewBuilder
    private var supportGrid: some View {
        Text("Tips help keep Nostalgex maintained.")
            .font(.custom("DMMono-Regular", size: 20))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 24) {
            SupportTile(
                art: PixelIcons.star,
                title: "RATE NOSTALGEX",
                caption: appState.hasTappedRate ? "Thanks for rating" : "Leave a star rating",
                isFocused: isFocused("rate")
            ) {
                rateTapped()
            }
            .settingsRow("rate", focus: focus)
            .accessibilityHint("Opens Nostalgex in the App Store to leave a star rating")

            ForEach(tipJar.products, id: \.id) { product in
                if let tip = TipProduct(rawValue: product.id) {
                    SupportTile(
                        art: PixelIcons.art(for: tip),
                        title: tip.rowTitle,
                        caption: product.displayPrice,
                        captionIsPrice: true,
                        isFocused: isFocused(tip.focusID)
                    ) {
                        guard !tipJar.isPurchasing else { return }
                        tipToConfirm = product
                    }
                    .settingsRow(tip.focusID, focus: focus)
                    .accessibilityHint("\(product.displayPrice) each. Choose how many, then tip. Unlocks nothing.")
                }
            }
        }

        if let line = tipJar.statusLine {
            Text(line)
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 24)
        }
    }
}
