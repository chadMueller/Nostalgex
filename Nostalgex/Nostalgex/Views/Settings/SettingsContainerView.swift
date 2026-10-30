import SwiftUI
import AVFoundation
import StoreKit

/// Settings as a rail plus a detail pane (N-028, Phase 1). Replaces the flat
/// SettingsPageView as what AppDestination.settings pushes.
///
/// Mechanics this phase exists to prove:
/// - Up/down on the rail swaps the detail pane's hero and title live, no press.
/// - Right or select moves focus into the category's rows.
/// - Menu from the rows returns focus to the rail; Menu from the rail leaves Settings.
/// - Left from the rows lands back on the selected tab, not whichever tab is level with
///   the row, so the pane never swaps under you on the way out.
///
/// Phase 1 content: SUPPORT NOSTALGEX and PLAYBACK & PICTURE carry their real rows
/// (same AppState fields and Analytics calls as SettingsPageView). The other four are
/// placeholders. Hero art is an SF Symbol until Phase 3.
struct SettingsContainerView: View {
    @Environment(AppState.self) var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: SettingsFocus?
    @State private var selected: SettingsCategory = .support

    // Playback
    @State private var streamQuality = StreamQuality.current
    @AppStorage(LocalPlexOriginalQuality.storageKey) private var localOriginalVideo = false
    @State private var showStreamQualityPicker = false
    @State private var showSubtitleLanguagePicker = false
    @State private var showAudioLanguagePicker = false

    // Support
    private let tipJar = TipJar.shared
    /// The tip tile picked, which opens the quantity sheet.
    @State private var tipToConfirm: Product?
    /// Set by TIP in the quantity sheet; the purchase starts once the sheet is gone.
    @State private var pendingTip: (product: Product, quantity: Int)?

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

