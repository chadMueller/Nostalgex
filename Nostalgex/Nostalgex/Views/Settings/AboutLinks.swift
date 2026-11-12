import Foundation

/// One line under ABOUT > LINKS: a name, what it is, and the address to read.
///
/// tvOS has no web browser, so an address is text to read and open on a phone or computer,
/// never a button that opens anything. The addresses are the ones the site, the README and
/// the Roku listing already publish. Only what a viewer can use today is listed.
struct AboutLink: Equatable, Identifiable {
    /// Also the Settings row id (`about_<id>`).
    let id: String
    let title: String
    let subtitle: String
    /// What is shown, without `https://`.
    let address: String

    var rowID: String { "about_\(id)" }
}

enum AboutLinks {
    static let discord = AboutLink(
        id: "discord", title: "DISCORD",
        subtitle: "Chat with other viewers and get help. Open it on a phone or computer.",
        address: "discord.gg/FgnZcr5bDT")
    static let website = AboutLink(
        id: "website", title: "WEBSITE",
        subtitle: "The Nostalgex website. Open it on a phone or computer.",
        address: "nostalgex.app")
    static let webTuner = AboutLink(
        id: "web_tuner", title: "WEB TUNER",
        subtitle: "Nostalgex in a web browser. Open it on a phone or computer.",
        address: "nostalgex.app/web-tuner")
    static let roku = AboutLink(
        id: "roku", title: "ROKU",
        subtitle: "Add it from the Roku Channel Store. Channel code: NOSTALGEX.",
        address: "my.roku.com/account/add/NOSTALGEX")
    static let github = AboutLink(
        id: "github", title: "GITHUB",
        subtitle: "Source code and issues. Open it on a phone or computer.",
        address: "github.com/chadMueller/Nostalgex")

    /// In the order they are listed.
    static let all: [AboutLink] = [discord, website, webTuner, roku, github]
}
