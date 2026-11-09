import XCTest
import SwiftUI
@testable import Nostalgex

/// The channel names a focused package row lists on CHANNEL PACKAGES (discussion #217): names
/// only, in the package's own order, the channels short of content marked, and the amber count
/// on the row read from the same list so it names exactly what it counts.
@MainActor
final class PackageChannelListingTests: XCTestCase {

    private typealias Availability = [(id: Int, name: String, hasContent: Bool)]

    private func availability(_ flags: [Bool]) -> Availability {
        flags.enumerated().map { (index, has) in (id: 100 + index, name: "CHANNEL \(index + 1)", hasContent: has) }
    }

    /// The rule the row's amber badge used before the list existed, kept here as the oracle.
    private func oldBadge(_ a: Availability, enabled: Bool, building: Bool) -> Int? {
        let available = a.filter(\.hasContent).count
        let missing = a.count - available
        return enabled && !building && available > 0 && missing > 0 ? missing : nil
    }

    // MARK: Names, in order

    func testTheNamesAreTheChannelsOfThePackageInPackageOrder() {
        let a: Availability = [(7, "SLIME TV", true), (3, "ANIMATION", false), (9, "FAMILY HOUR", true)]
        let listing = PackageChannelListing(availability: a, enabled: false, building: false)
        XCTAssertEqual(listing.names, ["SLIME TV", "ANIMATION", "FAMILY HOUR"], "the order the package lists them, not alphabetical, not by id")
        XCTAssertEqual(listing.entries.map(\.id), [7, 3, 9])
    }

    /// Every shipped package, read from channels.json the way the website's lineup does: the names
    /// are the package's `channelIDs` in order, each looked up in the same file, none dropped.
    func testEveryShippedPackageListsItsChannelsFromChannelsJSONInOrder() throws {
        let scope = HarnessScope.begin("package-channels-config")
        defer { scope.end() }
        let config = ChannelConfigLoader.loadBundled()
        XCTAssertFalse(config.bundles.isEmpty)
        let state = AppState()
        state.channelConfigChannels = config.channels
        state.allChannels = []

        for definition in config.bundles {
            let bundle = definition.toChannelBundle(enabled: false)
            let listing = PackageChannelListing(
                availability: state.bundleChannelAvailability(for: bundle), enabled: false, building: false
            )
            let expected = definition.channelIDs.compactMap { id in config.channels.first { $0.id == id }?.name }
            XCTAssertEqual(listing.names, expected, "\(definition.id): the names, in channels.json order")
            XCTAssertEqual(listing.names.count, definition.channelIDs.count, "\(definition.id): no channel id without a name in channels.json")
            XCTAssertNil(listing.badge, "\(definition.id): an off package is an invitation, never a warning")
            XCTAssertTrue(listing.shortChannels.isEmpty, "\(definition.id): none amber while off")
        }
    }

    /// The order the names are listed in is `channelIDs` order, and the website's lineup sorts each package
    /// by channel number (`scripts/generate-lineup-html.mjs`). They agree because every shipped package
    /// lists its channels by ascending channel number. (A channel's id and its number differ for some
    /// channels, so this is a fact about the file, not about ids.)
    func testEveryShippedPackageListsItsChannelsByAscendingChannelNumber() {
        let config = ChannelConfigLoader.loadBundled()
        XCTAssertFalse(config.bundles.isEmpty)
        for definition in config.bundles {
            let numbers = definition.channelIDs.compactMap { id in config.channels.first { $0.id == id }?.number }
            XCTAssertEqual(numbers.count, definition.channelIDs.count, "\(definition.id): every channel id is in channels.json")
            XCTAssertEqual(numbers, numbers.sorted(), "\(definition.id): channelIDs run by ascending channel number, as the website's lineup sorts them")
            XCTAssertEqual(Set(numbers).count, numbers.count, "\(definition.id): no channel listed twice")
        }
    }

