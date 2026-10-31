import XCTest
@testable import Nostalgex

/// A package should read as a block in the guide, not as channels scattered through the
/// lineup. SCREAM once ran 19, 77, 131 and 132 — a span of 114 for four channels.
final class ChannelNumberingTests: XCTestCase {

    private func config() throws -> ChannelConfigResult {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        return try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
    }

    func testEveryBundleIsOneUnbrokenRunOfNumbers() throws {
        let c = try config()
        let number = Dictionary(uniqueKeysWithValues: c.channels.map { ($0.id, $0.number) })
        for bundle in c.bundles where !bundle.id.hasPrefix("collections-") {
            let ns = bundle.channelIDs.compactMap { number[$0] }.sorted()
            guard let lo = ns.first, let hi = ns.last else { continue }
            XCTAssertEqual(hi - lo + 1, ns.count,
                "\(bundle.name) spans \(lo)-\(hi) for \(ns.count) channels; a package should be one block")
        }
    }

    func testNoTwoChannelsShareANumber() throws {
        let numbers = try config().channels.map(\.number)
        XCTAssertEqual(Set(numbers).count, numbers.count, "two channels claim the same number")
    }

    /// A channel can only sit in one block, so it can only belong to one bundle.
    func testNoChannelIsInTwoBundles() throws {
        let c = try config()
        var owner: [Int: String] = [:]
        for bundle in c.bundles where !bundle.id.hasPrefix("collections-") {
            for id in bundle.channelIDs {
                if let first = owner[id] {
                    XCTFail("channel \(id) is in both \(first) and \(bundle.name); it cannot be numbered into both")
                }
                owner[id] = bundle.name
            }
        }
    }

    func testEveryChannelBelongsToABundle() throws {
        let c = try config()
        let claimed = Set(c.bundles.flatMap(\.channelIDs))
        let orphans = c.channels.filter { !claimed.contains($0.id) }.map(\.name)
        XCTAssertTrue(orphans.isEmpty, "unreachable channels: \(orphans)")
    }

    /// Every package owns a block with room to grow, so a new channel never pushes the next
    /// package along (three 80s channels once moved KIDZ ZONE from 20 to 23). Each starts
    /// at its block's first number. 200-299 is free for future packages; runtime channels
    /// take 310-499 (`DynamicChannelBlock`).
    static let blocks: [String: ClosedRange<Int>] = [
        "nostalgex": 1...29, "kids": 30...49, "essentials": 50...69, "premium": 70...89,
        "adventureland": 90...109, "sports": 110...119, "truecrime": 120...129,
        "decades": 130...149, "arthouse": 150...159, "streamers": 160...179,
        "seasonal": 180...189, "tis-the-season": 190...199,
        "franchises": 300...309, "high-rotation": 500...519,
    ]

    func testEveryBundleStartsItsOwnBlock() throws {
        let c = try config()
        let number = Dictionary(uniqueKeysWithValues: c.channels.map { ($0.id, $0.number) })
        let shipped = c.bundles.filter { !$0.id.hasPrefix("collections-") }
        XCTAssertEqual(Set(shipped.map(\.id)), Set(Self.blocks.keys), "a package without a block, or a block without a package")
        for bundle in shipped {
            guard let block = Self.blocks[bundle.id] else { continue }
            let ns = bundle.channelIDs.compactMap { number[$0] }.sorted()
            XCTAssertEqual(ns.first, block.lowerBound, "\(bundle.name) should start at CH \(block.lowerBound)")
            XCTAssertTrue(ns.allSatisfy(block.contains), "\(bundle.name) runs \(ns) past \(block)")
        }
        let ranges = Self.blocks.values.sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThan(a.upperBound, b.lowerBound, "\(a) and \(b) overlap")
        }
    }

    func testRuntimeChannelsStayOutOfEveryPackageBlock() {
        for kind in DynamicChannelBlock.allCases {
            let runtime = kind.displayNumberBase...kind.displayNumberEnd
            for (id, block) in Self.blocks {
                XCTAssertFalse(runtime.overlaps(block), "\(kind) (\(runtime)) overlaps \(id) (\(block))")
            }
        }
    }

    // MARK: - A snapshot from before the renumber

    private func row(_ id: Int, _ number: Int, _ name: String) -> StoredChannel {
        StoredChannel(id: id, number: number, name: name, colorHex: "#FFFFFF", category: nil, minItems: 5,
                      isPremiereChannel: nil, rules: nil, timeRestrictions: nil, enabled: true,
                      itemRatingKeys: ["k\(id)"])
    }

    /// 1.0.28 saved STAR WARS (id 100) as CH 103 and KIDZ ZONE's FAMILY HOUR (id 20) as
    /// CH 23. A launch restores the guide from those rows, so they take this build's
    /// numbers by id, and the collection labels built from the old numbers follow.
    func testARestoredSnapshotTakesThisBuildsNumbers() throws {
        let c = try config()
        let number = Dictionary(uniqueKeysWithValues: c.channels.map { ($0.id, $0.number) })
        let starWars = try XCTUnwrap(number[100])
        let familyHour = try XCTUnwrap(number[20])
        let dynamicRow = row(1_020_000, 450, "HANKS")
        var snap = LibrarySnapshotV1(
            schemaVersion: 2, credentialFingerprint: "fp", lastLoadAtUnix: 0, serverName: "Test", allItems: [],
            channelConfigRows: [row(100, 103, "STAR WARS"), row(20, 23, "FAMILY HOUR")],
            allChannelRows: [row(100, 103, "STAR WARS"), row(20, 23, "FAMILY HOUR"), dynamicRow],
            bundleDefinitions: [], enabledBundleIDList: [], exclusiveRuleJSON: [],
            discoveredCollectionRows: [
                StoredDiscoveredCollection(id: "c-sw", title: "STAR WARS COLLECTION", movieCount: 9, itemRatingKeys: [],
                                           enabled: false, matchedChannel: "CH 103 STAR WARS", categoryRaw: "franchises",
                                           foldedIntoFranchise: "CH 103 STAR WARS"),
                StoredDiscoveredCollection(id: "c-wick", title: "JOHN WICK", movieCount: 4, itemRatingKeys: [],
                                           enabled: true, matchedChannel: nil, categoryRaw: "franchises",
                                           foldedIntoFranchise: "JOHN WICK"),
            ])

        XCTAssertEqual(snap.renumberChannels(number), 2)

        XCTAssertEqual(snap.allChannelRows.map(\.number), [starWars, familyHour, 450], "runtime rows are left alone")
        XCTAssertEqual(snap.allChannelRows.map(\.id), [100, 20, 1_020_000], "ids never change")
        XCTAssertEqual(snap.channelConfigRows.map(\.number), [starWars, familyHour])
        XCTAssertEqual(snap.allChannelRows[0].itemRatingKeys, ["k100"])
        XCTAssertEqual(snap.discoveredCollectionRows[0].matchedChannel, "CH \(starWars) STAR WARS")
        XCTAssertEqual(snap.discoveredCollectionRows[0].foldedIntoFranchise, "CH \(starWars) STAR WARS")
        XCTAssertEqual(snap.discoveredCollectionRows[1].foldedIntoFranchise, "JOHN WICK")

        XCTAssertEqual(snap.renumberChannels(number), 0, "a second launch finds nothing to move")
    }
}
