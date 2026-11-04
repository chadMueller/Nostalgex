import Foundation

/// The TMDB/OMDb enrichment cache on disk (I-073, GitHub #185).
///
/// The cache used to live in memory only, filled inside `enrichItems`. After a snapshot
/// restore it was empty, the 6h refresh skips an unchanged library, so it stayed empty for
/// the session; any package rebuild then read it empty, and every channel whose rule needs
/// enrichment (networks, keywords, production companies, OMDb scores: 50 of 142) came back
/// under `minItems`, was dropped, and the dropped lineup was saved as the snapshot. CARTOON
/// NETWORK (CH 215, a networks rule) was the one a viewer noticed.
///
/// One JSON file under `LocalStore` (Caches, so under a harness root when isolation is on),
/// rows keyed by TMDB id, each dropped after `ttl` like the web tuner's IndexedDB cache
/// (scripts/nostalgex-enrichment.js, CACHE_TTL_MS) and Roku's cachefs file
/// (roku/source/enrich/Enrichment.brs). Server-independent: a TMDB id means the same title
/// on every backend, so a sign-out keeps it.
enum EnrichmentCacheStore {
    static let fileName = "enrichment_cache_v1.json"
    /// Seven days, the same as the web tuner and Roku.
    static let ttl: TimeInterval = 7 * 86_400

    private static let queue = DispatchQueue(label: "nostalgex.enrichment-cache", qos: .utility)

    static var fileURL: URL? {
        LocalStore.rootDirectory?.appendingPathComponent(fileName)
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The rows still inside `ttl` as of `now`, or empty when there is no file or it does not
    /// decode (a half-written file from a kill, a future format): one rebuild, not a crash.
    static func load(now: Date = Date()) -> [String: MediaEnrichment] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let rows = try? makeDecoder().decode([String: MediaEnrichment].self, from: data) else { return [:] }
        return rows.filter { now.timeIntervalSince($0.value.fetchedAt) < ttl }
    }

    /// Encodes and writes on a background queue, atomically, so a kill mid-write leaves the
    /// previous file. Returns at once.
    static func saveInBackground(_ rows: [String: MediaEnrichment], completion: (@Sendable (Int) -> Void)? = nil) {
        guard let url = fileURL else { return }
        queue.async {
            do {
                let data = try makeEncoder().encode(rows)
                try data.write(to: url, options: .atomic)
                completion?(data.count)
            } catch {
                InstallDiagnostics.fail("enrichment cache: save failed: \(String(describing: error))")
            }
        }
    }

    /// Same, on the caller's thread. For tests and measurements.
    @discardableResult
    static func save(_ rows: [String: MediaEnrichment]) throws -> Int {
        guard let url = fileURL else { return 0 }
        let data = try makeEncoder().encode(rows)
        try data.write(to: url, options: .atomic)
        return data.count
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
