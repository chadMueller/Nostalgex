import XCTest
import SwiftUI
@testable import Nostalgex

/// The guide's package stripes: which package a channel is in, the runs that make a stripe, the colour of a
/// name and whether its text reads on it, the package boundary maths for Up and Down, and where a sticky label
/// sits in the viewport. All pure; the real focus engine is covered by `GuideStripeFocusTests` (UI).
@MainActor
final class GuideStripesTests: XCTestCase {

    private func channel(_ id: Int) -> Channel {
        Channel(id: id, number: id, name: "CH\(id)", color: .white, category: nil, rules: nil,
                timeRestrictions: nil, minItems: 0, itemPool: [])
    }

    private func bundle(_ id: String, _ name: String, _ ids: [Int]) -> ChannelBundle {
        ChannelBundle(id: id, name: name, description: nil, channelIDs: ids, activeMonths: nil, enabled: true)
    }

    private let franchises = "franchises"
    private let franchiseCollections = "collections-franchises"

    private func membership(_ bundles: [ChannelBundle], on: [String]? = nil, found: [Int] = []) -> [Int: GuidePackage] {
        GuideStripes.membership(
            bundles: bundles, enabledBundleIDs: Set(on ?? bundles.map(\.id)), foundFranchiseChannelIDs: found,
            franchisesBundleID: franchises, franchiseCollectionsBundleID: franchiseCollections
        )
    }

    // MARK: Which package a channel is in

    func testAChannelIsInThePackageThatListsIt() {
        let m = membership([bundle("a", "ALPHA", [1, 2]), bundle("b", "BETA", [3])])
        XCTAssertEqual(m[1]?.name, "ALPHA")
        XCTAssertEqual(m[2]?.name, "ALPHA")
        XCTAssertEqual(m[3]?.name, "BETA")
        XCTAssertNil(m[4], "in no package")
    }

    func testAPackageThatIsOffNamesNoChannel() {
        let m = membership([bundle("a", "ALPHA", [1, 2]), bundle("b", "BETA", [3])], on: ["a"])
        XCTAssertNil(m[3])
    }

    func testTheFirstPackageInOrderWinsAChannelListedTwice() {
        let m = membership([bundle("a", "ALPHA", [1]), bundle("b", "BETA", [1, 2])])
        XCTAssertEqual(m[1]?.name, "ALPHA")
        XCTAssertEqual(m[2]?.name, "BETA")
    }

    /// FRANCHISES reads as one package: the stock classics, the franchises found in the library and the
    /// server's franchise collections, named by the stock package.
    func testEveryFranchiseChannelIsInOnePackageNamedByTheStockPackage() {
        let bundles = [
            bundle("a", "ALPHA", [1]),
            bundle(franchiseCollections, "FRANCHISE SETS", [30]),
            bundle(franchises, "FRANCHISES", [10, 11]),
        ]
        let m = membership(bundles, found: [12])
        for id in [10, 11, 12, 30] { XCTAssertEqual(m[id]?.name, "FRANCHISES", "channel \(id)") }
        XCTAssertEqual(Set([10, 11, 12, 30].compactMap { m[$0]?.id }).count, 1, "one package, one id")
    }

    func testFranchiseCollectionsAloneAreNamedByTheirOwnPackage() {
        let m = membership([bundle("a", "ALPHA", [1]), bundle(franchiseCollections, "FRANCHISE SETS", [30])],
                           on: ["a", franchiseCollections])
        XCTAssertEqual(m[30]?.name, "FRANCHISE SETS")
    }

    func testFoundFranchisesAreNotAnyPackagesWhileFranchisesIsOff() {
        let m = membership([bundle("a", "ALPHA", [1]), bundle(franchises, "FRANCHISES", [10])], on: ["a"], found: [12])
        XCTAssertNil(m[12])
        XCTAssertNil(m[10])
    }

    // MARK: The runs

    func testConsecutiveRowsInOnePackageAreOneRun() {
        let channels = [1, 2, 3, 4, 5].map(channel)
        let m = membership([bundle("a", "ALPHA", [1, 2]), bundle("b", "BETA", [3, 4, 5])])
        let groups = GuideStripes.groups(channels: channels, membership: m)
        XCTAssertEqual(groups.map(\.name), ["ALPHA", "BETA"])
        XCTAssertEqual(groups.map(\.firstRow), [0, 2])
        XCTAssertEqual(groups.map(\.rowCount), [2, 3])
        XCTAssertEqual(groups.map(\.lastRow), [1, 4])
    }

    /// A channel in no package is not dropped: it is a run with no name, drawn as a plain stripe.
    func testChannelsInNoPackageAreARunWithNoName() {
        let channels = [1, 2, 9, 3].map(channel)
        let m = membership([bundle("a", "ALPHA", [1, 2]), bundle("b", "BETA", [3])])
        let groups = GuideStripes.groups(channels: channels, membership: m)
        XCTAssertEqual(groups.map(\.name), ["ALPHA", nil, "BETA"])
        XCTAssertEqual(groups.map(\.rowCount), [2, 1, 1])
    }

