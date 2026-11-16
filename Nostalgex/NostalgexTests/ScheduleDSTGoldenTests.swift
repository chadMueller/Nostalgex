import XCTest
@testable import Nostalgex

/// Shared golden vectors for the schedule on the days the clocks change.
///
/// `scripts/schedule-dst-golden.json` is read by this test AND by the web tuner's node test
/// (`npm run test:schedule-dst`, scripts/nostalgex-schedule-dst-smoke.mjs), which also checks
/// its midnights against the IANA rules and runs a negative control with the old arithmetic.
/// Each case runs in its own zone through an injected calendar, the same zone rules the app
/// gets from `Calendar.current` on the viewer's Apple TV.
final class ScheduleDSTGoldenTests: XCTestCase {

    private struct PoolItem: Decodable {
        let key: String
        let title: String
        let type: String
        let minutes: Int

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            key = try c.decode(String.self)
            title = try c.decode(String.self)
            type = try c.decode(String.self)
            minutes = try c.decode(Int.self)
        }
    }
    private struct Pools: Decodable {
        let small: [PoolItem]
        let big: [PoolItem]
    }
    private struct Day: Decodable {
        let zone: String
        let date: String
        let previous: String
        let start: Int
        let nextStart: Int
        let hours: Double
        let at: [Int]
    }
    private struct Yesterday: Decodable {
        let zone: String
        let date: String
        let previous: String
    }
    private struct Golden: Decodable {
        let pools: Pools
        let days: [Day]
        let yesterday: [Yesterday]
    }

    /// Repo root, found from this source file: NostalgexTests -> Nostalgex -> root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func golden() throws -> Golden {
        try JSONDecoder().decode(
            Golden.self,
            from: Data(contentsOf: Self.repoRoot.appendingPathComponent("scripts/schedule-dst-golden.json")))
    }

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone), zone)
        return calendar
    }

    private func channel(id: Int, _ pool: [PoolItem]) -> Channel {
        let items = pool.map { i in
            PlexMediaItem(
                id: i.key, title: i.title, artist: nil, episodeTitle: nil, seTag: nil, summary: "",
                year: 2000, originallyAvailableAt: nil, contentRating: nil, duration: i.minutes,
                ratingKey: i.key, partKey: nil, container: "mp4", videoCodec: nil, audioCodec: nil,
                videoProfile: nil, bitrate: nil, genres: [], rating: 0, userRating: 0,
                type: i.type == "episode" ? .episode : .movie, thumb: nil, art: nil, viewCount: 0,
                addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
                librarySource: i.type == "episode" ? .tv : .movie)
        }
        return Channel(id: id, number: id, name: "DST \(id)", color: .blue, category: nil, rules: nil,
                       timeRestrictions: nil, minItems: 1, itemPool: items, enabled: true)
    }

    private func at(_ unix: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(unix)) }
    private func unix(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    func testDayStartNextDayAndYesterdayInEveryZone() throws {
        for d in try golden().days {
            let cal = try calendar(d.zone)
            for t in d.at {
                let label = "\(d.zone) \(d.date) at \(t)"
                XCTAssertEqual(DailyManifestStore.localDayKey(for: at(t), calendar: cal), d.date, label)
                XCTAssertEqual(unix(DailyManifestStore.startOfLocalDay(for: at(t), calendar: cal)), d.start, label)
                XCTAssertEqual(unix(DailyManifestStore.startOfNextLocalDay(after: at(t), calendar: cal)), d.nextStart, label)
                XCTAssertEqual(DailyManifestStore.previousLocalDayKey(before: at(t), calendar: cal), d.previous, label)
            }
        }
    }

    /// A 25-hour day has no empty last hour, and a 23-hour day is covered to its end. The last programme plays to its own
    /// end, so it may run past midnight by less than its own length (#315); the programme before it ends before midnight.
    func testAFullDayOfScheduleWithNoHoleAndNoCutAtMidnight() throws {
        let g = try golden()
        let small = channel(id: 201, g.pools.small)
        for d in g.days {
            let cal = try calendar(d.zone)
            let fp = "dst-golden-fill"
            DailyManifestStore.clearAll(credentialFingerprint: fp)
            defer { DailyManifestStore.clearAll(credentialFingerprint: fp) }
            let blocks = DailyManifestScheduler.blocks(for: small, at: at(d.at[2]), credentialFingerprint: fp, calendar: cal)
            let label = "\(d.zone) \(d.date) (\(d.hours) h)"
            XCTAssertEqual(blocks.first.map { unix($0.startTime) }, d.start, label)
            let lastEnd = try XCTUnwrap(blocks.last.map { unix($0.endTime) }, label)
            XCTAssertGreaterThanOrEqual(lastEnd, d.nextStart, "\(label): the day is not covered")
            XCTAssertLessThan(lastEnd - d.nextStart, try XCTUnwrap(blocks.last).item.slotSeconds, "\(label): runs a whole programme past midnight")
            XCTAssertLessThan(unix(try XCTUnwrap(blocks.dropLast().last).endTime), d.nextStart, "\(label): only the last programme runs over")
            XCTAssertTrue(blocks.allSatisfy { $0.durationSeconds == Double($0.item.slotSeconds) }, "\(label): a block is cut short")
            for (a, b) in zip(blocks, blocks.dropFirst()) {
                XCTAssertEqual(a.endTime, b.startTime, "\(label): a hole or an overlap")
            }
        }
    }

    /// The day after the clocks go forward reads the day before it, not two days back.
    func testTheDayAfterAirsNothingYesterdayAired() throws {
        let g = try golden()
        let big = channel(id: 203, g.pools.big)
        for y in g.yesterday {
            let cal = try calendar(y.zone)
            let noon: (String) throws -> Date = { date in
                self.at(try XCTUnwrap(g.days.first { $0.zone == y.zone && $0.date == date }, date).at[2])
            }
            let fp = "dst-golden-yesterday"
            DailyManifestStore.clearAll(credentialFingerprint: fp)
            defer { DailyManifestStore.clearAll(credentialFingerprint: fp) }
            let before = DailyManifestScheduler.blocks(for: big, at: try noon(y.previous), credentialFingerprint: fp, calendar: cal)
            let after = DailyManifestScheduler.blocks(for: big, at: try noon(y.date), credentialFingerprint: fp, calendar: cal)
            let aired = Set(before.map(\.item.ratingKey))
            XCTAssertFalse(before.isEmpty, "\(y.zone) \(y.previous)")
            XCTAssertEqual(after.filter { aired.contains($0.item.ratingKey) }.count, 0, "\(y.zone) \(y.date)")
        }
    }
}
