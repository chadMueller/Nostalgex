import Foundation

/// The guide's time cursor (I-089): Right and Left move the guide's window through time, 30 minutes at a time, with
/// focus staying on the row. The info panel follows the window: moved later than now, it shows the focused
/// channel's programme at the window's left edge (the one that is about to start there), not what is on now.
enum GuideTimeCursor {
    static let slotSeconds: TimeInterval = 1800

    /// The time the panel previews, or nil for the live programme (the window is at its start, or the cursor
    /// is not later than now).
    static func previewTime(slotOffset: Int, windowStart: Date, now: Date = Date()) -> Date? {
        guard slotOffset > 0 else { return nil }
        let time = windowStart.addingTimeInterval(TimeInterval(slotOffset) * slotSeconds)
        return time > now ? time : nil
    }

    /// The programme on `entries` that covers `time`. Nil when none does (a gap), and the panel then shows
    /// what is on now, as it always did.
    static func entry(in entries: [ScheduleEntry], at time: Date) -> ScheduleEntry? {
        entries.first { $0.startTime <= time && time < $0.endTime }
    }

    /// The programme that follows `entry` on the schedule.
    static func entry(after entry: ScheduleEntry, in entries: [ScheduleEntry]) -> ScheduleEntry? {
        entries.filter { $0.startTime >= entry.endTime }.min { $0.startTime < $1.startTime }
    }
}
