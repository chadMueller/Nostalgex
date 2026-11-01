import XCTest
@testable import Nostalgex

/// `activeMonths` shipped long ago but no bundle set it, so the seasonal gate had never
/// run in production. SCREAM (October) and TIS THE SEASON (December) are the first users
/// of it, and a bundle that fails to come back in season is invisible for a year.
final class SeasonalBundleTests: XCTestCase {
    private func date(_ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func bundle(_ id: String, months: [Int]?) -> ChannelBundle {
        ChannelBundle(id: id, name: id, description: nil, channelIDs: [1], activeMonths: months)
    }

    func testOctoberOnlyBundleIsVisibleOnlyInOctober() {
        let scream = bundle("scream", months: [10])
        XCTAssertTrue(scream.isInSeason(on: date(10, 1)))
        XCTAssertTrue(scream.isInSeason(on: date(10, 31)))
        XCTAssertFalse(scream.isInSeason(on: date(9, 30)))
        XCTAssertFalse(scream.isInSeason(on: date(11, 1)))
        XCTAssertFalse(scream.isInSeason(on: date(7, 4)))
    }

    func testDecemberOnlyBundleIsVisibleOnlyInDecember() {
        let holiday = bundle("tis-the-season", months: [12])
        XCTAssertTrue(holiday.isInSeason(on: date(12, 1)))
        XCTAssertTrue(holiday.isInSeason(on: date(12, 25)))
        XCTAssertFalse(holiday.isInSeason(on: date(11, 28)))
        XCTAssertFalse(holiday.isInSeason(on: date(1, 2)))
    }

    func testSeptemberIsGatedToTheSecondHalf() {
        let b = bundle("scream", months: [9, 10])
        XCTAssertFalse(b.isInSeason(on: date(9, 14)))
        XCTAssertTrue(b.isInSeason(on: date(9, 15)))
    }

    func testBundleWithoutActiveMonthsIsAlwaysVisible() {
        let b = bundle("nostalgex", months: nil)
        for m in 1...12 { XCTAssertTrue(b.isInSeason(on: date(m, 15)), "month \(m)") }
    }

    /// The shipped config must actually carry the months, or the split is cosmetic.
    func testShippedConfigGatesScreamAndHolidayBundles() throws {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        let result = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
        let scream = try XCTUnwrap(result.bundles.first { $0.name == "SCREAM" })
        let holiday = try XCTUnwrap(result.bundles.first { $0.id == "tis-the-season" })
        XCTAssertEqual(scream.activeMonths, [10])
        XCTAssertEqual(holiday.activeMonths, [12])
        XCTAssertTrue(scream.toChannelBundle().isInSeason(on: date(10, 20)))
        XCTAssertFalse(holiday.toChannelBundle().isInSeason(on: date(10, 20)))
    }

    /// TIS THE SEASON comes into season a week before US Thanksgiving, so TURKEY DAY is
    /// offered while it is in season; SCREAM keeps plain October. 2026: Thanksgiving is
    /// Nov 26, so the invite starts Nov 19 and runs to Dec 31.
    func testShippedHolidaySeasonStartsAWeekBeforeThanksgiving() throws {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        let result = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
        let holiday = try XCTUnwrap(result.bundles.first { $0.id == "tis-the-season" }).toChannelBundle()
        let scream = try XCTUnwrap(result.bundles.first { $0.id == "seasonal" }).toChannelBundle()
        XCTAssertEqual(holiday.seasonStart, SeasonStart(relativeTo: "usThanksgiving", days: -7))
        XCTAssertNil(scream.seasonStart)
        let late = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 23, minute: 59))!
        XCTAssertFalse(holiday.isInSeason(on: late))
        XCTAssertTrue(holiday.isInSeason(on: date(11, 19)))
        XCTAssertTrue(holiday.isInSeason(on: date(12, 31)))
        XCTAssertFalse(holiday.isInSeason(on: Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 1))!))
        XCTAssertFalse(scream.isInSeason(on: date(11, 19)))
    }

    /// The early start covers the days from `seasonStart` to the end of its month, so it
    /// has to land in the month just before the first active month, or the season has a
    /// gap or starts nothing. Checked for every year the shipped config will meet.
    func testEveryShippedSeasonStartLeadsStraightIntoItsMonths() throws {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        let result = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
        let cal = ChannelBundle.seasonCalendar
        let early = result.bundles.map { $0.toChannelBundle() }.filter { $0.seasonStart != nil }
        XCTAssertEqual(early.map(\.id), ["tis-the-season"])
        for bundle in early {
            let months = try XCTUnwrap(bundle.activeMonths)
            XCTAssertEqual(months, months.sorted(), "\(bundle.id): one season per calendar year keeps NOT THIS YEAR right")
            for year in 2024...2040 {
                let june = cal.date(from: DateComponents(year: year, month: 6, day: 1))!
                let start = try XCTUnwrap(bundle.seasonStartDate(inYearOf: june, calendar: cal), "\(bundle.id) \(year)")
                let month = cal.component(.month, from: start)
                XCTAssertFalse(months.contains(month), "\(bundle.id) \(year): starts inside an active month")
                XCTAssertEqual(months.first, month % 12 + 1, "\(bundle.id) \(year): a gap before the first active month")
            }
        }
    }

    /// The library snapshot restores bundles from its own copy of the definitions, so the
    /// early start has to survive a save, and a snapshot written before it existed has to
    /// still decode (as no early start, until the next scan).
    func testSeasonStartSurvivesTheSnapshot() throws {
        let holiday = ChannelBundle(id: "tis-the-season", name: "TIS THE SEASON", description: nil, channelIDs: [130],
                                    activeMonths: [12], seasonStart: SeasonStart(relativeTo: "usThanksgiving", days: -7))
        let payload = LibrarySnapshotStore.makePayload(
            identity: "test", serverName: "Test", librarySignature: nil, lastLoadAtUnix: 0, allItems: [],
            channelConfigChannels: [], allChannels: [], bundles: [holiday], enabledBundleIDs: [],
            exclusiveRules: [], discoveredCollections: [])
        let data = try JSONEncoder().encode(payload.bundleDefinitions)
        let decoded = try JSONDecoder().decode([ChannelBundleDefinition].self, from: data)
        XCTAssertEqual(decoded.first?.seasonStart, holiday.seasonStart)
        XCTAssertTrue(try XCTUnwrap(decoded.first).toChannelBundle().isInSeason(on: date(11, 20)))

        let old = #"[{"id":"tis-the-season","name":"TIS THE SEASON","channelIDs":[130],"activeMonths":[12]}]"#
        let legacy = try JSONDecoder().decode([ChannelBundleDefinition].self, from: Data(old.utf8))
        XCTAssertNil(legacy.first?.seasonStart)
        XCTAssertFalse(try XCTUnwrap(legacy.first).toChannelBundle().isInSeason(on: date(11, 20)))
    }

    /// SCREAM's channels in guide order (the October lead block follows bundle order),
    /// and the Scream/Halloween lock shared by SCREAM ADULTS and SLASHER.
    func testShippedScreamLineupAndLock() throws {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        let result = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
        let scream = try XCTUnwrap(result.bundles.first { $0.id == "seasonal" })
        XCTAssertEqual(scream.channelIDs, [131, 141, 132, 408, 415, 416, 417, 418])
        let numbers = Dictionary(uniqueKeysWithValues: result.channels.map { ($0.id, $0.number) })
        XCTAssertEqual(scream.channelIDs.compactMap { numbers[$0] }, Array(180...187))
        let lock = try XCTUnwrap(result.exclusiveRules.first { $0.channelIDs.contains(132) })
        XCTAssertEqual(lock.channelIDs, [132, 415])
        XCTAssertTrue(lock.titleContains.isEmpty, "the SCREAM lock is an exact title list")
        XCTAssertTrue(lock.editorialTitles.contains("Halloween H20: 20 Years Later"))
    }

    /// TIS THE SEASON in guide order (the December lead block follows bundle order),
    /// and the holiday lock: films in a movie library only, owned by every holiday
    /// channel that can air a film, including the two TV channels that air specials.
    func testShippedHolidayLineupAndLock() throws {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        let result = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
        let holiday = try XCTUnwrap(result.bundles.first { $0.id == "tis-the-season" })
        XCTAssertEqual(holiday.channelIDs, [130, 409, 410, 411, 412, 413, 414, 422])
        let byID = Dictionary(uniqueKeysWithValues: result.channels.map { ($0.id, $0) })
        XCTAssertEqual(holiday.channelIDs.compactMap { byID[$0]?.number }, Array(190...197))
        XCTAssertEqual(byID[412]?.name, "MISTLETOE")
        XCTAssertEqual(byID[422]?.name, "TURKEY DAY")
        XCTAssertEqual(byID[412]?.rules?.matchTmdbGenres, true)
        XCTAssertEqual(byID[413]?.rules?.episodeAirWindow?.from, "11-25")

        let lock = try XCTUnwrap(result.exclusiveRules.first { $0.channelIDs.contains(130) })
        XCTAssertEqual(lock.channelIDs, [130, 409, 410, 411, 412, 413, 414])
        XCTAssertEqual(lock.type, .movie)
        XCTAssertEqual(lock.source, .movie)
        for word in ["Holiday", "Santa", "Merry", "Snowman", "Reindeer"] {
            XCTAssertFalse(lock.titleContains.contains(word), "\(word) measured under 95% Christmas")
        }
        XCTAssertFalse(lock.editorialTitles.contains("Rocky IV"))
    }

    /// The episode air window, including one that wraps the new year.
    func testAirWindow() {
        let xmas = AirWindow(from: "11-25", to: "01-07")
        XCTAssertTrue(xmas.contains(date: "2000-12-14"))
        XCTAssertTrue(xmas.contains(date: "1993-11-29"))
        XCTAssertTrue(xmas.contains(date: "2017-01-05"))
        XCTAssertTrue(xmas.contains(date: "2017-01-07T00:00:00Z"))
        XCTAssertFalse(xmas.contains(date: "2017-01-08"))
        XCTAssertFalse(xmas.contains(date: "1988-11-11"))
        XCTAssertFalse(xmas.contains(date: "2024-09-12"))
        XCTAssertFalse(xmas.contains(date: nil))
        XCTAssertFalse(xmas.contains(date: "December 14"))
        let november = AirWindow(from: "11-01", to: "11-30")
        XCTAssertTrue(november.contains(date: "1998-11-19"))
        XCTAssertFalse(november.contains(date: "2015-02-17"))
        XCTAssertFalse(AirWindow(from: nil, to: "11-30").contains(date: "1998-11-19"))
    }
}
