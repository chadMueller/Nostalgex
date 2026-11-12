import UIKit

/// Whether the press the focus engine just handled was a move it could not make, because there was nothing further
/// in that direction.
///
/// "Close when there is nothing further to move to" is the focus engine's own answer, so this asks it. An
/// `onMoveCommand` handler cannot work it out from a `FocusState`: the handler runs after the engine has moved
/// focus, and the state it reads lags that move unevenly, so on 2026-11-10 Up from the second row (which had moved
/// focus to the first row) read as "pressed Up on the first row" and closed the Now Playing panel. The engine posts
/// `movementDidFailNotification` first, then SwiftUI calls the handler, in the same turn.
enum FocusMoveFailureMonitor {
    private static var last: (heading: UIFocusHeading, at: Date)?
    private static var observer: NSObjectProtocol?

    /// How long after the failed move the handler may still ask. They land in the same run loop turn; this is slack.
    static let window: TimeInterval = 0.25

    /// Starts listening. Safe to call more than once.
    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.movementDidFailNotification, object: nil, queue: .main
        ) { note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            record(heading: context?.focusHeading ?? [])
        }
    }

    static func record(heading: UIFocusHeading, at date: Date = Date()) {
        last = (heading, date)
    }

    static func forget() { last = nil }

    /// True when the focus engine just failed to move in `heading`.
    static func didFail(_ heading: UIFocusHeading, now: Date = Date()) -> Bool {
        guard let last, last.heading.contains(heading) else { return false }
        return now.timeIntervalSince(last.at) <= window
    }
}
