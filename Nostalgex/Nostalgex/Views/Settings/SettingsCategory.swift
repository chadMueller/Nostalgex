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

    /// Phase 1 hero art. Phase 3 swaps these for one illustration per category.
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

    /// Tint for the placeholder hero only. Focus is always BrandCyan.
    var heroTint: Color {
        switch self {
        case .support: return Color(hex: "#FFE500")
        case .playback: return Color("BrandCyan")
        case .channels: return Color(hex: "#FF2DB4")
        case .servers: return Color("BrandCyan")
        case .pro: return Color(hex: "#FFB020")
        case .about: return .white.opacity(0.8)
        }
    }

    /// Phase 1 only: true for the two categories with real rows.
    var hasPhase1Content: Bool { self == .support || self == .playback }

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