    /// A long package, the shape that makes the row tall: NOSTALGEX lists 15 or more names.
    func testALongPackageListsEveryName() throws {
        let scope = HarnessScope.begin("package-channels-long")
        defer { scope.end() }
        let config = ChannelConfigLoader.loadBundled()
        let longest = try XCTUnwrap(config.bundles.max { $0.channelIDs.count < $1.channelIDs.count })
        XCTAssertGreaterThanOrEqual(longest.channelIDs.count, 15)
        let state = AppState()
        state.channelConfigChannels = config.channels
        let listing = PackageChannelListing(
            availability: state.bundleChannelAvailability(for: longest.toChannelBundle(enabled: false)),
            enabled: false, building: false
        )
        XCTAssertEqual(listing.entries.count, longest.channelIDs.count)
    }

    // MARK: Amber is exactly what the badge counts

    func testTheAmberChannelsAreExactlyTheChannelsWithoutContentAndTheBadgeCountsThem() {
        let listing = PackageChannelListing(
            availability: availability([true, false, true, false, false, true]), enabled: true, building: false
        )
        XCTAssertEqual(listing.shortChannels.map(\.name), ["CHANNEL 2", "CHANNEL 4", "CHANNEL 5"])
        XCTAssertEqual(listing.badge, 3, "the number on the row")
        XCTAssertEqual(listing.badge, listing.shortChannels.count, "the count names what it counts")
        XCTAssertEqual(listing.entries.filter(\.isShort).map(\.id), listing.shortChannels.map(\.id))
    }

    /// Exhaustive over every on/off, building and has-content pattern of up to six channels: the
    /// badge is the rule it replaced, and it always equals the number of amber names.
    func testTheBadgeIsTheOldRuleAndAlwaysTheNumberOfAmberNames() {
        for count in 0...6 {
            for pattern in 0..<(1 << count) {
                let flags = (0..<count).map { pattern & (1 << $0) != 0 }
                let a = availability(flags)
                for enabled in [false, true] {
                    for building in [false, true] {
                        let listing = PackageChannelListing(availability: a, enabled: enabled, building: building)
                        let label = "\(flags) enabled=\(enabled) building=\(building)"
                        XCTAssertEqual(listing.badge, oldBadge(a, enabled: enabled, building: building), label)
                        XCTAssertEqual(listing.badge ?? 0, listing.shortChannels.count, label)
                        XCTAssertEqual(listing.entries.count, count, "every channel is listed, amber or not: \(label)")
                    }
                }
            }
        }
    }

    func testAPackageThatIsOffMarksNothing() {
        let listing = PackageChannelListing(availability: availability([true, false, false]), enabled: false, building: false)
        XCTAssertEqual(listing.names.count, 3)
        XCTAssertTrue(listing.shortChannels.isEmpty)
        XCTAssertNil(listing.badge)
    }

    func testAPackageStillBuildingMarksNothing() {
        let listing = PackageChannelListing(availability: availability([true, false, false]), enabled: true, building: true)
        XCTAssertTrue(listing.shortChannels.isEmpty, "the row says it is finding channels; nothing is short yet")
        XCTAssertNil(listing.badge)
    }

    /// Nothing on air at all: the row's own line says "Not enough content to build this package", and
    /// the row dims. No amber count, so no amber names.
    func testAPackageWithNothingOnAirMarksNothing() {
        let listing = PackageChannelListing(availability: availability([false, false, false]), enabled: true, building: false)
        XCTAssertEqual(listing.names.count, 3)
        XCTAssertTrue(listing.shortChannels.isEmpty)
        XCTAssertNil(listing.badge)
    }

    func testAPackageWithNoMissingChannelsHasNoAmberAndNoBadge() {
        let listing = PackageChannelListing(availability: availability([true, true, true, true]), enabled: true, building: false)
        XCTAssertEqual(listing.names, ["CHANNEL 1", "CHANNEL 2", "CHANNEL 3", "CHANNEL 4"])
        XCTAssertTrue(listing.shortChannels.isEmpty)
        XCTAssertNil(listing.badge)
    }