            HStack(spacing: 0) {
                SettingsRailView(selected: selected, focus: $focus) { category in
                    activate(category)
                }
                .focusSection()
                .defaultFocus($focus, .rail(selected), priority: .userInitiated)

                detailPane
                    .focusSection()
                    .defaultFocus($focus, .row(firstRowID(for: selected)), priority: .userInitiated)
                    .onExitCommand {
                        // Only reached while a row has focus; Menu on the rail is not
                        // handled here, so the NavigationStack pops as before.
                        focus = .rail(selected)
                    }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($focus, .rail(.support))
        .onChange(of: focus) { _, newFocus in
            guard case .rail(let category)? = newFocus, category != selected else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                selected = category
            }
        }
        .onAppear {
            appState.player?.isMuted = true
        }
        .onDisappear {
            appState.player?.isMuted = false
        }
        .task {
            // Tip tiles stay hidden until (and unless) StoreKit returns the products.
            guard !appState.isDemoMode else { return }
            await tipJar.loadProductsIfNeeded()
        }
        .onChange(of: appState.hasCredentials) { _, has in
            if !has { dismiss() }
        }
        .sheet(isPresented: $showStreamQualityPicker) {
            StreamQualityPickerSheet(selected: streamQuality, allowsOriginal: appState.backendKind == .plex) { picked in
                if picked != streamQuality {
                    Analytics.track(.settingChanged(key: "stream_quality", value: picked.rawValue))
                }
                StreamQuality.current = picked
                streamQuality = picked
                appState.preferenceSync.record(PreferenceSync.streamQualityKey, value: picked.rawValue)
            }
        }
        .sheet(isPresented: $showSubtitleLanguagePicker) {
            SubtitleLanguagePickerSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showAudioLanguagePicker) {
            AudioLanguagePickerSheet()
                .environment(appState)
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

    // MARK: - Focus

    private func activate(_ category: SettingsCategory) {
        selected = category
        focus = .row(firstRowID(for: category))
    }

    private func firstRowID(for category: SettingsCategory) -> String {
        switch category {
        case .support: return "rate"
        case .playback: return "retro"
        default: return placeholderID(category)
        }
    }

    private func placeholderID(_ category: SettingsCategory) -> String {
        "placeholder_\(category.rawValue)"
    }

    private func isFocused(_ id: String) -> Bool {
        focus == .row(id)
    }

    // MARK: - Detail pane

    /// Scrolls vertically on its own; the rail never moves. Pro will add 10 to 15
    /// rows across categories, so nothing here assumes a category fits on screen.
    private var detailPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 44) {
                    hero
                        .id("hero")

                    VStack(alignment: .leading, spacing: 20) {
                        detailContent
                    }
                    .id(selected)
                    .transition(.opacity)
                }
                .padding(.horizontal, 80)
                .padding(.top, 70)
                .padding(.bottom, 80)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: focus) { _, newFocus in
                guard case .row(let id)? = newFocus else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: selected) { _, _ in
                proxy.scrollTo("hero", anchor: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Placeholder hero: a 16:9 tile holding the category's SF Symbol, sized like the
    /// Phase 3 illustration will be, with the title and one line beside it.
    private var hero: some View {
        HStack(alignment: .center, spacing: 44) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                Image(systemName: selected.sfSymbolPlaceholder)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .foregroundStyle(selected.heroTint)
                    .id(selected)
                    .transition(.opacity)
            }
            .frame(width: 400, height: 225)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text(selected.title)
                    .font(.custom("DMMono-Medium", size: 44))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(selected.subtitle)
                    .font(.custom("DMMono-Regular", size: 22))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(selected)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settingsHeroTitle")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selected {
        case .support:
            supportContent
        case .playback:
            playbackContent
        case .channels, .servers, .pro, .about:
            placeholderContent(selected)
        }
    }

    // MARK: - Support

    /// Tips never show in demo mode, and never as an error: no products, no tiles.
    private var showTips: Bool {
        !appState.isDemoMode && tipJar.tipsAvailable
    }

    private func rateTapped() {
        Analytics.track(.rateTapped)
        appState.recordRatingTapped()
        openURL(AppStoreLink.productPage)
    }

    @ViewBuilder
    private var supportContent: some View {
        if showTips {
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
                .focused($focus, equals: .row("rate"))
                .id("rate")
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
                        .focused($focus, equals: .row(tip.focusID))
                        .id(tip.focusID)
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
        } else {
            SettingsToggleRow(
                title: "RATE NOSTALGEX",
                subtitle: appState.hasTappedRate ? "Thanks for rating. Rate again anytime" : "Opens the App Store on your Apple TV",
                isOn: true,
                isFocused: isFocused("rate"),
                showToggle: false
            ) {
                rateTapped()
            }
            .focused($focus, equals: .row("rate"))
            .id("rate")
            .accessibilityHint("Opens Nostalgex in the App Store to leave a star rating")
        }
    }

    // MARK: - Playback

    @ViewBuilder
    private var playbackContent: some View {
        SettingsToggleRow(
            title: "RETRO MODE",
            subtitle: "CRT scanlines, vignette, VHS glitch, 4:3 aspect ratio",
            isOn: appState.retroMode,
            isFocused: isFocused("retro")
        ) {
            appState.retroMode.toggle()
        }
        .focused($focus, equals: .row("retro"))
        .id("retro")

        SettingsToggleRow(
            title: "STREAM QUALITY",
            subtitle: "Lower this when your connection is slow or shared",
            detail: localOriginalVideo && appState.backendKind == .plex ? "Original (local Plex)" : streamQuality.displayName,
            isOn: true,
            isFocused: isFocused("stream_quality"),
            showToggle: false
        ) {
            showStreamQualityPicker = true
        }
        .focused($focus, equals: .row("stream_quality"))
        .id("stream_quality")

        // One row: Off, then foreign audio only, then always. Same as the old page.
        SettingsToggleRow(
            title: "SUBTITLES",
            subtitle: subtitleModeExplanation,
            detail: subtitleModeLabel,
            isOn: true,
            isFocused: isFocused("sub_mode"),
            showToggle: false
        ) {
            cycleSubtitleMode()
        }
        .focused($focus, equals: .row("sub_mode"))
        .id("sub_mode")

        if appState.subtitlesInFullscreenEnabled || appState.autoSubtitlesForForeignAudioEnabled {
            SettingsToggleRow(
                title: "SUBTITLE LANGUAGE",
                subtitle: "When the video has multiple subtitle tracks, prefer this language",
                detail: SubtitleLanguagePreset.displayLabel(for: appState.preferredSubtitleLanguageCode),
                isOn: true,
                isFocused: isFocused("sub_lang"),
                showToggle: false
            ) {
                showSubtitleLanguagePicker = true
            }
            .focused($focus, equals: .row("sub_lang"))
            .id("sub_lang")
        }

        SettingsToggleRow(
            title: "AUDIO LANGUAGE",
            subtitle: "When the video has multiple audio tracks, prefer this language",
            detail: SubtitleLanguagePreset.displayLabel(for: appState.preferredAudioLanguageCode),
            isOn: true,
            isFocused: isFocused("audio_lang"),
            showToggle: false
        ) {
            showAudioLanguagePicker = true
        }
        .focused($focus, equals: .row("audio_lang"))
        .id("audio_lang")
    }

    private var subtitleModeLabel: String {
        if appState.subtitlesInFullscreenEnabled { return "ALWAYS" }
        if appState.autoSubtitlesForForeignAudioEnabled { return "FOREIGN AUDIO" }
        return "OFF"
    }

    private var subtitleModeExplanation: String {
        if appState.subtitlesInFullscreenEnabled { return "Shown in fullscreen whenever the video has them" }
        if appState.autoSubtitlesForForeignAudioEnabled { return "Shown in fullscreen when the audio isn't in your language" }
        return "Never shown. Press to change"
    }

    /// Off, then foreign audio only, then always, then back to off.
    private func cycleSubtitleMode() {
        if appState.subtitlesInFullscreenEnabled {
            appState.subtitlesInFullscreenEnabled = false
            appState.autoSubtitlesForForeignAudioEnabled = false
        } else if appState.autoSubtitlesForForeignAudioEnabled {
            appState.subtitlesInFullscreenEnabled = true
        } else {
            appState.autoSubtitlesForForeignAudioEnabled = true
        }
    }

    // MARK: - Placeholder categories

    /// Focusable, so right, select and Menu can be tried on every tab in Phase 1.
    private func placeholderContent(_ category: SettingsCategory) -> some View {
        let id = placeholderID(category)
        return SettingsToggleRow(
            title: "COMING IN PHASE 2",
            subtitle: "This tab's settings move here in the next step",
            isOn: true,
            isFocused: isFocused(id),
            showToggle: false
        ) {}
        .focused($focus, equals: .row(id))
        .id(id)
    }
}
