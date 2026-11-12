import SwiftUI

// Shared building blocks for the Settings screen (N-028). Moved here from the old
// BundleManagerView.swift, which held the flat SettingsPageView; that page is gone.

// MARK: - Link row (drills into a sub-page)

/// A row that opens a sub-page inside the detail pane: title on the left, its current
/// value and a chevron on the right, e.g. CHANNEL PACKAGES   15 ON  >. Same chrome as
/// SettingsToggleRow.
struct SettingsLinkRow: View {
    let title: String
    var subtitle: String? = nil
    let value: String
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SettingsFont.bodyMedium)
                        .foregroundStyle(Color.nxText)
                    if let subtitle {
                        Text(subtitle)
                            .font(NXFont.captionRegular)
                            .foregroundStyle(Color.nxText2)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(value)
                    .font(SettingsFont.bodyMedium)
                    .foregroundStyle(isFocused ? Color.nxCyan : Color.nxText2)

                Image(systemName: "chevron.right")
                    .font(SettingsFont.icon)
                    .foregroundStyle(isFocused ? Color.nxCyan : Color.nxText2)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .nxRowSurface(isSelected: isFocused)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// I-004: one channel's plain-language explainer on the MISSING CHANNELS page.
/// Read-only, but focusable so up and down walk through the cards. Focus comes from
/// the page's shared focus binding (`settingsRow`), like every other Settings row, so
/// the pane scrolls to it and Menu steps back from it the same way.
struct ChannelRequirementCard: View {
    let channel: Channel
    /// nil while the page is still counting.
    let matchedCount: Int?
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(channel.color)
                    .frame(width: 4, height: 16)
                Text(channel.name.uppercased())
                    .font(NXFont.captionMedium)
                    .foregroundStyle(Color.nxText)
            }

            Text(matchedCount.map { "Needs \(channel.minItems) matching title\(channel.minItems == 1 ? "" : "s"). You have \($0)." }
                 ?? "Needs \(channel.minItems) matching title\(channel.minItems == 1 ? "" : "s"). Counting yours…")
                .font(NXFont.captionRegular)
                .foregroundStyle(Color.nxAmber)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array((channel.rules?.plainLanguageRequirements ?? []).enumerated()), id: \.offset) { _, line in
                Text("\u{2022} \(line)")
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nxRowSurface(isSelected: isFocused)
        .focusable(true)
        .animation(.easeInOut(duration: 0.12), value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("channelRequirementCard_\(channel.id)")
    }
}

// MARK: - Franchises: ADD ALL / REMOVE ALL

/// Half-width action row for the found-franchise block. Same chrome as
/// SettingsToggleRow (DMMono, cyan focus stroke), no switch, dims when it has nothing
/// left to do so the pair reads as a state as much as a control.
struct FranchiseActionButton: View {
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SettingsFont.bodyMedium)
                    .foregroundStyle(isEnabled ? Color.nxText : Color.nxText2)
                Text(subtitle)
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .nxRowSurface(isSelected: isFocused)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Support tile

/// One of the four SUPPORT NOSTALGEX tiles: a pixel icon, a title and one short line.
/// Focus is the shared row surface (`nxRowSurface`): cyan outline, glow and a small lift.
struct SupportTile: View {
    let art: PixelArt
    let title: String
    let caption: String
    /// A price reads in the title weight so it stays legible from the couch.
    var captionIsPrice: Bool = false
    /// A third line under the caption, when there is something to say after the press.
    var hint: String? = nil
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                PixelIconView(art: art, size: 80)

