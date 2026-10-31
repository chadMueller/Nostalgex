import SwiftUI

// Shared building blocks for the Settings screen (N-028). Moved here from the old
// BundleManagerView.swift, which held the flat SettingsPageView; that page is gone.

// MARK: - Collection category accordion (show / hide only, not a lineup toggle)

struct CollectionAccordionHeaderRow: View {
    let title: String
    let subtitle: String
    let detail: String
    let isExpanded: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.custom("DMMono-Medium", size: 20))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)

                    Text(subtitle)
                        .font(.custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(detail)
                        .font(.custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(isExpanded ? "HIDE" : "SHOW")
                        .font(.custom("VT323-Regular", size: 22))
                        .foregroundStyle(Color("BrandCyan").opacity(isFocused ? 1.0 : 0.75))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.07) : Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isFocused ? Color("BrandCyan").opacity(0.5) : Color.white.opacity(0.08),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused, accentColor: Color("BrandCyan")))
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

/// I-004: one channel's plain-language explainer, inside the missing-channels
/// accordion. Read-only (nothing on this card changes anything), but still
/// focusable: without a focus target here the remote's up/down had nothing to
/// land on inside the accordion and skipped the whole list (found live,
/// 2026-10-30). Highlighted on focus the same way CollectionAccordionHeaderRow is.
struct ChannelRequirementCard: View {
    let channel: Channel
    let matchedCount: Int
    /// Its own focus, not @Environment(\.isFocused): that one reads an ancestor's focus
    /// and never lights up for a view that is itself the focusable, so the card took
    /// focus with no visible highlight.
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(channel.color)
                    .frame(width: 4, height: 18)
                Text(channel.name.uppercased())
                    .font(.custom("DMMono-Medium", size: 20))
                    .foregroundStyle(.white)
            }

            Text("Needs at least \(channel.minItems) matching title\(channel.minItems == 1 ? "" : "s"). Your library has \(matchedCount) right now.")
                .font(.custom("DMMono-Regular", size: 18))
                .foregroundStyle(Color(hex: "#FFB020"))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((channel.rules?.plainLanguageRequirements ?? []).enumerated()), id: \.offset) { _, line in
                    Text("\u{2022} \(line)")
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isFocused ? Color("BrandCyan").opacity(0.5) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .focusable(true)
        .focused($isFocused)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(isEnabled ? .white : .white.opacity(0.35))
                Text(subtitle)
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(isEnabled ? 0.8 : 0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? .white.opacity(0.07) : .white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? Color("BrandCyan").opacity(0.5) : .clear, lineWidth: 1.5)
            )
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
/// Focus matches SettingsToggleRow (cyan stroke, lighter fill) plus a small lift.
struct SupportTile: View {
    let art: PixelArt
    let title: String
    let caption: String
    /// A price reads in the title weight so it stays legible from the couch.
    var captionIsPrice: Bool = false
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                PixelIconView(art: art, size: 96)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.custom("DMMono-Medium", size: 22))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(caption)
                        .font(captionIsPrice ? .custom("DMMono-Medium", size: 22) : .custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(captionIsPrice ? 0.85 : 0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 30)
            .padding(.bottom, 26)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isFocused ? .white.opacity(0.08) : .white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isFocused ? Color("BrandCyan").opacity(0.6) : .white.opacity(0.06),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isFocused ? 1.04 : 1.0)
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
    var detail: String? = nil
    /// A price has to be readable; the default detail is a faint annotation.
    var detailIsProminent: Bool = false
    var warning: String? = nil
    let isOn: Bool
    let isFocused: Bool
    var isLoading: Bool = false
    var loadingMessage: String? = nil
    var showToggle: Bool = true
    /// Pro-only row: a lock and a PRO pill replace the switch, and select calls
    /// onLockedTap instead of onToggle. Off by default, so existing rows are unchanged.
    var proLocked: Bool = false
    var onLockedTap: (() -> Void)? = nil
    let onToggle: () -> Void

    var body: some View {
        Button {
            if proLocked {
                onLockedTap?()
            } else {
                onToggle()
            }
        } label: {
            HStack(spacing: 16) {
                // Label
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.custom("DMMono-Medium", size: 22))
                        .foregroundStyle(isOn ? .white : .white.opacity(0.35))

                    if let subtitle {
                        Text(subtitle)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(.white.opacity(isOn ? 0.8 : 0.5))
                            .lineLimit(2)
                    }

                    if let warning {
                        Text(warning)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(Color(hex: "#FFB020"))
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Detail text or loading message
                if isLoading, let msg = loadingMessage {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Color("BrandCyan"))
                        Text(msg)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(Color("BrandCyan").opacity(0.7))
                    }
                } else if isLoading {
                    ProgressView()
                        .tint(Color("BrandCyan"))
                } else if let detail {
                    Text(detail)
                        .font(detailIsProminent ? .custom("DMMono-Medium", size: 22) : .custom("VT323-Regular", size: 20))
                        .foregroundStyle(.white.opacity(detailIsProminent ? 0.85 : 0.2))
                }

                // Toggle switch (hidden while loading or when showToggle is false)
                if proLocked {
                    ProLockBadge()
                } else if !isLoading && showToggle {
                    ToggleSwitch(isOn: isOn)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? .white.opacity(0.07) : .white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isFocused ? Color("BrandCyan").opacity(0.5) : .clear,
                        lineWidth: 1.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .accessibilityLabel(title)
        .accessibilityValue(proLocked ? "Pro only" : (isOn ? "On" : "Off"))
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Pro lock badge

/// A lock and a PRO pill, in amber so Pro reads apart from the free rows' cyan.
struct ProLockBadge: View {
    private let amber = Color(hex: "#FFB020")

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 22)
                .foregroundStyle(amber)
            Text("PRO")
                .font(.custom("VT323-Regular", size: 24))
                .foregroundStyle(amber)
                .padding(.horizontal, 10)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.custom("DMMono-Medium", size: 28))
                .foregroundStyle(.white.opacity(0.8))
            if let subtitle {
                Text(subtitle)
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.7))
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
            .font(.custom("DMMono-Regular", size: 20))
            .foregroundStyle(.white.opacity(0.7))
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
                .frame(width: 52, height: 30)
                .overlay(
                    Capsule()
                        .stroke(isOn ? Color("BrandCyan").opacity(0.5) : .white.opacity(0.15), lineWidth: 1)
                )

            // Thumb
            Circle()
                .fill(isOn ? Color("BrandCyan") : .white.opacity(0.7))
                .frame(width: 24, height: 24)
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

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ENRICHMENT")
                        .font(.custom("DMMono-Medium", size: 28))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Improving channel accuracy with TMDB + OMDb metadata")
                        .font(.custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                }

                HStack(spacing: 16) {
                    ProgressView(value: enrichmentService.progress)
                        .progressViewStyle(.linear)
                        .tint(Color("BrandCyan"))
                        .focusable(false)

                    Text("\(enrichmentService.enrichedCount)/\(enrichmentService.totalToEnrich)")
                        .font(.custom("DMMono-Medium", size: 20))
                        .foregroundStyle(.white.opacity(0.7))
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

            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.custom("DMMono-Medium", size: 28))
                    .foregroundStyle(.white.opacity(0.8))

                Text(subtitle)
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.7))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(presets) { preset in
                            let isSel = selectedCode == preset.code
                            Button {
                                onSelect(preset.code)
                                dismiss()
                            } label: {
                                HStack(spacing: 16) {
                                    Text(preset.label)
                                        .font(.custom("DMMono-Medium", size: 22))
                                        .foregroundStyle(isSel ? Color("BrandCyan") : .white.opacity(0.85))

                                    Spacer()

                                    if isSel {
                                        Text("ACTIVE")
                                            .font(.custom("VT323-Regular", size: 20))
                                            .foregroundStyle(Color("BrandCyan").opacity(0.7))
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(focusedID == preset.id ? .white.opacity(0.07) : .white.opacity(0.02))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            focusedID == preset.id ? Color("BrandCyan").opacity(0.5) : .clear,
                                            lineWidth: 1.5
                                        )
                                )
                            }
                            .buttonStyle(SettingsButtonStyle(isFocused: focusedID == preset.id))
                            .focused($focusedID, equals: preset.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
    }
}

