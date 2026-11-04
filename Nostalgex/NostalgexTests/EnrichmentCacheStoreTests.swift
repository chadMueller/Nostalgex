import XCTest
@testable import Nostalgex

/// The enrichment cache on disk (I-073): survives a relaunch, drops rows past 7 days, lives
/// under the harness root when isolation is on, and costs little at 12,000 titles.
final class EnrichmentCacheStoreTests: XCTestCase {

    private var scope: HarnessScope?

    override func setUp() {
        super.setUp()
        scope = HarnessScope.begin("enrichment-cache")
        EnrichmentCacheStore.clear()
    }

    override func tearDown() {
        EnrichmentCacheStore.clear()
        scope?.end()
        scope = nil
        super.tearDown()
    }

    private func row(_ id: Int, fetchedAt: Date = Date(), keywords: Int = 8) -> MediaEnrichment {
        MediaEnrichment(
            tmdbID: String(id), imdbID: String(format: "tt%07d", id), mediaType: id % 3 == 0 ? "tv" : "movie",
            keywords: (0..<keywords).map { "keyword number \($0 + id % 5)" },
            networks: id % 3 == 0 ? ["Cartoon Network"] : [],
            productionCompanies: ["Studio \(id % 40)", "Partners \(id % 7)"],
            tmdbGenres: ["Animation", "Comedy", "Family"],
            imdbRating: id % 2 == 0 ? 7.4 : nil, imdbVotes: id % 2 == 0 ? 120_331 : nil,
            rottenTomatoesScore: id % 4 == 0 ? 81 : nil, metacriticScore: nil,
            awards: id % 10 == 0 ? "Won 1 Oscar. 12 wins & 30 nominations total" : nil,
            franchiseID: id % 6 == 0 ? 1_000 + id % 50 : nil, franchiseName: id % 6 == 0 ? "Collection \(id % 50)" : nil,
            fetchedAt: fetchedAt)
    }

    func testTheFileLivesUnderTheHarnessRoot() throws {
        let url = try XCTUnwrap(EnrichmentCacheStore.fileURL)
        let root = try XCTUnwrap(HarnessIsolation.root)
        XCTAssertTrue(url.path.hasPrefix(root.path), "\(url.path) is not under \(root.path)")
    }

    func testRowsComeBackAfterARelaunchAndOldOnesDoNot() throws {
        let fresh = row(1)
        let old = row(2, fetchedAt: Date().addingTimeInterval(-EnrichmentCacheStore.ttl - 60))
        let justInside = row(3, fetchedAt: Date().addingTimeInterval(-EnrichmentCacheStore.ttl + 3_600))
        try EnrichmentCacheStore.save(["1": fresh, "2": old, "3": justInside])

        let loaded = EnrichmentCacheStore.load()
        XCTAssertEqual(Set(loaded.keys), ["1", "3"], "the 7-day row is gone, the rest stay")
        XCTAssertEqual(loaded["1"]?.networks, [])
        XCTAssertEqual(loaded["3"]?.networks, ["Cartoon Network"])
        XCTAssertEqual(loaded["1"]?.keywords.count, 8)
        XCTAssertEqual(loaded["1"]?.imdbRating, nil)
        XCTAssertEqual(loaded["3"]?.imdbID, "tt0000003")
        XCTAssertEqual(loaded["1"]?.fetchedAt.timeIntervalSince1970 ?? 0, fresh.fetchedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testAMissingOrBrokenFileIsAnEmptyCache() throws {
        XCTAssertEqual(EnrichmentCacheStore.load().count, 0)
        try Data("{not json".utf8).write(to: XCTUnwrap(EnrichmentCacheStore.fileURL))
        XCTAssertEqual(EnrichmentCacheStore.load().count, 0)
    }

    @MainActor
    func testTheServiceMergesDiskUnderMemory() throws {
        try EnrichmentCacheStore.save(["1": row(1), "2": row(2)])
        let service = EnrichmentService()
        let inMemory = MediaEnrichment(tmdbID: "1", imdbID: nil, mediaType: "movie", keywords: ["newer"], networks: [],
                                       productionCompanies: [], tmdbGenres: [], imdbRating: nil, imdbVotes: nil,
                                       rottenTomatoesScore: nil, metacriticScore: nil, awards: nil, fetchedAt: Date())
        service.seedCache([inMemory])
        XCTAssertEqual(service.loadDiskCache(), 2)
        XCTAssertEqual(service.cache.count, 2)
        XCTAssertEqual(service.cache["1"]?.keywords, ["newer"], "a row already in memory wins")
        XCTAssertEqual(service.cache["2"]?.productionCompanies.count, 2)
    }

    /// The cost at the size of the report's library (I-073 is a ~12k-title library): bytes
    /// on disk, time to encode and write, time to read and decode, and memory held.
    func testTwelveThousandRowsCost() throws {
        let rows = Dictionary(uniqueKeysWithValues: (1...12_000).map { (String($0), row($0, keywords: 6 + $0 % 10)) })
        let before = BigLibraryHarness.footprintBytes()
        let t0 = CFAbsoluteTimeGetCurrent()
        let bytes = try EnrichmentCacheStore.save(rows)
        let saved = CFAbsoluteTimeGetCurrent() - t0
        let t1 = CFAbsoluteTimeGetCurrent()
        let loaded = EnrichmentCacheStore.load()
        let loadTook = CFAbsoluteTimeGetCurrent() - t1
        let after = BigLibraryHarness.footprintBytes()
        XCTAssertEqual(loaded.count, 12_000)
        let line = String(format: "[ENRICHCACHE] 12,000 rows: %d KB on disk, save %.0f ms, load %.0f ms, footprint +%d MB",
                          bytes / 1024, saved * 1000, loadTook * 1000, Int(after) / 1_048_576 - Int(before) / 1_048_576)
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "enrichment-cache-cost.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(loadTook, 3, "a restore must not wait seconds on this file")
    }
}