                VStack(spacing: 5) {
                    Text(title)
                        .font(SettingsFont.bodyMedium)
                        .foregroundStyle(Color.nxText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)

                    Text(caption)
                        .font(captionIsPrice ? SettingsFont.bodyMedium : NXFont.captionRegular)
                        .foregroundStyle(captionIsPrice ? Color.nxText : Color.nxText2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                    if let hint {
                        Text(hint)
                            .font(NXFont.captionRegular)
                            .foregroundStyle(Color.nxText2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("supportTileHint")
                    }
                }
            }
            // maxHeight too: the RATE tile carries a three-line instruction, and the tips beside it
            // grow to the same height instead of floating at their own.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .nxRowSurface(isSelected: isFocused)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .accessibilityLabel(title)
        .accessibilityValue(caption)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Rate row

/// RATE NOSTALGEX as one full-width row above the tip tiles: the star on the left, the name and a
/// short line side by side, and the instruction under them. Same row surface and selected state as
/// every other Settings row. The focus id and the action belong to the caller (`SettingsSupportView`),
/// so the one RATE path (`AppStoreLink.openRate`) is the same one the rating banner uses.
struct SupportRateRow: View {
    let art: PixelArt
    let title: String
    let caption: String
    /// The line under the title: where the stars are. Nil when the viewer has seen it enough.
    var hint: String? = nil
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 22) {
                PixelIconView(art: art, size: 60)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        Text(title)
                            .font(SettingsFont.bodyMedium)
                            .foregroundStyle(Color.nxText)
                            .lineLimit(1)
                        Text(caption)
                            .font(SettingsFont.bodyRegular)
                            .foregroundStyle(Color.nxText2)
                            .lineLimit(1)
                    }
                    if let hint {
                        Text(hint)
                            .font(NXFont.captionRegular)
                            .foregroundStyle(Color.nxText2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("supportTileHint")
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(SettingsFont.icon)
                    .foregroundStyle(isFocused ? Color.nxCyan : Color.nxText2)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nxRowSurface(isSelected: isFocused)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .accessibilityLabel(title)
        .accessibilityValue(caption)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Toggle Row

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String?
    /// How many lines the subtitle may take. Two for every row, which is all a one-line
    /// description needs; nil lets a row whose subtitle is text a viewer has to read in
    /// full (RESCAN LIBRARY's counts, which a support report quotes) take what it needs.
    var subtitleLineLimit: Int? = 2
    var detail: String? = nil
    /// A price has to be readable; the default detail is a faint annotation.
    var detailIsProminent: Bool = false
    var warning: String? = nil
    /// A small amber count beside the detail, e.g. channels still short of content. No
    /// text on screen; `alertBadgeLabel` is what VoiceOver reads for it.
    var alertBadge: Int? = nil
    var alertBadgeLabel: String? = nil
    /// A package's channel names (#217). The row grows to list them under its description
    /// while it has focus, and shrinks back when focus leaves. Nil for every other row.
    var channelNames: PackageChannelListing? = nil
    let isOn: Bool
    let isFocused: Bool
    var isLoading: Bool = false
    var loadingMessage: String? = nil
    var showToggle: Bool = true
    /// ON or OFF in words beside the switch (#232), so the state does not rest on the switch's colour alone.
    /// Off for the rows whose detail already says it (INCLUDED, OFF).
    var showStateText: Bool = true
    /// Pro-only row: a lock and a PRO pill replace the switch, and select calls
    /// onLockedTap instead of onToggle. Off by default, so existing rows are unchanged.
    var proLocked: Bool = false
    var onLockedTap: (() -> Void)? = nil
    let onToggle: () -> Void

    /// How long a row takes to grow or shrink when focus arrives or leaves. The Settings pane waits this long
    /// (and a little more) before it places a package row, so it never measures a row that is still growing.
    static let focusAnimationDuration: Double = 0.15

    var body: some View {
        Button {
            if proLocked {
                onLockedTap?()
            } else {
                onToggle()
            }
        } label: {
            HStack(spacing: 14) {
                // Label
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SettingsFont.bodyMedium)
                        .foregroundStyle(isOn ? Color.nxText : Color.nxText2)

                    if let subtitle {
                        Text(subtitle)
                            .font(NXFont.captionRegular)
                            .foregroundStyle(Color.nxText2)
                            .lineLimit(subtitleLineLimit)
                    }

                    if let warning {
                        Text(warning)
                            .font(NXFont.captionRegular)
                            .foregroundStyle(Color.nxAmber)
                            .lineLimit(2)
                    }

                    if isFocused, let channelNames, !channelNames.entries.isEmpty {
                        PackageChannelNames(listing: channelNames, isOn: isOn)
                            .padding(.top, 5)
                    }
                }

                Spacer()

                // Detail text or loading message
                if isLoading, let msg = loadingMessage {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Color("BrandCyan"))
                        Text(msg)
                            .font(NXFont.captionRegular)
                            .foregroundStyle(Color.nxCyan)
                    }
                } else if isLoading {
                    ProgressView()
                        .tint(Color("BrandCyan"))
                } else {
                    if let alertBadge {
                        AlertCountBadge(count: alertBadge)
                    }
                    if let detail {
                        Text(detail)
                            .font(SettingsFont.bodyMedium)
                            .foregroundStyle(
                                detailIsProminent ? Color.nxText2
                                    : isFocused ? Color.nxCyan : Color.nxText2
                            )
                    }
                }

                // Toggle switch (hidden while loading or when showToggle is false)
                if proLocked {
                    ProLockBadge()
                } else if !isLoading && showToggle {
                    HStack(spacing: 12) {
                        if showStateText {
                            // Fixed width, so the switches line up down the pane.
                            Text(isOn ? "ON" : "OFF")
                                .font(NXFont.captionMedium)
                                .foregroundStyle(isOn ? Color.nxCyan : Color.nxText2)
                                .frame(width: 52, alignment: .trailing)
                                .accessibilityHidden(true)
                        }
                        ToggleSwitch(isOn: isOn)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .nxRowSurface(isSelected: isFocused)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .accessibilityLabel(alertBadgeLabel.map { "\(title). \($0)" } ?? title)
        .accessibilityValue(proLocked ? "Pro only" : (isOn ? "On" : "Off"))
        .accessibilityHintIfPresent(channelNames?.spokenChannels)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .animation(.easeInOut(duration: Self.focusAnimationDuration), value: isFocused)
    }
}

// MARK: - Optional accessibility hint

extension View {
    /// Applies `accessibilityHint` only when there is a hint. With nil the view comes back as it was,
    /// so a row that has none (every `SettingsToggleRow` but a package row) is not touched, and a hint a
    /// caller sets on it afterwards is the only one.
    @ViewBuilder
    func accessibilityHintIfPresent(_ hint: String?) -> some View {
        if let hint, !hint.isEmpty {
            accessibilityHint(hint)
        } else {
            self
        }
    }
}

// MARK: - Alert count badge

/// An amber circle with a number in it, notification style: something on this row needs
/// a look. Sized to read from the couch next to a row's detail text.
struct AlertCountBadge: View {
    let count: Int
    private let amber = Color.nxAmber

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(NXFont.captionMedium)
            .foregroundStyle(Color.nxOnCyan)
            .padding(.horizontal, count > 9 ? 9 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(Capsule().fill(amber))
            .accessibilityHidden(true)
    }
}

// MARK: - Pro lock badge

/// A lock and a PRO pill, in amber so Pro reads apart from the free rows' cyan.
struct ProLockBadge: View {
    private let amber = Color.nxAmber

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 19)
                .foregroundStyle(amber)
            Text("PRO")
                .font(SettingsFont.tag)
                .foregroundStyle(amber)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .overlay(Capsule().stroke(amber.opacity(0.8), lineWidth: 1.5))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Section header and divider

/// A section inside a category's rows, e.g. SCHEDULE under CHANNELS & BUNDLES.
struct SettingsSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SettingsFont.heading)
                .foregroundStyle(Color.nxText2)
            if let subtitle {
                Text(subtitle)
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.06))
            .frame(height: 1)
    }
}

