import Foundation

/// One canonical franchise and everything that rolls up into it.
///
/// This is the hand-maintained half of franchise channel building. The automatic
/// half (`FranchiseChannelBuilder`) groups a library's movies by their TMDB
/// `belongs_to_collection` id. That handles the common case, but it can't know that
/// the prequel-trilogy collection and the sequel-trilogy collection are both "Star
/// Wars", or that The Mandalorian belongs with the films even though its title never
/// says "Star Wars". This dictionary carries that editorial knowledge.
///
/// The definitions themselves live in `franchises.json` at the repo root, shared with
/// the web tuner (`scripts/nostalgex-franchise-builder.js`). This type is the decoded
/// form; the field docs below match the `fields` block in that file.
struct FranchiseDefinition: Decodable {
    /// Channel-ready display name, upper-cased to match the rest of the lineup.
    let canonicalName: String

    /// The stock `channels.json` channel this franchise maps to, when one exists.
    /// Found films and shows fold INTO this channel rather than making a duplicate
    /// runtime channel next to it. nil means "no stock channel, build it dynamically".
    let stockChannelID: Int?

    /// TMDB `belongs_to_collection` ids that all roll up into this one franchise. A
    /// movie whose `franchiseID` is in here is claimed by this franchise, and several
    /// collections (LORD OF THE RINGS + THE HOBBIT) merge into a single channel.
    /// Empty for a studio-ruled franchise (see `studioRuled`).
    let tmdbCollectionIDs: [Int]

    /// Substrings a title must contain to join by name (word-boundary, case
    /// insensitive). Applies to TV shows AND, for dictionary franchises only, to films
    /// that TMDB leaves outside any collection: "star wars" catches "Star Wars: The
    /// Clone Wars" and "Rogue One: A Star Wars Story" (belongs_to_collection is null on
    /// TMDB); "transformers" catches "Transformers: Rise of the Beasts" (also null).
    /// It does not catch "The Mandalorian" or "Bumblebee" (those need the explicit
    /// title lists). Auto-found franchises never use tokens, so a token cannot
    /// over-match a franchise the dictionary does not know about.
    let nameMatchTokens: [String]

    /// TV shows that belong but do NOT name-match (STAR WARS -> The Mandalorian).
    let tvShowTitles: [String]

    /// Films that belong but have no `belongs_to_collection` on TMDB AND do not
    /// name-match (TRANSFORMERS -> Bumblebee). Exact title, case insensitive, with any
    /// trailing " (YYYY)" ignored.
    let filmTitles: [String]

    /// Marvel is defined by studio (CH101 carries a `studios` rule), not by collection
    /// grouping: its films live in dozens of tiny TMDB collections. When true the
    /// builder never places a FILM in this franchise (no `franchiseID` grouping, no
    /// `filmTitles`, no name tokens); the stock channel's studio rule owns the films.
    /// TV still joins, by exact `tvShowTitles` only, since a studio rule cannot see
    /// shows (CH101's rule is `type: movie`).
    let studioRuled: Bool

    /// A found franchise with this flag starts switched ON (a dynamic franchise only;
    /// a stock classic always starts on and has its own switch in Settings). The viewer can still turn it off,
    /// and that choice is kept (`nostalgex_disabled_franchises`). Nothing is built when
    /// the library has none of it: the usual three-film gate still applies.
    let defaultOn: Bool

    init(canonicalName: String,
         stockChannelID: Int? = nil,
         tmdbCollectionIDs: [Int] = [],
         nameMatchTokens: [String] = [],
         tvShowTitles: [String] = [],
         filmTitles: [String] = [],
         studioRuled: Bool = false,
         defaultOn: Bool = false) {
        self.canonicalName = canonicalName
        self.stockChannelID = stockChannelID
        self.tmdbCollectionIDs = tmdbCollectionIDs
        self.nameMatchTokens = nameMatchTokens
        self.tvShowTitles = tvShowTitles
        self.filmTitles = filmTitles
        self.studioRuled = studioRuled
        self.defaultOn = defaultOn
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalName, stockChannelID, tmdbCollectionIDs, nameMatchTokens,
             tvShowTitles, filmTitles, studioRuled, defaultOn
    }

    /// Only `canonicalName` is required; every list defaults to empty and every flag to
    /// false, the same defaults as the memberwise init and the JS loader
    /// (`normalizeDefinitions`). Unknown keys such as `note` are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            canonicalName: try c.decode(String.self, forKey: .canonicalName),
            stockChannelID: try c.decodeIfPresent(Int.self, forKey: .stockChannelID),
            tmdbCollectionIDs: try c.decodeIfPresent([Int].self, forKey: .tmdbCollectionIDs) ?? [],
            nameMatchTokens: try c.decodeIfPresent([String].self, forKey: .nameMatchTokens) ?? [],
            tvShowTitles: try c.decodeIfPresent([String].self, forKey: .tvShowTitles) ?? [],
            filmTitles: try c.decodeIfPresent([String].self, forKey: .filmTitles) ?? [],
            studioRuled: try c.decodeIfPresent(Bool.self, forKey: .studioRuled) ?? false,
            defaultOn: try c.decodeIfPresent(Bool.self, forKey: .defaultOn) ?? false
        )
    }

    /// The `FoundFranchise` / `FranchiseGrouping.stableID` this definition produces.
    var stableID: String { "dict:\(canonicalName)" }
}

