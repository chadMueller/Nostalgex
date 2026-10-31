import CryptoKit
import Foundation
import os
import SwiftUI

// MARK: - In-memory snapshot (also the legacy single-file format)

/// One channel row: rules + optional list of `PlexMediaItem.id` (rating keys) to rebuild pools.
struct StoredChannel: Codable {
    let id: Int
    let number: Int
    let name: String
    let colorHex: String
    let category: String?
    let minItems: Int
    /// Optional so snapshots written before premieres were limited to one channel
    /// still decode; absent reads as false.
    let isPremiereChannel: Bool?
    let rules: ChannelRulesJSON?
    let timeRestrictions: TimeRestrictionsJSON?
    let enabled: Bool
    let itemRatingKeys: [String]
}

struct StoredDiscoveredCollection: Codable {
    let id: String
    let title: String
    let movieCount: Int
    let itemRatingKeys: [String]
    let enabled: Bool
    let matchedChannel: String?
    let categoryRaw: String
    /// Optional so snapshots written before the franchise fold existed still decode.
    var foldedIntoFranchise: String? = nil
}

/// One found franchise (see `FoundFranchise`). Enabled state is NOT stored here: it
/// lives in UserDefaults under `nostalgex_enabled_franchises` and
/// `nostalgex_disabled_franchises` and is applied on restore.
struct StoredFoundFranchise: Codable {
    let id: String
    let name: String
    let movieRatingKeys: [String]
    let tvRatingKeys: [String]
    let coveredByChannelID: Int?
    let fromDictionary: Bool
}

/// What a restore hands AppState. It is also, byte for byte, the legacy on-disk format
/// (schemaVersion 2, one `library_snapshot_v1.json`), which is why it stays Codable.
struct LibrarySnapshotV1: Codable {
    var schemaVersion: Int
    var credentialFingerprint: String
    /// Unix seconds when the snapshot was produced. Snapshot is valid for 24h
    /// rolling (not day-boundary) so a load at 6pm stays warm until 6pm next day,
    /// avoiding a forced rescan in the user's evening when UTC midnight crosses.
    var lastLoadAtUnix: Int
    var serverName: String
    var allItems: [PlexMediaItem]
    var channelConfigRows: [StoredChannel]
    var allChannelRows: [StoredChannel]
    var bundleDefinitions: [ChannelBundleDefinition]
    var enabledBundleIDList: [String]
    var exclusiveRuleJSON: [ExclusiveRuleJSON]
    var discoveredCollectionRows: [StoredDiscoveredCollection]
    /// Library change signature at the time of the scan (see LibraryChangeSignature).
    /// Optional so snapshots written before it existed still decode.
    var librarySignature: String? = nil
    /// Franchises found in the library at scan time. Optional so older snapshots decode;
    /// absent reads as "nothing found yet".
    var foundFranchiseRows: [StoredFoundFranchise]? = nil
}

// MARK: - On-disk format v3 (chunked)
//
// The v2 snapshot was one JSON document holding every item, encoded in one call on the
// main thread and written atomically. At 400k items that call peaked at 2.6 GB, past what
// an Apple TV lets an app keep, so the app was killed right after the guide appeared, and
// because the write was all-or-nothing the next launch found no snapshot and scanned again.
//
// v3 is a directory:
//
//     library_snapshot/
//       current.json            manifest: which generation is live. Written LAST, atomically.
//       g-<uuid>/items-0000.json  ... 10k items per file
//       g-<uuid>/meta.json        header, channel rows, collections (pools as item indexes)
//
// A save writes a fresh generation directory chunk by chunk on a background queue, then
// swaps `current.json` to name it. A save killed at any point before that rename leaves
// the previous generation and its manifest untouched. A restore reads one chunk at a time.