/// A small caption above a run of rows, e.g. SERVERS and LIBRARIES.
struct SettingsSubheader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NXFont.captionRegular)
            .foregroundStyle(Color.nxText2)
            .padding(.top, 4)
    }
}

// MARK: - Toggle Switch

struct ToggleSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Track
            Capsule()
                .fill(isOn ? Color("BrandCyan").opacity(0.3) : .white.opacity(0.1))
                .frame(width: 44, height: 26)
                .overlay(
                    Capsule()
                        .stroke(isOn ? Color("BrandCyan").opacity(0.5) : .white.opacity(0.15), lineWidth: 1)
                )

            // Thumb
            Circle()
                .fill(isOn ? Color("BrandCyan") : .white.opacity(0.7))
                .frame(width: 20, height: 20)
                .padding(3)
        }
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .accessibilityHidden(true)
    }
}

// MARK: - Enrichment Progress (isolated to limit redraw blast radius)

struct EnrichmentStatusView: View {
    let enrichmentService: EnrichmentService

    var body: some View {
        if enrichmentService.isEnriching {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ENRICHMENT")
                        .font(SettingsFont.heading)
                        .foregroundStyle(Color.nxText2)
                    Text("Improving channel accuracy with TMDB + OMDb metadata")
                        .font(NXFont.captionRegular)
                        .foregroundStyle(Color.nxText2)
                }

                HStack(spacing: 14) {
                    ProgressView(value: enrichmentService.progress)
                        .progressViewStyle(.linear)
                        .tint(Color("BrandCyan"))
                        .focusable(false)

                    Text("\(enrichmentService.enrichedCount)/\(enrichmentService.totalToEnrich)")
                        .font(NXFont.captionMedium)
                        .foregroundStyle(Color.nxText2)
                }
            }
        }
    }
}

