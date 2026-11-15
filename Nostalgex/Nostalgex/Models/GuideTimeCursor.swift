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

/// The guide's programme cursor (Chad 2026-11-15: "it should jump to the next title not the next 30 minutes and we
/// should have a highlight or some way of seeing where the cursor is at"). Focus stays on the row; the cursor is a
/// time on it, and the programme the cursor is on is the one covering that time.
///
/// - Right: the next programme on the row, whatever its length, over a gap too.
/// - Left: the previous programme, as long as it has not ended; from the programme on now there is none, and the guide
///   goes to the bundle stripe as before.
/// - Up and Down: the row changes and the time stays, so the cursor is on the programme of the new row at that time.
/// - The window scrolls in time only when the programme the cursor moves to would leave the view.
/// - Nil is the live programme: where the guide comes back to on the playing channel.
///
/// Mirrors GuideCursor in the Android engine; Roku and the web tuner follow these rules.
enum GuideProgramCursor {
    /// The time the cursor stands at: its own, or now when it is on the live programme or has fallen behind now.
    static func time(_ cursor: Date?, now: Date) -> Date { max(cursor ?? now, now) }

    /// The programme the cursor is on: the one covering its time. Nil in a gap.
    static func current(in entries: [ScheduleEntry], cursor: Date?, now: Date) -> ScheduleEntry? {
        GuideTimeCursor.entry(in: entries, at: time(cursor, now: now))
    }

    /// Right: the programme after the cursor's, or the first to start after its time when it is in a gap.
    static func next(in entries: [ScheduleEntry], cursor: Date?, now: Date) -> ScheduleEntry? {
        if let current = current(in: entries, cursor: cursor, now: now) {
            return GuideTimeCursor.entry(after: current, in: entries)
        }
        let t = time(cursor, now: now)
        return entries.filter { $0.startTime > t }.min { $0.startTime < $1.startTime }
    }

    /// Left: the programme before the cursor's that has not ended yet. Nil from the programme on now.
    static func previous(in entries: [ScheduleEntry], cursor: Date?, now: Date) -> ScheduleEntry? {
        let anchor = current(in: entries, cursor: cursor, now: now)?.startTime ?? time(cursor, now: now)
        return entries.filter { $0.endTime <= anchor && $0.endTime > now }.max { $0.startTime < $1.startTime }
    }

    /// The cursor for a programme: its start, or nil (live) when it is on now.
    static func cursor(for entry: ScheduleEntry, now: Date) -> Date? {
        entry.startTime <= now ? nil : entry.startTime
    }

    /// The window's offset, in `slot` steps from `windowStart`, that shows `entry`: the offset it has while the
    /// programme starts inside the view with at least half a slot of it showing; otherwise the slot its start is in
    /// (for the live programme, the slot now is in).
    static func windowOffset(showing entry: ScheduleEntry, offset: Int, windowStart: Date, now: Date, maxOffset: Int,
                             visible: TimeInterval = 7200, slot: TimeInterval = GuideTimeCursor.slotSeconds) -> Int {
        let start = max(entry.startTime, now)
        let viewStart = windowStart.addingTimeInterval(TimeInterval(offset) * slot)
        let viewEnd = viewStart.addingTimeInterval(visible)
        if start >= viewStart && start < viewEnd.addingTimeInterval(-slot / 2) { return offset }
        let wanted = Int((start.timeIntervalSince(windowStart) / slot).rounded(.down))
        return min(max(0, wanted), maxOffset)
    }
}