/// meta.json in a generation directory.
struct LibrarySnapshotMetaV3: Codable {
    var schemaVersion: Int
    var credentialFingerprint: String
    var lastLoadAtUnix: Int
    var serverName: String
    var librarySignature: String?
    var itemCount: Int
    var chunkItemCounts: [Int]
    var channelConfigRows: [StoredChannel]
    /// Rows with empty `itemRatingKeys`; the pools are `allChannelPools` (same order).
    var allChannelRows: [StoredChannel]
    /// Each channel's pool as indexes into the item chunks. A rating key is ~50 bytes of
    /// JSON and a fresh String on restore; an index is a few digits and an Int.
    var allChannelPools: [[Int32]]
    var bundleDefinitions: [ChannelBundleDefinition]
    var enabledBundleIDList: [String]
    var exclusiveRuleJSON: [ExclusiveRuleJSON]
    /// Rows with empty `itemRatingKeys`; the members are `discoveredCollectionItems`.
    var discoveredCollectionRows: [StoredDiscoveredCollection]
    var discoveredCollectionItems: [[Int32]]
    /// Rows with empty rating key lists; the members are `foundFranchiseMovieItems` and
    /// `foundFranchiseTVItems` (same order). All three are optional so a v3 meta.json
    /// written before franchises existed still decodes, as "nothing found yet".
    var foundFranchiseRows: [StoredFoundFranchise]? = nil
    var foundFranchiseMovieItems: [[Int32]]? = nil
    var foundFranchiseTVItems: [[Int32]]? = nil
}

/// current.json. Small, written last, replaced atomically.
struct LibrarySnapshotManifestV3: Codable {
    var format: Int
    var generation: String
    var itemCount: Int
    var chunkCount: Int
}

// MARK: - Store

enum LibrarySnapshotStore {
    /// How old library data may get before a background refresh runs. Was 24h; people add
    /// media during the day and expect it in tonight's guide, and the refresh is invisible
    /// (guide stays up, partial results are discarded), so the only real cost of 6h is four
    /// scans a day instead of one.
    static let refreshAfterSeconds = 6 * 3600
    /// Past this age a scan runs even if the library reports no change.
    static let forceRefreshAfterSeconds = 24 * 3600

    /// Bump only when an older file can no longer decode or would decode into something
    /// wrong. A bump clears every user's snapshot and forces a full rescan on next launch.
    /// Fields added with `decodeIfPresent` and a safe default (mediaIndex, partIndex,
    /// playbackParts, exactDurationSeconds from #21; the found-franchise rows) do not need
    /// one: an old file decodes to the behaviour it had before, and the next full library
    /// scan fills them in. LibrarySnapshotCompatibilityTests holds this.
    static let formatVersion = 3
    /// Items per chunk file. ~10 MB of JSON at the sizes Plex hands back; encoding or
    /// decoding one costs tens of MB, not the whole library.
    static let chunkSize = 10_000
    /// A legacy single-file snapshot bigger than this is discarded (one rescan) instead of
    /// decoded. Decoding v2 is one call over the whole file and peaks at several times its
    /// size: measured +380 MB over steady at 100k items (96 MB file) and +1.5 GB at 400k.
    /// 64 MB (~65k items) keeps that one-time decode near the v3 budget.
    /// A var only so tests can lower it.
    nonisolated(unsafe) static var legacyMaxBytes: UInt64 = 64 * 1_048_576

    private static let legacyFileName = "library_snapshot_v1.json"
    private static let directoryName = "library_snapshot"
    private static let manifestName = "current.json"
    private static let metaName = "meta.json"

    private static func chunkName(_ i: Int) -> String { String(format: "items-%04d.json", i) }