    /// If the guide lists a package's channels apart, each stretch is its own stripe.
    func testAPackageListedInTwoStretchesIsTwoRuns() {
        let channels = [1, 3, 2].map(channel)
        let m = membership([bundle("a", "ALPHA", [1, 2]), bundle("b", "BETA", [3])])
        XCTAssertEqual(GuideStripes.groups(channels: channels, membership: m).map(\.name), ["ALPHA", "BETA", "ALPHA"])
    }

    func testNoChannelsIsNoRuns() {
        XCTAssertEqual(GuideStripes.groups(channels: [], membership: [:]), [])
    }

    /// A package whose channels were all filtered out of the guide has no rows, so it has no stripe at all.
    func testAPackageWithNoRowsHasNoRun() {
        let channels = [3, 4].map(channel)
        let m = membership([bundle("a", "ALPHA", [1, 2]), bundle("b", "BETA", [3, 4])])
        XCTAssertEqual(GuideStripes.groups(channels: channels, membership: m).map(\.name), ["BETA"])
    }

    func testTheRunAChannelIsIn() {
        let channels = [1, 2, 3, 4, 5].map(channel)
        let groups = GuideStripes.groups(channels: channels, membership: membership([bundle("a", "A", [1, 2]), bundle("b", "B", [3, 4, 5])]))
        XCTAssertEqual(GuideStripes.groupIndex(containingRow: 0, in: groups), 0)
        XCTAssertEqual(GuideStripes.groupIndex(containingRow: 1, in: groups), 0)
        XCTAssertEqual(GuideStripes.groupIndex(containingRow: 2, in: groups), 1)
        XCTAssertEqual(GuideStripes.groupIndex(containingRow: 4, in: groups), 1)
        XCTAssertNil(GuideStripes.groupIndex(containingRow: 5, in: groups))
    }

    // MARK: Up and Down on the stripe

    private func groups(_ names: [String?], rows: Int = 2) -> [GuideStripeGroup] {
        names.enumerated().map { i, name in
            GuideStripeGroup(package: name.map { GuidePackage(id: $0, name: $0) }, firstRow: i * rows, rowCount: rows)
        }
    }

    func testDownGoesToTheNextPackageAndUpToThePrevious() {
        let g = groups(["A", "B", "C"])
        XCTAssertEqual(GuideStripes.neighbourIndex(from: 0, step: 1, in: g), 1)
        XCTAssertEqual(GuideStripes.neighbourIndex(from: 1, step: 1, in: g), 2)
        XCTAssertEqual(GuideStripes.neighbourIndex(from: 2, step: -1, in: g), 1)
        XCTAssertEqual(GuideStripes.neighbourIndex(from: 1, step: -1, in: g), 0)
    }

    func testThereIsNoWrapPastTheFirstOrLastPackage() {
        let g = groups(["A", "B", "C"])
        XCTAssertNil(GuideStripes.neighbourIndex(from: 0, step: -1, in: g))
        XCTAssertNil(GuideStripes.neighbourIndex(from: 2, step: 1, in: g))
    }

    /// Channels in no package are not a package to jump to: they are stepped over.
    func testAnUnnamedRunIsSteppedOver() {
        let g = groups(["A", nil, "B", nil])
        XCTAssertEqual(GuideStripes.neighbourIndex(from: 0, step: 1, in: g), 2)
        XCTAssertEqual(GuideStripes.neighbourIndex(from: 2, step: -1, in: g), 0)
        XCTAssertNil(GuideStripes.neighbourIndex(from: 2, step: 1, in: g), "only an unnamed run is left")
    }

    func testThereAreNoPackagesToMoveBetweenWhenNoRunIsNamed() {
        XCTAssertFalse(GuideStripes.hasPackages(groups([nil, nil])))
        XCTAssertFalse(GuideStripes.hasPackages([]))
        XCTAssertTrue(GuideStripes.hasPackages(groups([nil, "A"])))
    }

    // MARK: What each row draws

    func testEveryRowDrawsItsPackagesColourAndTheFirstOfARunStartsIt() {
        let g = [GuideStripeGroup(package: GuidePackage(id: "a", name: "ALPHA"), firstRow: 0, rowCount: 2),
                 GuideStripeGroup(package: nil, firstRow: 2, rowCount: 1),
                 GuideStripeGroup(package: GuidePackage(id: "b", name: "BETA"), firstRow: 3, rowCount: 2)]
        let cells = GuideStripes.rowCells(groups: g, count: 5)
        XCTAssertEqual(cells.map(\.startsRun), [true, false, true, true, false])
        XCTAssertEqual(cells[0].hex, GuideStripes.Palette.hex(for: "ALPHA"))
        XCTAssertEqual(cells[1].hex, GuideStripes.Palette.hex(for: "ALPHA"))
        XCTAssertNil(cells[2].hex, "no package: a plain stripe")
        XCTAssertEqual(cells[3].hex, GuideStripes.Palette.hex(for: "BETA"))
    }

