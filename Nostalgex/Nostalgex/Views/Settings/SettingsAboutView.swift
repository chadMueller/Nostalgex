import SwiftUI

/// ABOUT: the version line, plus slots for the community and rating links.
///
/// PLACEHOLDER (N-028): the DISCORD, GITHUB and RATE rows have no destination yet.
/// Their copy and links come from Chad; nothing here opens anything.
struct SettingsAboutView: View {
    let focus: FocusState<SettingsFocus?>.Binding

    static let firstRowID = "about_version"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Focusable so the remote has somewhere to land; select does nothing.
            SettingsToggleRow(
                title: "VERSION",
                subtitle: "The build number tells two submissions of one version apart",
                detail: appVersionLabel,
                detailIsProminent: true,
                isOn: true,
                isFocused: isFocused("about_version"),
                showToggle: false
            ) {}
            .settingsRow("about_version", focus: focus)
            .accessibilityLabel("App version \(appVersionLabel)")

            SettingsSectionHeader(title: "LINKS")
                .padding(.top, 24)

            placeholderRow(id: "about_discord", title: "DISCORD")
            placeholderRow(id: "about_github", title: "GITHUB")
            placeholderRow(id: "about_rate", title: "RATE NOSTALGEX")
        }
    }

    private func isFocused(_ id: String) -> Bool {
        focus.wrappedValue == .row(id)
    }

    private func placeholderRow(id: String, title: String) -> some View {
        SettingsToggleRow(
            title: title,
            subtitle: "Placeholder. Link and copy to come from Chad.",
            detail: "PLACEHOLDER",
            isOn: false,
            isFocused: isFocused(id),
            showToggle: false
        ) {}
        .settingsRow(id, focus: focus)
    }

    /// Marketing version plus build, e.g. "1.0.10 (17)". Both matter: the build number
    /// is what distinguishes two submissions of the same version.
    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