    /// Keyed on WHICH library this is (server identity, and account where the backend has
    /// no server-side account notion), never on the session token. A token changes on every
    /// sign-in, and keying on it threw away a perfectly good snapshot each time, forcing a
    /// full rescan for no reason. A different account can only sign in after Disconnect,
    /// which clears the snapshot, so dropping the token leaks nothing.
    static func fingerprint(identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var legacyFileURL: URL? {
        LocalStore.rootDirectory?.appendingPathComponent(legacyFileName)
    }

    /// The v3 directory. Exposed for tests and the big-library harness.
    static var snapshotDirectoryURL: URL? {
        LocalStore.rootDirectory?.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The legacy file location. Exposed for the migration tests.
    static var legacySnapshotURL: URL? { legacyFileURL }

    // MARK: Write ordering

    /// Every save request and every clear() takes a new epoch. A write commits only if its
    /// epoch is still the latest, checked under the same lock clear() deletes under, so a
    /// save that was in flight when the user hit Disconnect can never bring the old
    /// library back, and an older save never lands on top of a newer one.
    private static let epochLock = NSLock()
    private static var epoch: UInt64 = 0
    private static let writeQueue = DispatchQueue(label: "com.muellhaus.nostalgex.snapshot-write", qos: .utility)

    private static func nextEpoch() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        epoch &+= 1
        return epoch
    }

    private static func isCurrent(_ e: UInt64) -> Bool {
        epochLock.lock(); defer { epochLock.unlock() }
        return epoch == e
    }

    static func clear() {
        epochLock.lock(); defer { epochLock.unlock() }
        epoch &+= 1
        if let dir = snapshotDirectoryURL { try? FileManager.default.removeItem(at: dir) }
        if let legacy = legacyFileURL { try? FileManager.default.removeItem(at: legacy) }
    }

    /// Blocks until every queued save has finished or been dropped. Tests and the harness.
    static func waitForPendingSaves() {
        writeQueue.sync {}
    }

    // MARK: Save

    /// Everything a save needs, captured on the caller's actor. The arrays are copy-on-write
    /// references, so capturing them costs nothing and the main actor stays free to replace
    /// its own copies while the write runs.
    struct Payload: @unchecked Sendable {
        let fingerprint: String
        let serverName: String
        let librarySignature: String?
        let lastLoadAtUnix: Int
        let allItems: [PlexMediaItem]
        let configRows: [StoredChannel]
        let visibleRows: [StoredChannel]
        let visiblePools: [[PlexMediaItem]]
        let bundleDefinitions: [ChannelBundleDefinition]
        let enabledBundleIDList: [String]
        let exclusiveRuleJSON: [ExclusiveRuleJSON]
        let collectionRows: [StoredDiscoveredCollection]
        let collectionItems: [[PlexMediaItem]]
        let franchiseRows: [StoredFoundFranchise]
        let franchiseMovies: [[PlexMediaItem]]
        let franchiseTV: [[PlexMediaItem]]
    }

    static func makePayload(
        identity: String,
        serverName: String,
        librarySignature: String?,
        lastLoadAtUnix: Int,
        allItems: [PlexMediaItem],
        channelConfigChannels: [Channel],
        allChannels: [Channel],
        bundles: [ChannelBundle],
        enabledBundleIDs: Set<String>,
        exclusiveRules: [ExclusiveRule],
        discoveredCollections: [DiscoveredCollection],
        foundFranchises: [FoundFranchise] = []
    ) -> Payload {
        Payload(
            fingerprint: fingerprint(identity: identity),
            serverName: serverName,
            librarySignature: librarySignature,
            lastLoadAtUnix: lastLoadAtUnix,
            allItems: allItems,
            configRows: channelConfigChannels.map { $0.toStoredChannel(includeItemKeys: false) },
            visibleRows: allChannels.map { $0.toStoredChannel(includeItemKeys: false) },
            visiblePools: allChannels.map(\.itemPool),
            bundleDefinitions: bundles.map {
                ChannelBundleDefinition(id: $0.id, name: $0.name, description: $0.description,
                                        channelIDs: $0.channelIDs, activeMonths: $0.activeMonths,
                                        seasonStart: $0.seasonStart)
            },
            enabledBundleIDList: Array(enabledBundleIDs).sorted(),
            exclusiveRuleJSON: exclusiveRules.map { $0.toExclusiveRuleJSON() },
            collectionRows: discoveredCollections.map { StoredDiscoveredCollection.from($0, includeItemKeys: false) },
            collectionItems: discoveredCollections.map(\.items),
            franchiseRows: foundFranchises.map { StoredFoundFranchise.from($0, includeItemKeys: false) },
            franchiseMovies: foundFranchises.map(\.movies),
            franchiseTV: foundFranchises.map(\.tvItems)
        )
    }

    /// Queues the write on a background queue and returns at once. A newer request or a
    /// clear() made before it commits wins; the older write is abandoned and its files removed.
    static func saveInBackground(_ payload: Payload) {
        let e = nextEpoch()
        writeQueue.async {
            do {
                try write(payload, epoch: e)
            } catch SnapshotError.superseded {
                // A newer save or a clear() owns the snapshot now.
            } catch {
                InstallDiagnostics.fail("snapshot: save failed: \(String(describing: error))")
            }
        }
    }

    /// Synchronous save: same write, same queue, waits for it. Tests and migration tooling.
    static func save(
        identity: String,
        serverName: String,
        librarySignature: String?,
        lastLoadAtUnix: Int,
        allItems: [PlexMediaItem],
        channelConfigChannels: [Channel],
        allChannels: [Channel],
        bundles: [ChannelBundle],
        enabledBundleIDs: Set<String>,
        exclusiveRules: [ExclusiveRule],
        discoveredCollections: [DiscoveredCollection],
        foundFranchises: [FoundFranchise] = []
    ) throws {
        let payload = makePayload(
            identity: identity, serverName: serverName, librarySignature: librarySignature,
            lastLoadAtUnix: lastLoadAtUnix, allItems: allItems, channelConfigChannels: channelConfigChannels,
            allChannels: allChannels, bundles: bundles, enabledBundleIDs: enabledBundleIDs,
            exclusiveRules: exclusiveRules, discoveredCollections: discoveredCollections,
            foundFranchises: foundFranchises)
        let e = nextEpoch()
        try writeQueue.sync { try write(payload, epoch: e) }
    }

    /// Test hook: called after each chunk file is written, with the chunk index. Lets a
    /// test stop a save part way, the way jetsam would.
    nonisolated(unsafe) static var afterChunkWritten: ((Int) throws -> Void)?

    private static func write(_ p: Payload, epoch e: UInt64) throws {
        guard let root = snapshotDirectoryURL else { throw SnapshotError.noApplicationSupport }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        removeUnreferencedGenerations(in: root)
        guard isCurrent(e) else { throw SnapshotError.superseded }

        let generation = "g-" + UUID().uuidString
        let dir = root.appendingPathComponent(generation, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: dir) } }

