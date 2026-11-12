import XCTest
@testable import Nostalgex

/// The focused guide row: white text on a wash of the channel color was 2.5 to 3:1 on bright channels
/// (cyan, yellow, white). The fills behind it now keep the channel's look and get darker only as far as
/// white text needs to read at 4.5:1. Held over every channel color in `channels.json`, the demo channels,
/// and the extremes.
final class GuideRowContrastTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func shippedColors() throws -> [String] {
        struct File: Decodable { struct C: Decodable { let colorHex: String }; let channels: [C] }
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("channels.json"))
        return try JSONDecoder().decode(File.self, from: data).channels.map(\.colorHex)
    }

    func testWhiteTextReadsOnEveryChannelsFocusedFills() throws {
        let hexes = try shippedColors()
        XCTAssertGreaterThanOrEqual(hexes.count, 100)
        var worstRow = 100.0, worstBlock = 100.0
        for hex in Set(hexes) {
            let fills = GuideRowContrast.fills(forHex: hex)
            let row = NXRGB.contrast(NXColor.text, fills.row)
            let block = NXRGB.contrast(NXColor.text, fills.nowPlaying)
            worstRow = min(worstRow, row); worstBlock = min(worstBlock, block)
            XCTAssertGreaterThanOrEqual(row, 4.5, "row behind \(hex): \(String(format: "%.2f", row)):1")
            XCTAssertGreaterThanOrEqual(block, 4.5, "playing block behind \(hex): \(String(format: "%.2f", block)):1")
        }
        print("[GuideRowContrast] \(Set(hexes).count) colors, worst row \(worstRow), worst block \(worstBlock)")
    }

    func testTheExtremesAndTheDemoCyan() {
        for hex in ["#FFFFFF", "#FFFF00", "#00D4FF", "#00C4FF", "#FFE500", "#000000", "#1A0A2E"] {
            let f = GuideRowContrast.fills(forHex: hex)
            XCTAssertGreaterThanOrEqual(NXRGB.contrast(NXColor.text, f.row), 4.5, hex)
            XCTAssertGreaterThanOrEqual(NXRGB.contrast(NXColor.text, f.nowPlaying), 4.5, hex)
        }
    }

    /// A channel that already reads keeps exactly the wash it had; a bright one is darkened, and only
    /// as far as needed (the next step brighter would fail), so it still looks like its channel.
    func testDarkChannelsAreUntouchedAndBrightOnesAreDarkenedLeastBy() {
        let navy = NXColor.panel
        let dark = NXRGB(0x7C3AED)
        let darkFills = GuideRowContrast.fills(for: dark)
        XCTAssertEqual(darkFills.row, GuideRowContrast.rowWash(dark), "a channel that already reads is not changed")
        _ = navy

        let cyan = NXRGB(0x00D4FF)
        let wash = GuideRowContrast.playingWash(cyan)
        XCTAssertLessThan(NXRGB.contrast(NXColor.text, wash), 4.5, "the old half-strength cyan block did not read")
        let fixed = GuideRowContrast.fills(for: cyan).nowPlaying
        let c = NXRGB.contrast(NXColor.text, fixed)
        XCTAssertGreaterThanOrEqual(c, 4.5)
        XCTAssertLessThan(c, 4.6, "darkened no further than needed")
        // Same hue: the channels' ratios are kept.
        XCTAssertEqual(fixed.g / fixed.b, wash.g / wash.b, accuracy: 0.001)
    }

    func testTheBadHexFallsBackToWhiteAndStillReads() {
        let f = GuideRowContrast.fills(forHex: "nonsense")
        XCTAssertGreaterThanOrEqual(NXRGB.contrast(NXColor.text, f.row), 4.5)
    }
    // MARK: - The Watershed placeholder on a focused row

    /// Text-2 on a pale channel's focused wash was 4.3 to 4.7:1, and the placeholder's 2% lift took it to
    /// 4.1 to 4.4. It is brightened on those, only as far as 4.5:1 needs, and never touched elsewhere.
    func testThePlaceholderReadsOnEveryChannelsFocusedRow() throws {
        let hexes = Set(try shippedColors())
        XCTAssertGreaterThanOrEqual(hexes.count, 90)
        var worst = 100.0, changed = 0
        for hex in hexes {
            let surface = GuideRowContrast.placeholderSurface(for: GuideRowContrast.rgb(fromHex: hex))
            let text = GuideRowContrast.placeholderText(forHex: hex)
            let ratio = NXRGB.contrast(text, surface)
            worst = min(worst, ratio)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "placeholder on \(hex): \(String(format: "%.2f", ratio)):1")
            if text != NXColor.text2 {
                changed += 1
                XCTAssertLessThan(NXRGB.contrast(NXColor.text2, surface), 4.5, "\(hex) was changed though text-2 read")
                XCTAssertLessThan(ratio, 4.6, "\(hex) brightened further than needed")
                XCTAssertNotEqual(text, NXColor.text, "\(hex) went all the way to white")
            }
        }
        print("[GuideRowContrast] placeholder: \(hexes.count) colors, worst \(worst), \(changed) brightened")
    }

    func testThePalePlaceholderNumbers() {
        for hex in ["#F5E6C8", "#E5E5E5", "#FFE81F", "#FFE500", "#F7DC6F", "#FFD700"] {
            let surface = GuideRowContrast.placeholderSurface(for: GuideRowContrast.rgb(fromHex: hex))
            let before = NXRGB.contrast(NXColor.text2, surface)
            let after = NXRGB.contrast(GuideRowContrast.placeholderText(forHex: hex), surface)
            XCTAssertLessThan(before, 4.5, "\(hex) is one of the colors that did not read")
            XCTAssertGreaterThanOrEqual(after, 4.5, hex)
            print("[GuideRowContrast] \(hex) placeholder \(String(format: "%.2f", before)) -> \(String(format: "%.2f", after))")
        }
    }

    func testTextTwoIsKeptWhereItAlreadyReads() {
        let violet = GuideRowContrast.placeholderText(forHex: "#7C3AED")
        XCTAssertEqual(violet, NXColor.text2)
        let surface = NXColor.panel
        XCTAssertEqual(GuideRowContrast.secondaryText(on: surface), NXColor.text2)
        // On black text-2 reads anyway; on a surface it cannot reach, the answer is white-ward and bounded.
        let bright = NXRGB(0x808080)
        let t = GuideRowContrast.secondaryText(on: bright)
        XCTAssertGreaterThanOrEqual(NXRGB.contrast(NXColor.text, bright), 3.5)
        XCTAssertLessThanOrEqual(t.r, 1.0)
    }
}
