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
    /// Jellyfin only: the user hides this library from the home screen on the server.
    var isHidden: Bool = false

    /// What Settings and the library picker call such a library.
    static let hiddenMark = "HIDDEN ON JELLYFIN"

    var id: String { Self.storageKey(serverID: serverID, sectionKey: sectionKey) }

    static func storageKey(serverID: String, sectionKey: String) -> String {
        "\(serverID)::\(sectionKey)"
    }

    /// The line under the library's name: its kind, the server when more than one is in play, and
    /// `hiddenMark` for a library the user hides from the Jellyfin home screen.
    func subtitle(multiServer: Bool) -> String {
        let base = multiServer ? "\(serverName) · \(typeLabel)" : typeLabel
        return isHidden ? "\(base) · \(Self.hiddenMark)" : base
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
        Set(AppDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ deselected: Set<String>) {
        AppDefaults.standard.set(Array(deselected), forKey: key)
    }

    /// Whether a library the user hides from the Jellyfin home screen is on until the viewer
    /// switches it off. False: it is listed in LIBRARIES but off, and nothing from it airs
    /// until the viewer switches it on, because hiding it was a choice made on the server
    /// (adult content, test or plugin folders). The one line to change if that call changes.
    static let hiddenSectionsOnByDefault = false

    private static let includedHiddenKey = "nostalgex_included_hidden_library_sections"

    /// The hidden libraries the viewer switched ON, by `LibrarySectionRef.id`. Only read while
    /// `hiddenSectionsOnByDefault` is false; with it true a hidden library follows the same
    /// opt-out set as every other.
    static func loadIncludedHidden() -> Set<String> {
        Set(AppDefaults.standard.stringArray(forKey: includedHiddenKey) ?? [])
    }

    static func saveIncludedHidden(_ included: Set<String>) {
        AppDefaults.standard.set(Array(included), forKey: includedHiddenKey)
    }
}
