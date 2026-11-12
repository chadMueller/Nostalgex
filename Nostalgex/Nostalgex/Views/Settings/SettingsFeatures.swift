import Foundation

/// Switches for parts of Settings that are built but not ready to show.
///
/// Off: the part still has nothing behind it. Flipping it to true brings it back exactly
/// as it was built, with no other change. The code behind it (SettingsProView,
/// ProUpsellSheet, the proLocked row style) keeps compiling either way.
enum SettingsFeatures {
    /// The NOSTALGEX PRO tab on the Settings rail. Off: the rail has five tabs.
    static let showProTab = false
}
