import SwiftUI

/// The six tabs of the Settings rail (N-028). SUPPORT NOSTALGEX is pinned above a
/// divider so it is never buried; the other five follow in this order.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case support
    case playback
    case channels
    case servers
    case pro
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .support: return "SUPPORT NOSTALGEX"
        case .playback: return "PLAYBACK & PICTURE"
        case .channels: return "CHANNELS & BUNDLES"
        case .servers: return "SERVERS & ACCOUNTS"
        case .pro: return "NOSTALGEX PRO"
        case .about: return "ABOUT"
        }
    }

    /// One line under the hero title.
    var subtitle: String {
        switch self {
        case .support: return "A star rating or a tip, whichever suits"
        case .playback: return "Picture, quality, subtitles and audio"
        case .channels: return "Packages, franchises, collections and the schedule"
        case .servers: return "Servers, libraries, rescans and sign out"
        case .pro: return "What Pro adds"
        case .about: return "Version and links"
        }
    }

    /// Sits above the divider at the top of the rail.
    var isPinned: Bool { self == .support }

    /// Hero fallback while a category has no heroImageName asset yet.
    var sfSymbolPlaceholder: String {
        switch self {
        case .support: return "star.fill"
        case .playback: return "tv"
        case .channels: return "square.stack.3d.up.fill"
        case .servers: return "server.rack"
        case .pro: return "crown.fill"
        case .about: return "info.circle"
        }
    }

    /// Asset name of the 16:9 hero illustration in Assets.xcassets/SettingsHero.
    /// The hero falls back to sfSymbolPlaceholder while an asset is missing.
    var heroImageName: String {
        switch self {
        case .support: return "SettingsHeroSupport"
        case .playback: return "SettingsHeroPlayback"
        case .channels: return "SettingsHeroChannels"
        case .servers: return "SettingsHeroServers"
        case .pro: return "SettingsHeroPro"
        case .about: return "SettingsHeroAbout"
        }
    }

    static var pinned: [SettingsCategory] { allCases.filter(\.isPinned) }
    static var unpinned: [SettingsCategory] { allCases.filter { !$0.isPinned } }
}

/// One focus value for the whole Settings screen, so the container can move focus
/// between the rail and the detail pane and read where it is.
enum SettingsFocus: Hashable {
    case rail(SettingsCategory)
    /// A row in the detail pane, keyed by the same ids the old flat page used.
    case row(String)
}

extension View {
    /// Makes a detail-pane row focusable under `.row(id)` and gives it the same id for
    /// ScrollViewReader, the pairing every Settings row needs.
    func settingsRow(_ id: String, focus: FocusState<SettingsFocus?>.Binding) -> some View {
        self
            .focused(focus, equals: .row(id))
            .id(id)
    }
}