        let encoder = JSONEncoder()
        let items = p.allItems
        var counts: [Int] = []
        counts.reserveCapacity(items.count / chunkSize + 1)
        var start = 0
        while start < items.count {
            guard isCurrent(e) else { throw SnapshotError.superseded }
            let end = min(start + chunkSize, items.count)
            let index = counts.count
            try autoreleasepool {
                let data = try encoder.encode(Array(items[start..<end]))
                try data.write(to: dir.appendingPathComponent(chunkName(index)))
            }
            counts.append(end - start)
            start = end
            try afterChunkWritten?(index)
        }
        LibraryLoadProbe.mark("snapshot.chunks")

        var indexByID: [String: Int32] = [:]
        indexByID.reserveCapacity(items.count)
        for (i, item) in items.enumerated() where indexByID[item.id] == nil {
            indexByID[item.id] = Int32(i)
        }
        func indexes(_ pool: [PlexMediaItem]) -> [Int32] { pool.compactMap { indexByID[$0.id] } }

        let meta = LibrarySnapshotMetaV3(
            schemaVersion: formatVersion,
            credentialFingerprint: p.fingerprint,
            lastLoadAtUnix: p.lastLoadAtUnix,
            serverName: p.serverName,
            librarySignature: p.librarySignature,
            itemCount: items.count,
            chunkItemCounts: counts,
            channelConfigRows: p.configRows,
            allChannelRows: p.visibleRows,
            allChannelPools: p.visiblePools.map(indexes),
            bundleDefinitions: p.bundleDefinitions,
            enabledBundleIDList: p.enabledBundleIDList,
            exclusiveRuleJSON: p.exclusiveRuleJSON,
            discoveredCollectionRows: p.collectionRows,
            discoveredCollectionItems: p.collectionItems.map(indexes),
            foundFranchiseRows: p.franchiseRows,
            foundFranchiseMovieItems: p.franchiseMovies.map(indexes),
            foundFranchiseTVItems: p.franchiseTV.map(indexes)
        )
        indexByID = [:]
        try autoreleasepool {
            try encoder.encode(meta).write(to: dir.appendingPathComponent(metaName))
        }
        LibraryLoadProbe.mark("snapshot.meta")