    func testAnEmptyPackageListsNothing() {
        for enabled in [false, true] {
            let listing = PackageChannelListing(availability: [], enabled: enabled, building: false)
            XCTAssertTrue(listing.entries.isEmpty)
            XCTAssertEqual(listing.names, [])
            XCTAssertNil(listing.badge)
        }
    }

    // MARK: Through AppState

    /// A package that is on, read through the same call the row makes: the amber names are the
    /// channels the library cannot fill, and the badge is their number.
    func testAPackageThatIsOnMarksTheChannelsTheLibraryCannotFill() throws {
        let scope = HarnessScope.begin("package-channels-on")
        defer { scope.end() }
        let config = ChannelConfigLoader.loadBundled()
        let definition = try XCTUnwrap(config.bundles.first { $0.id == "nostalgex" })
        XCTAssertGreaterThanOrEqual(definition.channelIDs.count, 15)
        let state = AppState()
        state.channelConfigChannels = config.channels
        // The library can fill every channel of the package except the 4th, the 9th and the last.
        let short = Set([definition.channelIDs[3], definition.channelIDs[8], definition.channelIDs[definition.channelIDs.count - 1]])
        state.allChannels = definition.channelIDs.filter { !short.contains($0) }.compactMap { id in
            config.channels.first { $0.id == id }
        }
        let bundle = definition.toChannelBundle(enabled: true)
        let listing = PackageChannelListing(
            availability: state.bundleChannelAvailability(for: bundle), enabled: true, building: false
        )
        XCTAssertEqual(Set(listing.shortChannels.map(\.id)), short)
        XCTAssertEqual(listing.badge, 3)
        XCTAssertEqual(listing.entries.map(\.id), definition.channelIDs, "package order, short or not")
    }

    // MARK: What is drawn

    func testOnlyTheShortChannelsAreDrawnAmber() {
        let listing = PackageChannelListing(
            availability: [(1, "ONE", true), (2, "TWO TWO", false), (3, "THREE", true), (4, "FOUR", false)],
            enabled: true, building: false
        )
        let amber = Color(hex: "#FFB020")
        let drawnAmber = listing.entries.filter { PackageChannelNames.nameColor(isShort: $0.isShort, isOn: true) == amber }.map(\.name)
        XCTAssertEqual(drawnAmber, ["TWO TWO", "FOUR"], "exactly the channels the badge counts")
        XCTAssertEqual(drawnAmber, listing.shortChannels.map(\.name))
        XCTAssertNotEqual(PackageChannelNames.nameColor(isShort: false, isOn: true), amber)
        XCTAssertNotEqual(PackageChannelNames.nameColor(isShort: false, isOn: false), amber)
    }

    func testAnOffPackageReadsDimmerThanAnOnPackage() {
        XCTAssertNotEqual(PackageChannelNames.nameColor(isShort: false, isOn: true),
                          PackageChannelNames.nameColor(isShort: false, isOn: false))
    }

    // MARK: Line breaks: a dot only between two names on one line

    private func lines(_ widths: [CGFloat], max: CGFloat, separator: CGFloat = 10, gap: CGFloat = 9) -> [[Int]] {
        PackageNameFlow.lines(nameWidths: widths, separatorWidth: separator, gap: gap, maxWidth: max)
    }

    func testNamesThatAllFitAreOneLine() {
        XCTAssertEqual(lines([50, 60, 70], max: 1000), [[0, 1, 2]])
    }

    func testANameThatDoesNotFitStartsTheNextLine() {
        // A dot and its two gaps cost 28. 50 + 28 + 60 = 138 fits in 140; the 70 wide name would make it 236.
        XCTAssertEqual(lines([50, 60, 70, 30], max: 140), [[0, 1], [2, 3]], "greedy, in order: 70 + 28 + 30 = 128 fits")
        XCTAssertEqual(lines([50, 60, 70, 30], max: 240), [[0, 1, 2], [3]])
        XCTAssertEqual(lines([50, 60, 70, 30], max: 100), [[0], [1], [2], [3]], "nothing fits beside the name before it")
    }

