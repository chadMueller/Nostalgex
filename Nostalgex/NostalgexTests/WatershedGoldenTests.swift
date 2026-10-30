import XCTest
@testable import Nostalgex

/// Shared golden vectors for the global Watershed setting.
///
/// `scripts/watershed-golden.json` is read by this test AND by the web tuner's node test
/// (`npm run test:watershed`, scripts/nostalgex-watershed-smoke.mjs, which runs the same
/// cases against plex-tuner.html's `getTimeFilteredPool` and `isWatershedHold`). Both
/// engines must agree on which items a channel's pool keeps at a given local hour with
/// the toggle on or off, and on whether a channel counts as a Watershed hold (its pool
/// emptied by the gate alone, not a genuinely empty channel).
final class WatershedGoldenTests: XCTestCase {

    private struct Golden: Decodable {
        let cases: [Case]
    }

    private struct PoolItem: Decodable {
        let ratingKey: String
        let contentRating: String?
        let type: String
    }

    private struct Case: Decodable {
        let name: String
        let watershedEnabled: Bool
        let hour: Int
        let hasOwnBlockRatings: Bool
        let pool: [PoolItem]
        let expectPool: [String]
        let expectHold: Bool
    }

    /// Repo root, found from this source file: NostalgexTests -> Nostalgex -> root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func golden() throws -> Golden {
        try JSONDecoder().decode(
            Golden.self,
            from: Data(contentsOf: Self.repoRoot.appendingPathComponent("scripts/watershed-golden.json")))
    }

    private func mediaType(_ type: String) -> MediaType {
        type == "episode" ? .episode : .movie
    }

    private func item(_ p: PoolItem) -> PlexMediaItem {
        let type = mediaType(p.type)
        return PlexMediaItem(
            id: p.ratingKey, title: p.ratingKey, artist: nil, episodeTitle: nil, seTag: nil, summary: "",
            year: 2000, originallyAvailableAt: nil, contentRating: p.contentRating, duration: 100,
            ratingKey: p.ratingKey, partKey: nil, container: nil, videoCodec: nil, audioCodec: nil,
            videoProfile: nil, bitrate: nil, genres: ["Comedy"], rating: 0, userRating: 0, type: type,
            thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
            librarySource: type == .episode ? .tv : .movie, serverID: nil
        )
    }

    /// A `Date` whose local hour component reads back as `hour`, so `Channel.filteredPool`'s
    /// own `Calendar.current` read matches what the case asked for regardless of time zone.
    private func date(atHour hour: Int) throws -> Date {
        try XCTUnwrap(Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: Date()))
    }

    func testEveryGoldenCaseAgreesWithTheWebEngine() throws {
        let cases = try golden().cases
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            var channel = Channel(
                id: 7, number: 7, name: c.hasOwnBlockRatings ? "VHS VAULT" : "TEST CHANNEL",
                color: .blue, category: "nostalgex", rules: ChannelRules(),
                timeRestrictions: c.hasOwnBlockRatings
                    ? TimeRestrictions(blockRatings: BlockRatings(ratings: ["R", "NC-17"], blockBefore: 21, blockAfter: nil))
                    : nil,
                minItems: 0
            )
            channel.itemPool = c.pool.map(item)
            let now = try date(atHour: c.hour)

            let gotPool = channel.filteredPool(now: now, watershedEnabled: c.watershedEnabled).map(\.id)
            XCTAssertEqual(gotPool, c.expectPool, "\(c.name): pool")

            let gotHold = channel.isWatershedHold(now: now, watershedEnabled: c.watershedEnabled)
            XCTAssertEqual(gotHold, c.expectHold, "\(c.name): hold")
        }
    }

    // MARK: - Direct checks, not tied to the shared fixture file

    /// Mirrors `testBlockRatingsHoldsRatingsFromOtherCountries` in RatingGoldenTests:
    /// off by default, so shipping this feature never changes anyone's guide on its own.
    func testWatershedDefaultsOff() {
        var channel = Channel(
            id: 423, number: 35, name: "TEST CHANNEL", color: .blue, category: "nostalgex",
            rules: ChannelRules(), timeRestrictions: nil, minItems: 0
        )
        channel.itemPool = [item(PoolItem(ratingKey: "r", contentRating: "R", type: "movie"))]
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        // No watershedEnabled argument: the default reads the real Settings toggle, which
        // is false until a viewer turns it on in a fresh UserDefaults domain.
        XCTAssertFalse(channel.isWatershedHold(now: noon, watershedEnabled: false))
        XCTAssertEqual(channel.filteredPool(now: noon, watershedEnabled: false).map(\.id), ["r"])
    }

    /// VHS VAULT's own exemption, expressed directly against the real channel shape rather
    /// than the generic fixture: turning the global toggle on or off must not add or remove
    /// a single item from its pool.
    func testVHSVaultIsExemptFromTheGlobalToggleBothWays() {
        var channel = Channel(
            id: 7, number: 7, name: "VHS VAULT", color: .blue, category: "nostalgex",
            rules: ChannelRules(),
            timeRestrictions: TimeRestrictions(
                blockRatings: BlockRatings(ratings: ["R", "NC-17"], blockBefore: 21, blockAfter: nil)),
            minItems: 0
        )
        channel.itemPool = [
            item(PoolItem(ratingKey: "r", contentRating: "R", type: "movie")),
            item(PoolItem(ratingKey: "pg1", contentRating: "PG", type: "movie")),
            item(PoolItem(ratingKey: "pg2", contentRating: "PG", type: "movie")),
        ]
        let afternoon = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let withToggleOn = channel.filteredPool(now: afternoon, watershedEnabled: true).map(\.id)
        let withToggleOff = channel.filteredPool(now: afternoon, watershedEnabled: false).map(\.id)
        XCTAssertEqual(withToggleOn, withToggleOff)
        XCTAssertEqual(withToggleOn, ["pg1", "pg2"])
    }
}
