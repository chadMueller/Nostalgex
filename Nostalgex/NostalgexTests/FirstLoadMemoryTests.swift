import XCTest
@testable import Nostalgex

/// Issue #146, the reporter's second message: every server worked on its own, and adding
/// them together in onboarding took the app to the home screen. `StopWaitingFirstRunHarnessTests
/// .testMultiServerOnboardingMemory` measured four servers (175,000 movies) in one load:
/// scanning them peaks at 235 MB and grows only by the items, but the channel build peaks near
/// 1 GB, and the pools alone were 800,305 slots of 592 bytes for 573,333 items (451 MB
/// allocated for 323 MB used). The slack is `compactMap` growing its result by doubling.
final class FirstLoadMemoryTests: XCTestCase {

    private func item(_ n: Int, title: String) -> PlexMediaItem {
        PlexMediaItem(
            id: "p\(n)", title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2000, originallyAvailableAt: nil, contentRating: "PG",
            duration: 95, ratingKey: "p\(n)", partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: ["Comedy"], rating: 7, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie)
    }

    private func cache(_ item: PlexMediaItem) -> AppState.FilterCache {
        AppState.FilterCache(item: item, titleLower: item.title.lowercased(), episodeTitleLower: "",
                             genresLowerSet: ["comedy"], enrichment: nil, itemStudioLower: "")
    }

    /// A pool the build hands back holds only the slots it uses, give or take an eighth.
    /// `compactMap` grows its result in steps (for items this size: 1,328, 5,313, 21,254,
    /// 85,019 slots), so a pool just past a step carries about four times what it needs:
    /// 5,400 matches measured at 21,254 slots, 15,854 of them unused (9 MB).
    func testAPoolKeepsNoMoreSlotsThanItNeeds() {
        let items = (0 ..< 16_200).map { n in item(n, title: n % 3 == 0 ? "zebra film \(n)" : "other film \(n)") }
        let matching = items.filter { $0.title.hasPrefix("zebra") }
        XCTAssertEqual(matching.count, 5_400)
        var rules = ChannelRules()
        rules.titleContains = ["zebra"]

        let pool = AppState.filterItems(items.map(cache), rules: rules, forChannelID: 1, category: nil,
                                        memberships: .empty, exclusiveRules: [])

        XCTAssertEqual(pool.map(\.id), matching.map(\.id), "same items, same order")
        let slack = pool.capacity - pool.count
        XCTAssertLessThanOrEqual(slack, pool.count / 8 + 16,
                                 "\(pool.count) items in \(pool.capacity) slots: \(slack * MemoryLayout<PlexMediaItem>.stride / 1024) KB of 592-byte slots unused")
    }

    func testAPoolThatIsAlreadyTightIsReturnedAsItIs() {
        var tight: [PlexMediaItem] = []
        tight.reserveCapacity(64)
        tight.append(contentsOf: (0 ..< 64).map { item($0, title: "zebra \($0)") })
        let again = AppState.trimmed(tight)
        XCTAssertEqual(again.map(\.id), tight.map(\.id))
        XCTAssertEqual(again.capacity, tight.capacity, "nothing to trim, nothing copied")
        XCTAssertTrue(AppState.trimmed([]).isEmpty)
    }
}