    func testEveryNameIsOnExactlyOneLineInOrderAndNoLineIsEmpty() {
        let widths: [CGFloat] = (0..<22).map { CGFloat(40 + ($0 * 37) % 120) }
        for max in stride(from: CGFloat(60), through: 900, by: 45) {
            let result = lines(widths, max: max)
            XCTAssertEqual(result.flatMap { $0 }, Array(widths.indices), "max \(max): every name once, in order")
            XCTAssertTrue(result.allSatisfy { !$0.isEmpty }, "max \(max): no empty line")
        }
    }

    /// The dots drawn are the ones between two names on one line, so with n names on k lines there are
    /// n - k of them, and no line can start or end with one.
    func testTheDotsDrawnAreTheOnesBetweenNamesOnTheSameLine() {
        let widths: [CGFloat] = (0..<22).map { CGFloat(40 + ($0 * 37) % 120) }
        for max in stride(from: CGFloat(60), through: 900, by: 45) {
            let result = lines(widths, max: max)
            let dots = result.reduce(0) { $0 + $1.count - 1 }
            XCTAssertEqual(dots, widths.count - result.count, "max \(max)")
        }
    }

    func testALineIsNeverWiderThanTheWidthUnlessOneNameIsAlone() {
        let widths: [CGFloat] = [120, 90, 150, 60, 200, 80]
        let result = lines(widths, max: 300)
        for line in result {
            let width = line.map { widths[$0] }.reduce(0, +) + CGFloat(line.count - 1) * 28
            XCTAssertTrue(width <= 300 || line.count == 1, "\(line): \(width)")
        }
        XCTAssertEqual(lines([500], max: 300), [[0]], "a name wider than the row has its own line")
    }

    func testNoNamesIsNoLines() {
        XCTAssertEqual(lines([], max: 300), [])
    }

    // MARK: What VoiceOver hears

    func testTheCountReadsTitlesAndMatchesTheBadge() {
        let one = PackageChannelListing(availability: availability([true, true, false]), enabled: true, building: false)
        XCTAssertEqual(one.badgeLabel, "1 channel has not enough titles yet")
        let three = PackageChannelListing(availability: availability([true, false, false, false]), enabled: true, building: false)
        XCTAssertEqual(three.badgeLabel, "3 channels have not enough titles yet")
        let none = PackageChannelListing(availability: availability([true, true]), enabled: true, building: false)
        XCTAssertNil(none.badgeLabel)
        XCTAssertNil(PackageChannelListing(availability: availability([true, false]), enabled: false, building: false).badgeLabel)
    }

    func testTheHintListsTheNamesAndNamesTheShortOnes() {
        let listing = PackageChannelListing(
            availability: [(1, "ONE", true), (2, "TWO", false), (3, "THREE", true), (4, "FOUR", false)],
            enabled: true, building: false
        )
        XCTAssertEqual(listing.spokenChannels, "Channels: ONE, TWO, THREE, FOUR. Not enough titles yet: TWO, FOUR.")
    }

    func testTheHintHasNoShortChannelsToNameWhenNoneIsShort() {
        let off = PackageChannelListing(availability: [(1, "ONE", true), (2, "TWO", false)], enabled: false, building: false)
        XCTAssertEqual(off.spokenChannels, "Channels: ONE, TWO.")
    }

    /// A package with no resolvable names has no hint at all, never "Channels: ".
    func testAPackageWithNoNamesHasNoHint() {
        for enabled in [false, true] {
            XCTAssertNil(PackageChannelListing(availability: [], enabled: enabled, building: false).spokenChannels)
        }
    }
}