    // MARK: Colour

    /// The same name is the same colour on every launch: these are pinned, so a change to the hash or the
    /// palette shows up here. (The shipped packages, by their names in the guide.)
    func testTheColourOfAShippedPackageNeverChanges() {
        let expected: [(String, Int)] = [
            ("NOSTALGEX", 9), ("KIDZ ZONE", 1), ("PRIME TIME", 6), ("MARQUEE", 1), ("ADVENTURELAND", 4),
            ("OVERTIME", 9), ("CASE FILES", 2), ("DECADES", 4), ("ARTHOUSE", 0), ("NETWORKS", 6), ("SCREAM", 0),
            ("TIS THE SEASON", 5), ("FRANCHISES", 6), ("HIGH ROTATION", 7),
        ]
        for (name, index) in expected {
            XCTAssertEqual(GuideStripes.Palette.index(for: name), index, name)
        }
    }

    func testTheColourDoesNotDependOnCase() {
        XCTAssertEqual(GuideStripes.Palette.index(for: "Kidz Zone"), GuideStripes.Palette.index(for: "KIDZ ZONE"))
    }

    func testEveryNameLandsInThePalette() {
        for name in ["", "A", "KIDZ ZONE", "A VERY LONG PACKAGE NAME WITH MANY WORDS", "ÅNGSTRÖM", "日本語"] {
            XCTAssertTrue(GuideStripes.Palette.hexes.indices.contains(GuideStripes.Palette.index(for: name)), name)
        }
    }

    func testThePaletteIsTenDistinctValidColoursFromTheApp() throws {
        let hexes = GuideStripes.Palette.hexes
        XCTAssertEqual(hexes.count, 10)
        XCTAssertEqual(Set(hexes).count, hexes.count, "no colour twice")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "channels", withExtension: "json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let channels = try XCTUnwrap(json["channels"] as? [[String: Any]])
        let appColours = Set(channels.compactMap { ($0["colorHex"] as? String)?.uppercased() })
        XCTAssertFalse(appColours.isEmpty)
        for hex in hexes {
            XCTAssertNotNil(UInt32(hex.dropFirst(), radix: 16), hex)
            XCTAssertTrue(appColours.contains(hex.uppercased()), "\(hex) is one of the channel colours the app already uses")
        }
    }

    /// The name on its stripe, white or black, never reads below 4.5 to 1 on any colour.
    func testTheNameReadsOnEveryStripeColour() {
        for hex in GuideStripes.Palette.hexes {
            XCTAssertGreaterThanOrEqual(GuideStripes.Palette.nameContrast(onHex: hex), 4.5, hex)
        }
    }

    func testTheBetterOfBlackAndWhiteIsChosen() {
        XCTAssertTrue(GuideStripes.Palette.nameIsBlack(onHex: "#F1C40F"), "yellow wants black")
        XCTAssertFalse(GuideStripes.Palette.nameIsBlack(onHex: "#8E44AD"), "purple wants white")
        XCTAssertEqual(GuideStripes.Palette.luminance(ofHex: "#FFFFFF"), 1, accuracy: 0.001)
        XCTAssertEqual(GuideStripes.Palette.luminance(ofHex: "#000000"), 0, accuracy: 0.001)
    }

