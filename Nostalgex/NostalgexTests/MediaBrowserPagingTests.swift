import XCTest
@testable import Nostalgex

/// #318: the Jellyfin and Emby collection list in pages of 500, and what reading library pages ahead could save.
final class MediaBrowserPagingTests: XCTestCase {
    private actor Calls { var starts: [Int] = []; func add(_ s: Int) { starts.append(s) } }

    /// 1,234 collections: three requests (0, 500, 1000), every one read.
    func testThePagesAreReadUntilTheTotal() async throws {
        let calls = Calls()
        let all = Array(0..<1234)
        let got: [Int] = try await MediaBrowserPaging.readAll(pageSize: 500) { start, limit in
            await calls.add(start)
            return (Array(all[start..<min(start + limit, all.count)]), all.count)
        }
        XCTAssertEqual(got, all)
        let starts = await calls.starts
        XCTAssertEqual(starts, [0, 500, 1000])
    }

    /// A server that leaves out TotalRecordCount, or sends a short page, or an empty one, still ends.
    func testAShortOrEmptyPageEnds() async throws {
        let short: [Int] = try await MediaBrowserPaging.readAll(pageSize: 500) { start, _ in
            (start == 0 ? Array(0..<500) : Array(0..<20), nil)
        }
        XCTAssertEqual(short.count, 520)
        let empty: [Int] = try await MediaBrowserPaging.readAll(pageSize: 500) { _, _ in ([], 9999) }
        XCTAssertEqual(empty.count, 0, "the server said 9,999 and sent none: one request, not a loop")
    }

    func testTheQueryAsksForAPage() {
        let q = Dictionary(uniqueKeysWithValues: MediaBrowserPaging.collectionQuery(userId: "u", start: 1000, limit: 500).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["IncludeItemTypes"], "BoxSet")
        XCTAssertEqual(q["StartIndex"], "1000")
        XCTAssertEqual(q["Limit"], "500")
        XCTAssertEqual(q["Fields"], "ChildCount")
    }

    /// What reading the next library page while this one is handled could save at most: the time the app spends on a
    /// page between two requests (decoding 200 items of a realistic answer). Prints `[PAGING]`.
    func testTheTimeBetweenTwoPageRequests() throws {
        func item(_ i: Int) -> [String: Any] {
            ["Id": String(format: "%032x", i), "Name": "Episode \(i)", "SeriesName": "A Show", "Type": "Episode",
             "Overview": String(repeating: "A long overview of the episode. ", count: 8), "ProductionYear": 1994,
             "PremiereDate": "1994-09-22T00:00:00.0000000Z", "DateCreated": "2024-03-02T10:00:00.0000000Z",
             "OfficialRating": "TV-PG", "CommunityRating": 8.4, "RunTimeTicks": 13_680_000_000, "Genres": ["Comedy", "Romance"],
             "ParentIndexNumber": 1, "IndexNumber": i % 24 + 1, "ProviderIds": ["Tmdb": "1668", "Imdb": "tt0108778", "Tvdb": "79168"],
             "Studios": [["Name": "NBC"]], "ImageTags": ["Primary": "abc123"],
             "UserData": ["Played": false, "PlayCount": 0],
             "MediaSources": [["Id": String(format: "%032x", i), "Container": "mkv", "RunTimeTicks": 13_680_000_000, "Bitrate": 13_000_000,
                               "MediaStreams": (0..<12).map { s in ["Type": s == 0 ? "Video" : (s < 4 ? "Audio" : "Subtitle"), "Codec": s == 0 ? "h264" : (s < 4 ? "ac3" : "srt"), "Index": s, "Language": "eng"] }]]]
        }
        let page = try JSONSerialization.data(withJSONObject: ["Items": (0..<200).map(item), "TotalRecordCount": 20000])
        struct Page: Decodable { let Items: [JellyfinItem]?; let TotalRecordCount: Int? }
        var times: [Double] = []
        for _ in 0..<20 {
            let t = Date()
            let decoded = try JSONDecoder().decode(Page.self, from: page)
            times.append(Date().timeIntervalSince(t) * 1000)
            XCTAssertEqual(decoded.Items?.count, 200)
        }
        times.sort()
        print(String(format: "[PAGING] 200-item page, %d KB: decode median %.1f ms, max %.1f ms (simulator, this Mac)", page.count / 1024, times[times.count / 2], times.last!))
    }
}

/// Reading pages ahead against a model server that takes a fixed time to build each page and builds them in parallel
/// (the web tuner's stub: 200 titles a page, 1 s a page, scaled down here). Prints `[PAGING]`.
final class MediaBrowserReadAheadTests: XCTestCase {
    private func run(ahead: Int?, pages: Int, perPage: Duration) async throws -> (Double, [Int]) {
        let all = Array(0..<(pages * 200))
        let fetch: @Sendable (Int, Int) async throws -> (items: [Int], total: Int?) = { start, limit in
            try await Task.sleep(for: perPage)
            return (Array(all[start..<min(start + limit, all.count)]), all.count)
        }
        let t = ContinuousClock.now
        let got: [Int]
        if let ahead {
            got = try await MediaBrowserPaging.readAllAhead(pageSize: 200, ahead: ahead, fetch: fetch)
        } else {
            got = try await MediaBrowserPaging.readAll(pageSize: 200, fetch: fetch)
        }
        let elapsed = ContinuousClock.now - t
        return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, got)
    }

    func testReadingAheadAgainstAModelServer() async throws {
        let pages = 30, per = Duration.milliseconds(100)
        let (seq, a) = try await run(ahead: nil, pages: pages, perPage: per)
        let (three, b) = try await run(ahead: 3, pages: pages, perPage: per)
        XCTAssertEqual(a, b, "the same items in the same order")
        print(String(format: "[PAGING] %d pages, %d ms a page, server builds in parallel: one at a time %.2f s, three ahead %.2f s (%.0f%% less)",
                     pages, 100, seq, three, (1 - three / seq) * 100))
        XCTAssertLessThan(three, seq * 0.5)
    }
}
