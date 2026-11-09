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

    /// A long package, the shape that makes the row tall: NOSTALGEX lists 15 or more names.
    func testALongPackageListsEveryName() throws {
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

    private func plain(_ text: AttributedString) -> String {
        String(text.characters).replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testTheDrawnTextIsTheNamesAndNoChannelNumbers() {
        let listing = PackageChannelListing(
            availability: [(901, "FAMILY HOUR", true), (902, "DIZ FLICKS", true), (903, "TOON TOWN", false)],
            enabled: true, building: false
        )
        let text = PackageChannelNames.attributed(listing: listing, isOn: true)
        XCTAssertEqual(plain(text), "FAMILY HOUR · DIZ FLICKS · TOON TOWN", "names joined by dots, nothing else")
        XCTAssertFalse(plain(text).contains("901"), "no id")
        XCTAssertFalse(plain(text).contains(where: \.isNumber), "no channel numbers")
    }

    func testANameIsNeverBrokenAcrossLinesAndADotStaysWithItsName() {
        let listing = PackageChannelListing(
            availability: [(1, "FAMILY HOUR", true), (2, "DIZ FLICKS", true)], enabled: false, building: false
        )
        let raw = String(PackageChannelNames.attributed(listing: listing, isOn: false).characters)
        XCTAssertTrue(raw.contains("FAMILY\u{00A0}HOUR\u{00A0}·"), "the spaces inside a name and before its dot do not break")
        XCTAssertTrue(raw.contains("· DIZ\u{00A0}FLICKS"), "a line can end only after a dot")
    }

    func testOnlyTheShortChannelsAreDrawnAmber() {
        let listing = PackageChannelListing(
            availability: [(1, "ONE", true), (2, "TWO TWO", false), (3, "THREE", true), (4, "FOUR", false)],
            enabled: true, building: false
        )
        let text = PackageChannelNames.attributed(listing: listing, isOn: true)
        let amber = Color(hex: "#FFB020")
        var amberRuns: [String] = []
        for run in text.runs where run.foregroundColor == amber {
            amberRuns.append(plain(AttributedString(text[run.range])))
        }
        XCTAssertEqual(amberRuns, ["TWO TWO", "FOUR"], "exactly the channels the badge counts")
    }

    func testAnOffPackageReadsDimmerThanAnOnPackage() {
        let listing = PackageChannelListing(availability: [(1, "ONE", true)], enabled: true, building: false)
        let on = PackageChannelNames.attributed(listing: listing, isOn: true)
        let off = PackageChannelNames.attributed(listing: listing, isOn: false)
        XCTAssertNotEqual(on.runs.first?.foregroundColor, off.runs.first?.foregroundColor)
    }

    func testTheSpokenListIsTheNamesInOrder() {
        let listing = PackageChannelListing(availability: [(1, "ONE", true), (2, "TWO", false)], enabled: true, building: false)
        XCTAssertEqual(PackageChannelNames.spokenNames(listing), "Channels: ONE, TWO")
    }
}