    /// The shipped packages in guide order (by their first channel number): no two neighbours share a colour.
    func testNoTwoNeighbouringShippedPackagesShareAColour() {
        let config = ChannelConfigLoader.loadBundled()
        func firstNumber(_ b: ChannelBundleDefinition) -> Int {
            b.channelIDs.compactMap { id in config.channels.first { $0.id == id }?.number }.min() ?? Int.max
        }
        let ordered = config.bundles.filter { !$0.channelIDs.isEmpty }.sorted { firstNumber($0) < firstNumber($1) }
        XCTAssertGreaterThanOrEqual(ordered.count, 10)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertNotEqual(GuideStripes.Palette.index(for: a.name), GuideStripes.Palette.index(for: b.name),
                              "\(a.name) and \(b.name) are neighbours in the guide and the same colour")
        }
    }

    // MARK: Where things are on the screen

    private let pitch: CGFloat = 81

    func testAWholeRunThatIsOnScreenIsItsOwnSpan() {
        let g = GuideStripeGroup(package: GuidePackage(id: "a", name: "A"), firstRow: 2, rowCount: 3)
        let span = GuideStripes.visibleSpan(of: g, rowPitch: pitch, leading: 0, offset: 0, viewport: 463)
        XCTAssertEqual(span?.top, 162)
        XCTAssertEqual(span?.height, 243)
    }

    /// Scrolled so the run's first rows are gone: the span is what is left, from the top of the viewport.
    func testARunScrolledPartlyOffTheTopKeepsTheRowsThatAreLeft() {
        let g = GuideStripeGroup(package: GuidePackage(id: "a", name: "A"), firstRow: 0, rowCount: 5)   // 0 to 405
        let span = GuideStripes.visibleSpan(of: g, rowPitch: pitch, leading: 0, offset: 162, viewport: 463)
        XCTAssertEqual(span?.top, 0)
        XCTAssertEqual(span?.height, 243)
    }

    func testARunRunningOffTheBottomIsCutAtTheViewport() {
        let g = GuideStripeGroup(package: GuidePackage(id: "a", name: "A"), firstRow: 4, rowCount: 10)   // from 324
        let span = GuideStripes.visibleSpan(of: g, rowPitch: pitch, leading: 0, offset: 0, viewport: 463)
        XCTAssertEqual(span?.top, 324)
        XCTAssertEqual(span?.height, 139)
    }

    func testARunWhollyOffScreenHasNoSpan() {
        let g = GuideStripeGroup(package: GuidePackage(id: "a", name: "A"), firstRow: 0, rowCount: 2)
        XCTAssertNil(GuideStripes.visibleSpan(of: g, rowPitch: pitch, leading: 0, offset: 500, viewport: 463))
        let below = GuideStripeGroup(package: GuidePackage(id: "b", name: "B"), firstRow: 20, rowCount: 2)
        XCTAssertNil(GuideStripes.visibleSpan(of: below, rowPitch: pitch, leading: 0, offset: 0, viewport: 463))
    }

    /// The seasonal invite sits above the first channel and pushes every run down by its height.
    func testTheInviteRowPushesEveryRunDown() {
        let g = GuideStripeGroup(package: GuidePackage(id: "a", name: "A"), firstRow: 0, rowCount: 2)
        let span = GuideStripes.visibleSpan(of: g, rowPitch: pitch, leading: 80, offset: 0, viewport: 463)
        XCTAssertEqual(span?.top, 80)
        XCTAssertEqual(span?.height, 162)
    }

    func testLabelsAreOnlyForNamedRunsWithRoomForThem() {
        let g = [GuideStripeGroup(package: GuidePackage(id: "a", name: "ALPHA"), firstRow: 0, rowCount: 3),
                 GuideStripeGroup(package: nil, firstRow: 3, rowCount: 2),
                 GuideStripeGroup(package: GuidePackage(id: "b", name: "BETA"), firstRow: 5, rowCount: 1)]
        // Scrolled so that only 30 pt of ALPHA is left at the top.
        let labels = GuideStripes.labels(groups: g, rowPitch: pitch, leading: 0, offset: 213, viewport: 463)
        XCTAssertEqual(labels.map(\.name), ["BETA"], "ALPHA has 30 pt left, too little; the unnamed run has no name")
        let full = GuideStripes.labels(groups: g, rowPitch: pitch, leading: 0, offset: 0, viewport: 463)
        XCTAssertEqual(full.map(\.name), ["ALPHA", "BETA"])
        XCTAssertEqual(full.first?.top, 0)
        XCTAssertEqual(full.first?.height, 243)
    }

    /// A one-row package is 81 pt: room for a few letters, so it has a label (cut to fit by the view).
    func testAOneRowPackageHasALabel() {
        let g = [GuideStripeGroup(package: GuidePackage(id: "t", name: "TINY"), firstRow: 0, rowCount: 1)]
        XCTAssertEqual(GuideStripes.labels(groups: g, rowPitch: pitch, leading: 0, offset: 0, viewport: 463).count, 1)
    }

    /// The stripe takes the slot at the left of the rows and nothing else. The slot is what is left of the
    /// header's width (the 232 pt channel heading plus four 439 pt time columns, 1988 pt on a 1920 pt screen)
    /// once the row's content is centred in it. The live and the focused row have the wider accent bar, so
    /// they leave the least: 29.5 pt.
    func testTheStripeFitsTheSlotOnEveryRow() {
        let screen: CGFloat = 1920, channelColumn: CGFloat = 220
        let programs = screen - channelColumn
        let headerWidth = channelColumn + 12 + 4 * (programs / 4 + 14)
        for accent: CGFloat in [4, 8] {
            let content = accent + channelColumn + 1 + programs
            let slot = (headerWidth - content) / 2
            XCTAssertLessThan(GuideStripes.stripeWidth, slot, "accent \(accent)")
        }
        XCTAssertEqual((headerWidth - (8 + channelColumn + 1 + programs)) / 2, 29.5, accuracy: 0.01)
    }
}
