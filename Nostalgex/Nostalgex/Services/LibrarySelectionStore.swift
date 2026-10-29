import Foundation

/// One library section a backend can show on the library-selection screen (onboarding)
/// or in Settings. `serverID` scopes `sectionKey`, which is only unique per server,
/// two different Plex servers can both number their first section "1", the same way
/// `PlexMediaItem.serverID` scopes a rating key.
///
/// See `docs/LIBRARY-SELECTION.md` (nostalgex-internal, I-054) for the feature spec.
struct LibrarySectionRef: Identifiable, Hashable, Sendable {
    let serverID: String
    let serverName: String
    let sectionKey: String
    let title: String
    let type: String

    var id: String { Self.storageKey(serverID: serverID, sectionKey: sectionKey) }

    static func storageKey(serverID: String, sectionKey: String) -> String {
        "\(serverID)::\(sectionKey)"
    }

    /// Short label for the section's content type, used in subtitles. Falls back to
    /// "Library" for anything not recognized (matches the loading-screen label logic).
    var typeLabel: String {
        switch type {
        case "show": return "TV Shows"
        case "musicvideo": return "Music Videos"
        case "artist": return "Music"
        case "photo": return "Photos"
        case "movie":
            return title.range(of: #"music.?video|^music$|^mv[s]?$"#, options: [.regularExpression, .caseInsensitive]) != nil
                ? "Music Videos" : "Movies"
        default: return "Library"
        }
    }
}

/// Which library sections the viewer has turned off, persisted across launches and
/// relaunches. Default (key absent, or a section never seen before) is ON: I-054 is
/// explicit that this is opting OUT, not opting in, so nobody lands on an empty guide
/// by not noticing the selection screen or by a new library appearing on their server
/// later. Plain UserDefaults, like the other simple on/off settings (enabled bundles,
/// enabled collections), nothing here is a credential.
enum LibrarySectionSelectionStore {
    private static let key = "nostalgex_deselected_library_sections"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ deselected: Set<String>) {
        UserDefaults.standard.set(Array(deselected), forKey: key)
    }
}
