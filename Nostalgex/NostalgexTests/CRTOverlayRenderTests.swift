import XCTest
import SwiftUI
@testable import Nostalgex

/// Retro mode's overlay (`CRTOverlayView`) is scanlines, a vignette and flicker. These render it
/// once, over white, and read the pixels: the scanlines are a dark line every third row at the
/// scanline opacity, the vignette darkens the corners and edges and leaves the middle alone. The white
/// tracking line that used to run down the screen is gone, so nothing in the overlay is lighter than
/// the white behind it.
@MainActor
final class CRTOverlayRenderTests: XCTestCase {

    private let width = 600
    private let height = 338

    /// Red channel, 0...1, of every pixel, row by row, of the overlay drawn over white.
    private func render() throws -> [[Double]] {
        let view = CRTOverlayView()
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "the overlay did not render")
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, width)
        XCTAssertEqual(cg.height, height)
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &raw, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).map { y in (0..<width).map { x in Double(raw[(y * width + x) * 4]) / 255 } }
    }

    func testScanlinesStillDrawEveryThirdRow() throws {
        let pixels = try render()
        // A column well inside the picture, where the vignette adds nothing.
        let x = width / 2
        let column = (60..<(height - 60)).map { pixels[$0][x] }
        let darkest = try XCTUnwrap(column.min())
        let lightest = try XCTUnwrap(column.max())
        XCTAssertGreaterThan(lightest - darkest, 0.08, "scanlines darken some rows and leave the rows between them")
        // The dip is about the scanline opacity: black at RetroLook.scanlineOpacity over white, a 1.5 pt
        // line on a pixel grid, so a pixel row it covers three quarters of goes 0.75 of the way there.
        XCTAssertGreaterThan(darkest, 1 - RetroLook.scanlineOpacity - 0.04)
        XCTAssertLessThan(darkest, 1 - RetroLook.scanlineOpacity * 0.5)
        // Every third row is dark: the same pattern repeats with a period of three rows.
        let dark = column.enumerated().filter { $0.element < 0.95 }.map(\.offset)
        XCTAssertGreaterThan(dark.count, column.count / 4, "a dark row about every third row")
        for pair in zip(dark, dark.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1 - pair.0, 3, "no gap longer than the scanline spacing between dark rows")
        }
    }

    func testTheVignetteStillDarkensTheCornersAndLeavesTheMiddle() throws {
        let pixels = try render()
        let middle = pixels[height / 2][width / 2]
        let corner = pixels[2][2]
        XCTAssertGreaterThan(middle, 0.78, "the middle of the picture is only scanlined")
        XCTAssertLessThan(corner, 0.3, "the corner is dark")
        let edgeMid = pixels[height / 2][2]
        XCTAssertLessThan(edgeMid, middle - 0.2, "the side edge is darker than the middle")
        let topMid = pixels[2][width / 2]
        XCTAssertLessThan(topMid, middle - 0.2, "the top edge is darker than the middle")
    }

    /// With the tracking line gone, nothing the overlay draws is lighter than what is under it.
    func testNothingInTheOverlayIsBrighterThanTheWhiteBehindIt() throws {
        let pixels = try render()
        XCTAssertLessThanOrEqual(pixels.flatMap { $0 }.max() ?? 2, 1.0)
        // And over black, the only light the overlay adds is the faint edge stroke.
        let view = CRTOverlayView()
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.uiImage?.cgImage)
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &raw, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Away from the 2 pt edge stroke there is no light at all: no band of white across the picture.
        var brightest: UInt8 = 0
        for y in 8..<(height - 8) {
            for x in 8..<(width - 8) { brightest = max(brightest, raw[(y * width + x) * 4]) }
        }
        XCTAssertEqual(brightest, 0, "over black the overlay adds no light inside the edge")
    }
}
