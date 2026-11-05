import XCTest
@testable import Nostalgex

/// Shared vectors for which Jellyfin and Emby library views a scan reads, and what it asks them for
/// (#205, #206). `scripts/jellyfin-library-golden.json` is read by this test and by the web tuner's
/// node smoke (`npm run test:jellyfin-urls`): a view's CollectionType gives a section type and the
/// item types to ask for, and a row the server sent is kept or dropped by its `Type`.
final class JellyfinLibraryGoldenTests: XCTestCase {

    private struct Golden: Decodable {
        struct Section: Decodable { let collectionType: String?; let sectionType: String; let itemTypes: String? }
        struct Row: Decodable {
            let type: String?
            enum CodingKeys: String, CodingKey { case type = "Type" }
        }
        struct Kind: Decodable { let item: Row; let asked: String; let kept: Bool }
        let sections: [Section]
        let types: [Kind]
    }

    /// Repo root, found from this source file: NostalgexTests -> Nostalgex -> root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func golden() throws -> Golden {
        try JSONDecoder().decode(
            Golden.self,
            from: Data(contentsOf: Self.repoRoot.appendingPathComponent("scripts/jellyfin-library-golden.json")))
    }

    func testEveryViewTypeGivesTheSameSectionAndItemTypesAsTheWebTuner() throws {
        let cases = try golden().sections
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let label = c.collectionType.map { "\"\($0)\"" } ?? "no CollectionType"
            XCTAssertEqual(JellyfinAPIService.sectionType(for: c.collectionType), c.sectionType, label)
            XCTAssertEqual(JellyfinAPIService.itemTypes(forSectionType: c.sectionType), c.itemTypes, label)
        }
    }

    func testEveryRowIsKeptOrDroppedAsTheWebTunerDoesIt() throws {
        let cases = try golden().types
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(JellyfinAPIService.isAskedType(c.item.type, asked: c.asked), c.kept,
                           "Type \(c.item.type ?? "none") asked for \(c.asked)")
        }
    }

    /// Only the views that hold videos are sections: not offered in library selection, never read.
    func testViewsWithNoVideosAreNotSections() throws {
        let json = """
        { "Items": [
          { "Id": "1", "Name": "Movies", "CollectionType": "movies" },
          { "Id": "2", "Name": "Shows", "CollectionType": "tvshows" },
          { "Id": "3", "Name": "Playlists", "CollectionType": "playlists" },
          { "Id": "4", "Name": "Music", "CollectionType": "music" },
          { "Id": "5", "Name": "Everything" } ] }
        """
        struct Page: Decodable { let Items: [JellyfinItem] }
        let page = try JSONDecoder().decode(Page.self, from: Data(json.utf8))
        let sections = JellyfinAPIService.videoSections(from: page.Items)
        XCTAssertEqual(sections.map(\.title), ["Movies", "Shows", "Everything"])
        XCTAssertEqual(sections.map(\.type), ["movie", "show", "movie"])
    }

    func testAnItemKeepsItsType() throws {
        struct Page: Decodable { let Items: [JellyfinItem] }
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{ "Items": [ { "Id": "a", "Type": "Playlist" }, { "Id": "b" } ] }"#.utf8))
        XCTAssertEqual(page.Items.map(\.itemType), ["Playlist", nil])
    }
}
