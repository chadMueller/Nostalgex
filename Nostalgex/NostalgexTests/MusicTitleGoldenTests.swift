import XCTest
@testable import Nostalgex

/// N-034: `MusicTitleParser.clean` and `parse` against `scripts/music-title-golden.json`, the same
/// file the web tuner (`npm run test:music-title`) and the Roku port are held to. The note in the
/// file lists the nine steps; a case here that differs from the web is a bug in one of them.
final class MusicTitleGoldenTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Golden: Decodable {
        struct Clean: Decodable { let `in`: String; let out: String }
        struct Parse: Decodable { let `in`: String; let artist: String?; let song: String }
        let clean: [Clean]
        let parse: [Parse]
    }

    private func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.repoRoot.appendingPathComponent("scripts/music-title-golden.json")))
    }

    func testCleanMatchesTheSharedGolden() throws {
        let g = try golden()
        XCTAssertGreaterThanOrEqual(g.clean.count, 37)
        var wrong: [String] = []
        for c in g.clean where MusicTitleParser.clean(c.in) != c.out {
            wrong.append("\"\(c.in)\" -> \"\(MusicTitleParser.clean(c.in))\", golden \"\(c.out)\"")
        }
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) of \(g.clean.count) differ: \(wrong.prefix(5))")
    }

    func testParseMatchesTheSharedGolden() throws {
        let g = try golden()
        XCTAssertGreaterThanOrEqual(g.parse.count, 8)
        for p in g.parse {
            let got = MusicTitleParser.parse(p.in)
            XCTAssertEqual(got.artist, p.artist, p.in)
            XCTAssertEqual(got.song, p.song, p.in)
        }
    }
}
