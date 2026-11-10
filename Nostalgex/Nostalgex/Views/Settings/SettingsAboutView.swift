import SwiftUI

/// ABOUT: the version line, then LINKS (`AboutLinks.all`: Discord, the website, the web
/// tuner, Roku, GitHub).
///
/// tvOS has no web browser, so each link is a line to read and open on a phone or
/// computer, not a button that opens anything. Rating lives under SUPPORT NOSTALGEX.
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

            ForEach(AboutLinks.all) { link in
                SettingsToggleRow(
                    title: link.title,
                    subtitle: link.subtitle,
                    detail: link.address,
                    detailIsProminent: true,
                    isOn: true,
                    isFocused: isFocused(link.rowID),
                    showToggle: false
                ) {}
                .settingsRow(link.rowID, focus: focus)
                .accessibilityLabel("\(link.title.capitalized), \(link.address)")
            }
        }
    }

    private func isFocused(_ id: String) -> Bool {
        focus.wrappedValue == .row(id)
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
