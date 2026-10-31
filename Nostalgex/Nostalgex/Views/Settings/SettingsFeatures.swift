import Foundation

/// Switches for parts of Settings that are built but not ready to show.
///
/// Both are off for 1.0.29: the rows they hide still read "Placeholder" and have nothing
/// behind them. Flipping one to true brings its part back exactly as it was built, with
/// no other change. The code behind them (SettingsProView, ProUpsellSheet, the proLocked
/// row style, the About placeholder rows) keeps compiling either way.
enum SettingsFeatures {
    /// The NOSTALGEX PRO tab on the Settings rail. Off: the rail has five tabs.
    static let showProTab = false

    /// The DISCORD and RATE NOSTALGEX rows under ABOUT > LINKS. Off: LINKS shows GITHUB
    /// only. Rating stays reachable from SUPPORT NOSTALGEX either way.
    static let showAboutCommunityLinks = false
}
