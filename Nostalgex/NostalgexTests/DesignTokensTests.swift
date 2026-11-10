import XCTest
import UIKit
@testable import Nostalgex

/// The shared type scale and color list. Every text color has to read on every surface it can sit on
/// (4.5:1), nothing the viewer reads is below 25 pt, and nothing the viewer presses is below 29 pt.
final class DesignTokensTests: XCTestCase {

    // MARK: Contrast

    func testEveryTextColorReadsOnEverySurfaceItSitsOn() {
        XCTAssertGreaterThanOrEqual(NXColor.textPairs.count, 21)
        for pair in NXColor.textPairs {
            let ratio = NXRGB.contrast(pair.fg, pair.bg)
            XCTAssertGreaterThanOrEqual(ratio, pair.minimum, "\(pair.name): \(String(format: "%.2f", ratio)):1")
        }
    }

    /// The numbers the proposal prints (tokens.md), so a changed hex shows up here and not on a TV.
    func testTheProposalsNumbersHold() {
        func c(_ f: NXRGB, _ b: NXRGB) -> Double { (NXRGB.contrast(f, b) * 10).rounded() / 10 }
        XCTAssertEqual(c(NXColor.text, NXColor.panel), 19.1, accuracy: 0.15)
        XCTAssertEqual(c(NXColor.text2, NXColor.panel), 10.8, accuracy: 0.15)
        XCTAssertEqual(c(NXColor.cyan, NXColor.panel), 10.8, accuracy: 0.15)
        XCTAssertEqual(c(NXColor.text2, NXColor.selectedRow), 8.5, accuracy: 0.15)
        XCTAssertEqual(c(NXColor.text, NXColor.chosenNeutral), 11.6, accuracy: 0.15)
        XCTAssertEqual(c(NXColor.text2, NXColor.chosenNeutral), 6.6, accuracy: 0.15)
        XCTAssertEqual(c(NXColor.onCyan, NXColor.cyan), 10.9, accuracy: 0.15)
    }

    /// Red is a fill: it must not be offered as a text color on a row. Danger text is redText.
    func testRedIsNotATextColorOnARow() {
        XCTAssertLessThan(NXRGB.contrast(NXColor.red, NXColor.selectedRow), 4.5)
        XCTAssertGreaterThanOrEqual(NXRGB.contrast(NXColor.redText, NXColor.selectedRow), 4.5)
        XCTAssertFalse(NXColor.textPairs.contains { $0.name.hasPrefix("red on") })
    }

    func testCyanIsTheBrandCyanAsset() throws {
        let asset = try XCTUnwrap(UIColor(named: "BrandCyan"))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(asset.getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(Double(r), NXColor.cyan.r, accuracy: 0.005)
        XCTAssertEqual(Double(g), NXColor.cyan.g, accuracy: 0.005)
        XCTAssertEqual(Double(b), NXColor.cyan.b, accuracy: 0.005)
    }

    func testTextOnAChannelColorIsBlackOrWhiteWhicheverReadsBetter() {
        for hex: UInt32 in [0x00D4FF, 0xFFE500, 0xFF2244, 0x1A0A2E, 0xFFFFFF, 0x000000, 0x7C3AED, 0x808080] {
            let fill = NXRGB(hex)
            let text = NXColor.readableText(on: fill)
            XCTAssertTrue(text == NXColor.text || text == NXRGB(0x000000))
            XCTAssertGreaterThanOrEqual(NXRGB.contrast(text, fill), 4.5, String(hex, radix: 16))
        }
    }

    // MARK: Sizes

    func testTheScaleIsSixSizesAndNothingReadableIsBelowTheFloor() {
        XCTAssertEqual([NXType.hero, NXType.title, NXType.heading, NXType.body, NXType.caption, NXType.tag],
                       [96, 44, 34, 29, 25, 36])
        for size in NXType.dmMonoSizes { XCTAssertGreaterThanOrEqual(size, NXType.floor) }
        XCTAssertEqual(NXType.floor, 25)
        XCTAssertEqual(NXType.pressFloor, 29)
        XCTAssertGreaterThanOrEqual(NXType.body, NXType.pressFloor, "what the viewer presses is set in body or larger")
    }

    // MARK: The migrated files keep to the tokens

    private static let migrated = [
        "Views/Settings/SettingsSharedComponents.swift",
        "Views/Settings/SettingsRailView.swift",
        "Views/Settings/SettingsSupportView.swift",
        "Views/Settings/SettingsContainerView.swift",
        "Views/Settings/SettingsAboutView.swift",
        "Views/Settings/AboutLinks.swift",
        "Views/RatingNudgeBanner.swift",
    ]

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostalgex")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// A screen moved onto the tokens says so in its code: no literal font sizes, no white-with-opacity as text.
    func testMigratedScreensUseTheTokensNotLiteralSizesOrFadedWhite() throws {
        for file in Self.migrated {
            let text = try source(file)
            XCTAssertNil(text.range(of: #"\.font\(\.custom\("#, options: .regularExpression), "\(file): a literal font size")
            XCTAssertNil(text.range(of: #"foregroundStyle\([^)]*\.white\.opacity"#, options: .regularExpression), "\(file): faded white as text")
            XCTAssertNil(text.range(of: #"foregroundStyle\(\s*\.white\s*\)"#, options: .regularExpression), "\(file): bare white as text")
        }
    }

    func testTheMigratedFilesAreTheOnesTheListNames() throws {
        for file in Self.migrated { XCTAssertNoThrow(try source(file), file) }
    }
}
