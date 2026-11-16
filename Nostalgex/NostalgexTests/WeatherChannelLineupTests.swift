import XCTest
import SwiftUI
@testable import Nostalgex

/// CH 299 in the guide (I-016): in the lineup only beside library channels, numbered between the packages and
/// the franchise block, and a guide row of hour blocks with one live.
final class WeatherChannelLineupTests: XCTestCase {
    private func channel(_ id: Int, _ number: Int) -> Channel {
        Channel(id: id, number: number, name: "CH \(number)", color: .red, category: nil, rules: nil, timeRestrictions: nil, minItems: 0)
    }

    func testItJoinsOnlyBesideLibraryChannels() {
        XCTAssertTrue(WeatherChannel.lineup([], on: true).isEmpty, "an empty library must still read as empty")
        let lineup = WeatherChannel.lineup([channel(1, 1), channel(100, 300)], on: true)
        XCTAssertEqual(lineup.filter(\.isWeather).count, 1)
        let sorted = GuideChannelOrder.sorted(lineup, seasonalFirst: [])
        XCTAssertEqual(sorted.map(\.number), [1, 299, 300])
        XCTAssertFalse(WeatherChannel.lineup(lineup, on: false).contains(where: \.isWeather))
        XCTAssertEqual(WeatherChannel.lineup(lineup, on: true).filter(\.isWeather).count, 1, "never twice")
    }

    func testItsIdIsInADynamicBlockNothingElseUses() {
        XCTAssertTrue(ChannelIDSpace.isDynamic(WeatherEngine.channelID))
        for block in DynamicChannelBlock.allCases {
            XCTAssertFalse((block.idBase..<(block.idBase + ChannelIDSpace.categoryStride)).contains(WeatherEngine.channelID))
            XCTAssertFalse((block.displayNumberBase...block.displayNumberEnd).contains(WeatherEngine.channelNumber))
        }
    }

    func testTheGuideRowHasOneLiveHourBlock() throws {
        let now = Date(timeIntervalSince1970: 1_794_765_600 + 1234)
        let s = WeatherChannel.schedule(at: now)
        XCTAssertEqual(s.entries.count, 26)
        XCTAssertEqual(s.entries.filter(\.isNowPlaying).count, 1)
        let live = try XCTUnwrap(s.nowPlaying)
        XCTAssertTrue(live.startTime <= now && now < live.endTime)
        XCTAssertEqual(live.durationSeconds, 3600)
        XCTAssertEqual(s.elapsedSeconds, 1234)
        XCTAssertNil(s.upNext, "the loop has no UP NEXT")
        XCTAssertTrue(s.isCurrent(at: now))
        // The schedule builder hands CH 299 this row, never a manifest.
        let built = ChannelScheduleBuilder.buildSchedule(for: WeatherChannel.make(), at: now, credentialFingerprint: "x")
        XCTAssertEqual(built?.nowPlaying?.startTime, live.startTime)
    }
}
