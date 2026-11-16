import XCTest
@testable import Nostalgex

/// `scripts/guide-stripe-colours-golden.json`: the colour index of each bundle name, and the ten colours, as
/// `GuideStripes.Palette` gives them. The Apple TV is the source; the Android and Roku tests read the same file, so a
/// change to the hash or the palette on any one of the three shows up on the others.
///
/// To rewrite the file after a deliberate change: `TEST_RUNNER_NX_WRITE_STRIPE_GOLDEN=1`. The names are the ones
/// already in the file, plus every bundle name in `channels.json` (add a new bundle there and rewrite).
final class GuideStripeColoursGoldenTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var goldenURL: URL { Self.repoRoot.appendingPathComponent("scripts/guide-stripe-colours-golden.json") }

    private func read() throws -> (hexes: [String], names: [String: Int], order: [String]) {
        let data = try Data(contentsOf: goldenURL)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hexes = try XCTUnwrap(obj["hexes"] as? [String])
        let names = try XCTUnwrap(obj["names"] as? [String: Int])
        return (hexes, names, names.keys.sorted())
    }

    func testThePaletteAndEveryNameMatchTheGolden() throws {
        if ProcessInfo.processInfo.environment["NX_WRITE_STRIPE_GOLDEN"] != nil {
            let existing = try read().order
            let shipped = ChannelConfigLoader.loadBundled().bundles.map(\.name)
            let all = Array(Set(existing + shipped)).sorted()
            var lines = ["{", "  \"version\": 1,",
                         "  \"hexes\": [" + GuideStripes.Palette.hexes.map { "\"\($0)\"" }.joined(separator: ", ") + "],",
                         "  \"names\": {"]
            let rows = all.map { "    \(String(data: try! JSONEncoder().encode($0), encoding: .utf8)!): \(GuideStripes.Palette.index(for: $0))" }
            lines.append(rows.joined(separator: ",\n"))
            lines += ["  }", "}", ""]
            try lines.joined(separator: "\n").write(to: goldenURL, atomically: true, encoding: .utf8)
            return
        }
        let golden = try read()
        XCTAssertEqual(GuideStripes.Palette.hexes, golden.hexes)
        for (name, index) in golden.names {
            XCTAssertEqual(GuideStripes.Palette.index(for: name), index, name)
        }
        for bundle in ChannelConfigLoader.loadBundled().bundles {
            XCTAssertNotNil(golden.names[bundle.name], "\(bundle.name) is a shipped bundle and is not in the golden; rewrite it")
        }
    }
}
