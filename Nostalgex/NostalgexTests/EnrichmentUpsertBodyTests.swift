import XCTest
@testable import Nostalgex

/// What the app sends to the shared `media_enrichments` table.
///
/// The table's API refuses a whole batch whose rows do not all carry the same keys
/// (PGRST102, HTTP 400; seen against the live project on 2026-11-23), and a row leaves out
/// what it does not know. So every request must hold rows with one set of keys.
final class EnrichmentUpsertBodyTests: XCTestCase {

    private func row(_ id: String, imdb: String? = nil, franchise: Int? = nil, rating: Double? = nil,
                     votes: Int? = nil, rottenTomatoes: Int? = nil) -> MediaEnrichment {
        MediaEnrichment(tmdbID: id, imdbID: imdb, mediaType: "movie", keywords: ["k"], networks: [],
                        productionCompanies: [], tmdbGenres: ["Drama"], imdbRating: rating, imdbVotes: votes,
                        rottenTomatoesScore: rottenTomatoes, metacriticScore: nil, awards: nil,
                        franchiseID: franchise, franchiseName: franchise.map { "Collection \($0)" },
                        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func rows(in body: Data) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    }

    func testEveryRequestHoldsRowsWithOneSetOfKeys() throws {
        let mixed = [
            row("1"),
            row("2", imdb: "tt0000002"),
            row("3", franchise: 10),
            row("4", imdb: "tt0000004"),
            row("5", imdb: "tt0000005", rating: 7.4, votes: 900),
            row("6"),
            row("7", imdb: "tt0000007", rating: 6.1, votes: 40),
            row("8", imdb: "tt0000008", rating: 8.0, votes: 12_000, rottenTomatoes: 91),
        ]
        // The fault this guards: one array of these, as the app sent before, mixes key sets.
        let asOneBatch = try rows(in: {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(mixed)
        }())
        XCTAssertEqual(Set(asOneBatch.map { $0.keys.sorted().joined(separator: ",") }).count, 5,
                       "the rows really do differ in their keys")

        let bodies = try SupabaseService.upsertBodies(for: mixed)
        XCTAssertEqual(bodies.count, 5, "five different sets of keys, five requests")
        var sent: [String] = []
        for body in bodies {
            let rows = try rows(in: body)
            XCTAssertEqual(Set(rows.map { $0.keys.sorted().joined(separator: ",") }).count, 1, "one request, one set of keys")
            for row in rows {
                XCTAssertFalse(row.values.contains { $0 is NSNull }, "a key is left out, never sent as null")
                sent.append(try XCTUnwrap(row["tmdb_id"] as? String))
            }
        }
        XCTAssertEqual(sent.sorted(), ["1", "2", "3", "4", "5", "6", "7", "8"], "every row goes, once")
        XCTAssertEqual(try rows(in: bodies[0]).compactMap { $0["tmdb_id"] as? String }, ["1", "6"], "in the order given")
    }

    func testAGroupIsSplitAtTheChunkSize() throws {
        let many = (1...450).map { row("\($0)") }
        let bodies = try SupabaseService.upsertBodies(for: many)
        XCTAssertEqual(try bodies.map { try rows(in: $0).count }, [200, 200, 50])
        XCTAssertTrue(try SupabaseService.upsertBodies(for: []).isEmpty)
    }
}