        // Commit. Holding the lock clear() deletes under means a clear() either ran first
        // (epoch moved, nothing commits) or runs after and removes what this wrote.
        let manifest = LibrarySnapshotManifestV3(format: formatVersion, generation: generation,
                                                 itemCount: items.count, chunkCount: counts.count)
        let manifestData = try encoder.encode(manifest)
        epochLock.lock()
        guard epoch == e else {
            epochLock.unlock()
            throw SnapshotError.superseded
        }
        do {
            try manifestData.write(to: root.appendingPathComponent(manifestName), options: .atomic)
        } catch {
            epochLock.unlock()
            throw error
        }
        committed = true
        epochLock.unlock()

        removeUnreferencedGenerations(in: root)
        if let legacy = legacyFileURL { try? fm.removeItem(at: legacy) }
        LibraryLoadProbe.mark("snapshot.commit")
        InstallDiagnostics.note("snapshot: saved \(items.count) items in \(counts.count) chunks, \(p.visibleRows.count) channels")
    }

    private static func readManifest(in root: URL) -> LibrarySnapshotManifestV3? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(LibrarySnapshotManifestV3.self, from: data)
    }

    /// Generation directories a killed or superseded save left behind. Only the writer
    /// queue calls this, so the one generation being written is never in the listing.
    private static func removeUnreferencedGenerations(in root: URL) {
        let live = readManifest(in: root)?.generation
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix("g-") && name != live {
            try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: Load

    struct Loaded {
        var snapshot: LibrarySnapshotV1
        let isStale: Bool
        /// Came from the legacy single file; the caller re-saves so the next launch reads v3.
        let fromLegacyFile: Bool
    }

    /// Loads the snapshot when it belongs to `identity`. `isStale` is true past the refresh
    /// window. Nil when there is none or it belongs to another library; throws when the
    /// files are there but unreadable (the caller falls back to a scan).
    static func loadSnapshot(identity: String) throws -> Loaded? {
        guard let root = snapshotDirectoryURL else {
            InstallDiagnostics.note("snapshot: no local store directory")
            return nil
        }
        let fp = fingerprint(identity: identity)
        let snap: LibrarySnapshotV1
        var fromLegacy = false
        if let manifest = readManifest(in: root) {
            guard manifest.format == formatVersion else {
                InstallDiagnostics.note("snapshot: format mismatch (file=\(manifest.format), expected=\(formatVersion)), clearing")
                clear()
                return nil
            }
            guard let loaded = try loadChunked(root: root, manifest: manifest, fingerprint: fp) else { return nil }
            snap = loaded
        } else if let legacy = legacyFileURL, FileManager.default.fileExists(atPath: legacy.path) {
            guard let loaded = try loadLegacy(at: legacy, fingerprint: fp) else { return nil }
            snap = loaded
            fromLegacy = true
        } else {
            InstallDiagnostics.note("snapshot: none on disk")
            return nil
        }

        let now = Int(Date().timeIntervalSince1970)
        let ageSeconds = now - snap.lastLoadAtUnix
        let isStale = ageSeconds >= Self.refreshAfterSeconds
        let ageHours = ageSeconds / 3600
        if isStale {
            InstallDiagnostics.note("snapshot: \(ageHours)h old (>\(Self.refreshAfterSeconds / 3600)h), will refresh in background")
        } else {
            InstallDiagnostics.note("snapshot: hit, \(ageHours)h old, \(snap.allItems.count) items, \(snap.allChannelRows.count) channels")
        }
        return Loaded(snapshot: snap, isStale: isStale, fromLegacyFile: fromLegacy)
    }

    static func loadIfValid(identity: String) throws -> LibrarySnapshotV1? {
        guard let loaded = try loadSnapshot(identity: identity), !loaded.isStale else { return nil }
        return loaded.snapshot
    }

    private static func loadChunked(root: URL, manifest: LibrarySnapshotManifestV3, fingerprint fp: String) throws -> LibrarySnapshotV1? {
        let dir = root.appendingPathComponent(manifest.generation, isDirectory: true)
        let decoder = JSONDecoder()
        let meta: LibrarySnapshotMetaV3 = try autoreleasepool {
            let data = try Data(contentsOf: dir.appendingPathComponent(metaName), options: .mappedIfSafe)
            return try decoder.decode(LibrarySnapshotMetaV3.self, from: data)
        }
        guard meta.schemaVersion == formatVersion else {
            InstallDiagnostics.note("snapshot: schema mismatch (file=\(meta.schemaVersion), expected=\(formatVersion)), clearing")
            clear()
            return nil
        }
        guard meta.credentialFingerprint == fp else {
            InstallDiagnostics.note("snapshot: credential fingerprint mismatch — stored=\(meta.credentialFingerprint.prefix(8))… current=\(fp.prefix(8))…")
            return nil
        }
        guard meta.chunkItemCounts.count == manifest.chunkCount,
              meta.chunkItemCounts.reduce(0, +) == manifest.itemCount,
              meta.itemCount == manifest.itemCount else {
            throw SnapshotError.inconsistent("manifest says \(manifest.itemCount) items in \(manifest.chunkCount) chunks, meta disagrees")
        }

        var items: [PlexMediaItem] = []
        items.reserveCapacity(meta.itemCount)
        for (i, expected) in meta.chunkItemCounts.enumerated() {
            try autoreleasepool {
                let data = try Data(contentsOf: dir.appendingPathComponent(chunkName(i)), options: .mappedIfSafe)
                let chunk = try decoder.decode([PlexMediaItem].self, from: data)
                guard chunk.count == expected else {
                    throw SnapshotError.inconsistent("chunk \(i) holds \(chunk.count) items, expected \(expected)")
                }
                items.append(contentsOf: chunk)
            }
        }
        LibraryLoadProbe.mark("snapshot.load.chunks")

        func keys(_ indexes: [Int32]) -> [String] {
            indexes.compactMap { i in
                let i = Int(i)
                return i >= 0 && i < items.count ? items[i].id : nil
            }
        }
        let channelRows = zip(meta.allChannelRows, meta.allChannelPools).map { row, pool in
            row.withItemRatingKeys(keys(pool))
        }
        let collectionRows = zip(meta.discoveredCollectionRows, meta.discoveredCollectionItems).map { row, members in
            row.withItemRatingKeys(keys(members))
        }
        // Absent (a v3 snapshot from before franchises) stays nil: nothing found yet.
        let franchiseRows: [StoredFoundFranchise]? = meta.foundFranchiseRows.map { rows in
            let movies = meta.foundFranchiseMovieItems ?? []
            let tv = meta.foundFranchiseTVItems ?? []
            return rows.enumerated().map { i, row in
                row.withRatingKeys(movies: i < movies.count ? keys(movies[i]) : [],
                                   tv: i < tv.count ? keys(tv[i]) : [])
            }
        }
        return LibrarySnapshotV1(
            schemaVersion: meta.schemaVersion,
            credentialFingerprint: meta.credentialFingerprint,
            lastLoadAtUnix: meta.lastLoadAtUnix,
            serverName: meta.serverName,
            allItems: items,
            channelConfigRows: meta.channelConfigRows,
            allChannelRows: channelRows,
            bundleDefinitions: meta.bundleDefinitions,
            enabledBundleIDList: meta.enabledBundleIDList,
            exclusiveRuleJSON: meta.exclusiveRuleJSON,
            discoveredCollectionRows: collectionRows,
            librarySignature: meta.librarySignature,
            foundFranchiseRows: franchiseRows
        )
    }

    /// The v2 single file. Decoded once if it is small enough, then the caller re-saves it
    /// as v3 (which deletes this file on commit). Too big: deleted, and the launch scans.
    private static func loadLegacy(at url: URL, fingerprint fp: String) throws -> LibrarySnapshotV1? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size <= legacyMaxBytes else {
            InstallDiagnostics.note("snapshot: legacy file is \(size / 1_048_576) MB, over the \(legacyMaxBytes / 1_048_576) MB migration cap; discarding, will rescan")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let snap: LibrarySnapshotV1 = try autoreleasepool {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            do {
                return try JSONDecoder().decode(LibrarySnapshotV1.self, from: data)
            } catch {
                InstallDiagnostics.note("snapshot: legacy decode failed (\(data.count) bytes): \(error)")
                throw error
            }
        }
        guard snap.schemaVersion == 2 else {
            InstallDiagnostics.note("snapshot: legacy schema \(snap.schemaVersion), clearing")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard snap.credentialFingerprint == fp else {
            InstallDiagnostics.note("snapshot: credential fingerprint mismatch — stored=\(snap.credentialFingerprint.prefix(8))… current=\(fp.prefix(8))…")
            return nil
        }
        InstallDiagnostics.note("snapshot: migrating legacy single-file snapshot (\(snap.allItems.count) items)")
        return snap
    }

    enum SnapshotError: Error {
        case noApplicationSupport
        case superseded
        case inconsistent(String)
    }
}

// MARK: - Renumbered lineup

extension LibrarySnapshotV1 {
    /// Gives the stored channels the numbers `numbers` (channel id to number, from the
    /// channels.json this build carries) says, and rewrites the "CH <n> NAME" labels the
    /// collection rows keep (`matchedChannel`, `foldedIntoFranchise`) to match.
    ///
    /// A restore builds the guide from these rows, not from channels.json, so without this
    /// an update that renumbers the lineup (1.0.29 put every package in its own block) kept
    /// the old numbers until the next library refresh, up to a day later. The labels matter
    /// beyond Settings: the franchise fold compares `matchedChannel` with a label built from
    /// the live number, so a stale one stops a collection folding. Ids never change, and a
    /// row whose id `numbers` lacks keeps its number. Returns how many rows moved.
    @discardableResult
    mutating func renumberChannels(_ numbers: [Int: Int]) -> Int {
        var labels: [String: String] = [:]
        var moved = 0
        func renumbered(_ rows: [StoredChannel], counting: Bool) -> [StoredChannel] {
            rows.map { row in
                guard let number = numbers[row.id], number != row.number else { return row }
                labels["CH \(row.number) \(row.name)"] = "CH \(number) \(row.name)"
                if counting { moved += 1 }
                return StoredChannel(id: row.id, number: number, name: row.name, colorHex: row.colorHex,
                                     category: row.category, minItems: row.minItems,
                                     isPremiereChannel: row.isPremiereChannel, rules: row.rules,
                                     timeRestrictions: row.timeRestrictions, enabled: row.enabled,
                                     itemRatingKeys: row.itemRatingKeys)
            }
        }
        channelConfigRows = renumbered(channelConfigRows, counting: false)
        allChannelRows = renumbered(allChannelRows, counting: true)
        guard !labels.isEmpty else { return moved }
        discoveredCollectionRows = discoveredCollectionRows.map { row in
            let matched = row.matchedChannel.map { labels[$0] ?? $0 }
            let folded = row.foldedIntoFranchise.map { labels[$0] ?? $0 }
            guard matched != row.matchedChannel || folded != row.foldedIntoFranchise else { return row }
            return StoredDiscoveredCollection(id: row.id, title: row.title, movieCount: row.movieCount,
                                              itemRatingKeys: row.itemRatingKeys, enabled: row.enabled,
                                              matchedChannel: matched, categoryRaw: row.categoryRaw,
                                              foldedIntoFranchise: folded)
        }
        return moved
    }
}

// MARK: - Channel ↔ stored row

extension StoredChannel {
    func withItemRatingKeys(_ keys: [String]) -> StoredChannel {
        StoredChannel(id: id, number: number, name: name, colorHex: colorHex, category: category,
                      minItems: minItems, isPremiereChannel: isPremiereChannel, rules: rules,
                      timeRestrictions: timeRestrictions, enabled: enabled, itemRatingKeys: keys)
    }
}

extension Channel {
    func toStoredChannel(includeItemKeys: Bool) -> StoredChannel {
        StoredChannel(
            id: id,
            number: number,
            name: name,
            colorHex: color.snapshotHexString,
            category: category,
            minItems: minItems,
            isPremiereChannel: isPremiereChannel,
            rules: rules?.toChannelRulesJSON(),
            timeRestrictions: timeRestrictions?.toTimeRestrictionsJSON(),
            enabled: enabled,
            itemRatingKeys: includeItemKeys ? itemPool.map(\.id) : []
        )
    }

    static func fromSnapshotRow(_ row: StoredChannel, itemLookup: (String) -> PlexMediaItem?, includePool: Bool) -> Channel {
        let pool: [PlexMediaItem] = includePool
            ? row.itemRatingKeys.compactMap(itemLookup)
            : []
        return Channel(
            id: row.id,
            number: row.number,
            name: row.name,
            color: Color(hex: row.colorHex),
            category: row.category,
            rules: row.rules?.toChannelRules(),
            timeRestrictions: row.timeRestrictions?.toTimeRestrictions(),
            minItems: row.minItems,
            isPremiereChannel: row.isPremiereChannel ?? false,
            itemPool: pool,
            enabled: row.enabled
        )
    }
}

extension StoredDiscoveredCollection {
    static func from(_ collection: DiscoveredCollection, includeItemKeys: Bool = true) -> StoredDiscoveredCollection {
        StoredDiscoveredCollection(
            id: collection.id,
            title: collection.title,
            movieCount: collection.movieCount,
            itemRatingKeys: includeItemKeys ? collection.items.map(\.id) : [],
            enabled: collection.enabled,
            matchedChannel: collection.matchedChannel,
            categoryRaw: collection.category.rawValue,
            foldedIntoFranchise: collection.foldedIntoFranchise
        )
    }

    func withItemRatingKeys(_ keys: [String]) -> StoredDiscoveredCollection {
        StoredDiscoveredCollection(id: id, title: title, movieCount: movieCount, itemRatingKeys: keys,
                                   enabled: enabled, matchedChannel: matchedChannel, categoryRaw: categoryRaw,
                                   foldedIntoFranchise: foldedIntoFranchise)
    }

    /// A row whose category reads "actors" (the retired NOTABLE STARS) resolves to
    /// `.custom`, which is where those collections classify now.
    func resolve(itemLookup: (String) -> PlexMediaItem?) -> DiscoveredCollection {
        let items = itemRatingKeys.compactMap(itemLookup)
        let category = CollectionCategory(rawValue: categoryRaw) ?? .custom
        return DiscoveredCollection(
            id: id,
            title: title,
            movieCount: movieCount,
            items: items,
            enabled: enabled,
            matchedChannel: matchedChannel,
            category: category,
            foldedIntoFranchise: foldedIntoFranchise
        )
    }

    func resolve(itemLookup: [String: PlexMediaItem]) -> DiscoveredCollection {
        resolve(itemLookup: { itemLookup[$0] })
    }
}

extension StoredFoundFranchise {
    static func from(_ franchise: FoundFranchise, includeItemKeys: Bool = true) -> StoredFoundFranchise {
        StoredFoundFranchise(
            id: franchise.id,
            name: franchise.name,
            movieRatingKeys: includeItemKeys ? franchise.movies.map(\.id) : [],
            tvRatingKeys: includeItemKeys ? franchise.tvItems.map(\.id) : [],
            coveredByChannelID: franchise.coveredByChannelID,
            fromDictionary: franchise.fromDictionary
        )
    }

    func withRatingKeys(movies: [String], tv: [String]) -> StoredFoundFranchise {
        StoredFoundFranchise(id: id, name: name, movieRatingKeys: movies, tvRatingKeys: tv,
                             coveredByChannelID: coveredByChannelID, fromDictionary: fromDictionary)
    }

    func resolve(itemLookup: (String) -> PlexMediaItem?, enabledIDs: Set<String>,
                 disabledIDs: Set<String> = []) -> FoundFranchise {
        FoundFranchise(
            id: id,
            name: name,
            movies: movieRatingKeys.compactMap(itemLookup),
            tvItems: tvRatingKeys.compactMap(itemLookup),
            coveredByChannelID: coveredByChannelID,
            fromDictionary: fromDictionary,
            enabled: coveredByChannelID == nil
                && FranchiseDictionary.isOn(id, enabledIDs: enabledIDs, disabledIDs: disabledIDs)
        )
    }

    func resolve(itemLookup: [String: PlexMediaItem], enabledIDs: Set<String>,
                 disabledIDs: Set<String> = []) -> FoundFranchise {
        resolve(itemLookup: { itemLookup[$0] }, enabledIDs: enabledIDs, disabledIDs: disabledIDs)
    }
}
