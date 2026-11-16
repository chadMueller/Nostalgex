import XCTest
import SwiftUI
@testable import Nostalgex

/// CH 299 in the guide (I-016): in the lineup only beside library channels, numbered between the packages and
/// the franchise block, and a guide row that is one always-live bar.
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

    /// Chad, 2026-11-16: one full-width bar, no scheduled sections. One entry, always on now, past both ends of the
    /// guide's 22-hour window at every time position; no UP NEXT; the info panel shows no progress bar for it.
    func testTheGuideRowIsOneAlwaysLiveBar() throws {
        let now = Date(timeIntervalSince1970: 1_794_765_600 + 1234)
        let s = WeatherChannel.schedule(at: now)
        XCTAssertEqual(s.entries.count, 1)
        let live = try XCTUnwrap(s.nowPlaying)
        XCTAssertTrue(live.isNowPlaying)
        XCTAssertNil(s.upNext, "the loop has no UP NEXT")
        let windowStart = ChannelScheduleBuilder.windowStart(at: now)
        for halfHours in 0...44 {
            let t = windowStart.addingTimeInterval(Double(halfHours) * 1800)
            XCTAssertTrue(live.startTime <= windowStart && t < live.endTime, "the bar ends before slot \(halfHours)")
            XCTAssertEqual(GuideProgramCursor.current(in: s.entries, cursor: t, now: now)?.id, live.id)
            XCTAssertNil(GuideProgramCursor.next(in: s.entries, cursor: t, now: now), "the cursor stepped to a block")
        }
        XCTAssertTrue(s.isCurrent(at: now))
        XCTAssertTrue(live.item.title.hasPrefix("LOCAL WEATHER"))
        XCTAssertTrue(live.item.isWeatherLoop, "the info panel draws LIVE and a full bar for it")
        XCTAssertFalse(InfoPanelLayout.sections(for: live.item, hasUpNext: false).contains(.upNext))
        // The schedule builder hands CH 299 this row, never a manifest.
        let built = ChannelScheduleBuilder.buildSchedule(for: WeatherChannel.make(), at: now, credentialFingerprint: "x")
        XCTAssertEqual(built?.entries.count, 1)
        XCTAssertEqual(built?.nowPlaying?.id, live.id)
    }
}