// MARK: - Button Style

struct SettingsButtonStyle: ButtonStyle {
    let isFocused: Bool
    var accentColor: Color = Color("BrandCyan")

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Subtitle language preset list
//
// `SubtitleLanguagePreset` now lives in Models/: the in-player Now Playing panel offers
// the same two language settings and has to render the same labels.

struct LanguagePickerSheet: View {
    let title: String
    let subtitle: String
    let presets: [SubtitleLanguagePreset]
    let selectedCode: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedID: String?

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

            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(SettingsFont.heading)
                    .foregroundStyle(Color.nxText2)

                Text(subtitle)
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(presets) { preset in
                            let isSel = selectedCode == preset.code
                            Button {
                                onSelect(preset.code)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    Text(preset.label)
                                        .font(SettingsFont.bodyMedium)
                                        .foregroundStyle(isSel ? Color.nxCyan : Color.nxText2)

                                    Spacer()

                                    if isSel {
                                        Text("ACTIVE")
                                            .font(SettingsFont.tag)
                                            .foregroundStyle(Color.nxCyan)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 15)
                                .nxRowSurface(isSelected: focusedID == preset.id)
                            }
                            .buttonStyle(SettingsButtonStyle(isFocused: focusedID == preset.id))
                            .focused($focusedID, equals: preset.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 72)
            .padding(.vertical, 52)
        }
    }
}

struct StreamQualityPickerSheet: View {
    let selected: StreamQuality
    let allowsOriginal: Bool
    @AppStorage(LocalPlexOriginalQuality.storageKey, store: AppDefaults.standard) private var localOriginalVideo = false
    let onSelect: (StreamQuality) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedID: String?

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

            VStack(alignment: .leading, spacing: 16) {
                Text("STREAM QUALITY")
                    .font(SettingsFont.heading)
                    .foregroundStyle(Color.nxText2)

                Text("Lower quality uses less bandwidth. Auto adjusts as your connection changes.")
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        if allowsOriginal {
                            Button {
                                localOriginalVideo.toggle()
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(localOriginalVideo ? "Original (local Plex) · ACTIVE" : "Original (local Plex)")
                                        .font(SettingsFont.bodyMedium)
                                    Text(LocalPlexOriginalQuality.detail)
                                        .font(NXFont.captionRegular)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(15)
                            }
                            .focused($focusedID, equals: "local-original")
                        }
                        ForEach(StreamQuality.allCases) { quality in
                            let isSel = selected == quality
                            Button {
                                localOriginalVideo = false
                                onSelect(quality)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(quality.displayName)
                                            .font(SettingsFont.bodyMedium)
                                            .foregroundStyle(isSel ? Color.nxCyan : Color.nxText2)

                                        Text(quality.detail)
                                            .font(NXFont.captionRegular)
                                            .foregroundStyle(Color.nxText2)
                                    }

                                    Spacer()

                                    if isSel {
                                        Text("ACTIVE")
                                            .font(SettingsFont.tag)
                                            .foregroundStyle(Color.nxCyan)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 15)
                                .nxRowSurface(isSelected: focusedID == quality.id)
                            }
                            .buttonStyle(SettingsButtonStyle(isFocused: focusedID == quality.id))
                            .focused($focusedID, equals: quality.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 72)
            .padding(.vertical, 52)
        }
    }
}

struct SubtitleLanguagePickerSheet: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        LanguagePickerSheet(
            title: "SUBTITLE LANGUAGE",
            subtitle: "Choose which subtitle track to prefer when multiple are available.",
            presets: SubtitleLanguagePreset.all,
            selectedCode: appState.preferredSubtitleLanguageCode
        ) { appState.preferredSubtitleLanguageCode = $0 }
    }
}

struct AudioLanguagePickerSheet: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        LanguagePickerSheet(
            title: "AUDIO LANGUAGE",
            subtitle: "Choose which audio track to prefer when multiple are available.",
            presets: SubtitleLanguagePreset.all,
            selectedCode: appState.preferredAudioLanguageCode
        ) { appState.preferredAudioLanguageCode = $0 }
    }
}