/// The franchise dictionary, loaded from the bundled `franchises.json`.
///
/// `franchises.json` lives at the repo root next to `channels.json` and is the single
/// source for both engines: the "Sync channel config" build phase copies it into the
/// app bundle, and `public/franchises.json` (a symlink) ships it with the web build.
/// Every TMDB collection id in it was verified against the live TMDB API on
/// 2026-10-11; the per-entry `note` fields say which collection each id is, and
/// record the two ids from memory that turned out dead. `scripts/franchise-golden.json`
/// pins the groupings both engines must produce: `FranchiseGoldenTests` (Swift) and
/// `npm run test:franchises` (node) both check against it.
///
/// What TMDB cannot carry, and the dictionary covers instead:
/// - Films with `belongs_to_collection: null`. Rogue One, Solo, Bumblebee and
///   Transformers: Rise of the Beasts are all null on TMDB. The "A Star Wars Story"
///   pair and Rise of the Beasts join by `nameMatchTokens`; Bumblebee, whose title
///   says nothing, is listed in `filmTitles`.
/// - MARVEL stays studio-ruled by design (CH101's `studios` rule), never grouped by
///   collection id.
/// - TV has no collection id at all, so it joins by token or by `tvShowTitles`.
///
/// If the file is missing or does not decode, the dictionary is empty and a CONFIG
/// line is logged: franchise channels then come only from auto-found collections.
/// Degraded, never a crash.
enum FranchiseDictionary {

    /// Highest `franchises.json` `version` this build understands. A newer file still
    /// decodes (unknown keys are ignored); the log line flags it.
    static let supportedVersion = 1

    static let all: [FranchiseDefinition] = loadBundled()

    // MARK: - Loading

    private struct File: Decodable {
        let version: Int?
        let franchises: [FranchiseDefinition]
    }

    /// Decode a `franchises.json` document. Throws on malformed JSON so a test can see
    /// the error; the app path (`loadBundled`) turns a throw into an empty dictionary.
    static func decode(_ data: Data) throws -> [FranchiseDefinition] {
        try JSONDecoder().decode(File.self, from: data).franchises
    }

    /// The bundled `franchises.json`, or an empty dictionary plus a log line.
    static func loadBundled(bundle: Bundle? = nil) -> [FranchiseDefinition] {
        let bundle = bundle ?? Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "franchises", withExtension: "json") else {
            print("[Plex90] CONFIG: bundled franchises.json MISSING from app, franchise dictionary is empty")
            return []
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            if let v = file.version, v > supportedVersion {
                print("[Plex90] CONFIG: franchises.json version \(v) is newer than \(supportedVersion), unknown fields ignored")
            }
            return file.franchises
        } catch {
            print("[Plex90] CONFIG: franchises.json failed to decode (\(error)), franchise dictionary is empty")
            return []
        }
    }

    /// Resolves the app bundle from inside the app and from a hosted test bundle alike.
    private final class BundleToken {}

    // MARK: - Lookups

    /// franchiseID -> definition, for every definition that declares collection ids.
    /// A studio-ruled franchise (Marvel) declares none, so it never appears here and is
    /// never matched by franchiseID.
    static let byCollectionID: [Int: FranchiseDefinition] = {
        var map: [Int: FranchiseDefinition] = [:]
        for def in all {
            for id in def.tmdbCollectionIDs { map[id] = def }
        }
        return map
    }()

    static func definition(forFranchiseID id: Int) -> FranchiseDefinition? {
        byCollectionID[id]
    }

    /// Stable ids of the franchises that start switched on (STAR TREK, FAST & FURIOUS).
    static let defaultOnIDs: Set<String> = Set(all.filter(\.defaultOn).map(\.stableID))

    /// Whether a found franchise is on: an explicit choice wins either way, otherwise
    /// the dictionary default. Shared by the rebuild, the snapshot restore and iCloud
    /// arrivals so all three agree.
    static func isOn(_ id: String, enabledIDs: Set<String>, disabledIDs: Set<String>) -> Bool {
        isOn(id, enabledIDs: enabledIDs, disabledIDs: disabledIDs, defaultOn: defaultOnIDs.contains(id))
    }

    /// Same rule with an explicit default. A stock classic (ids 100-106, CH 300-306) defaults ON: it
    /// is off only when the viewer switched it off (`nostalgex_disabled_franchises`).
    static func isOn(_ id: String, enabledIDs: Set<String>, disabledIDs: Set<String>, defaultOn: Bool) -> Bool {
        if enabledIDs.contains(id) { return true }
        if disabledIDs.contains(id) { return false }
        return defaultOn
    }

    /// The stock definitions (a `stockChannelID`), keyed by that channel id.
    static let byStockChannelID: [Int: FranchiseDefinition] = {
        var map: [Int: FranchiseDefinition] = [:]
        for def in all { if let id = def.stockChannelID { map[id] = def } }
        return map
    }()

    /// Strip a trailing " Collection" (case insensitive) and tidy whitespace.
    /// "John Wick Collection" -> "John Wick".
    static func cleanFranchiseName(_ raw: String) -> String {
        var name = raw
        let suffix = " collection"
        if name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