struct StreamQualityPickerSheet: View {
    let selected: StreamQuality
    let allowsOriginal: Bool
    @AppStorage(LocalPlexOriginalQuality.storageKey) private var localOriginalVideo = false
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

            VStack(alignment: .leading, spacing: 20) {
                Text("STREAM QUALITY")
                    .font(.custom("DMMono-Medium", size: 28))
                    .foregroundStyle(.white.opacity(0.8))

                Text("Lower quality uses less bandwidth. Auto adjusts as your connection changes.")
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.7))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        if allowsOriginal {
                            Button {
                                localOriginalVideo.toggle()
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(localOriginalVideo ? "Original (local Plex) · ACTIVE" : "Original (local Plex)")
                                        .font(.custom("DMMono-Medium", size: 22))
                                    Text(LocalPlexOriginalQuality.detail)
                                        .font(.custom("DMMono-Regular", size: 20))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
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
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(quality.displayName)
                                            .font(.custom("DMMono-Medium", size: 22))
                                            .foregroundStyle(isSel ? Color("BrandCyan") : .white.opacity(0.85))

                                        Text(quality.detail)
                                            .font(.custom("DMMono-Regular", size: 20))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }

                                    Spacer()

                                    if isSel {
                                        Text("ACTIVE")
                                            .font(.custom("VT323-Regular", size: 20))
                                            .foregroundStyle(Color("BrandCyan").opacity(0.7))
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(focusedID == quality.id ? .white.opacity(0.07) : .white.opacity(0.02))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            focusedID == quality.id ? Color("BrandCyan").opacity(0.5) : .clear,
                                            lineWidth: 1.5
                                        )
                                )
                            }
                            .buttonStyle(SettingsButtonStyle(isFocused: focusedID == quality.id))
                            .focused($focusedID, equals: quality.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
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
