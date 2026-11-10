import UIKit

/// When the viewer last touched the remote, for GUIDE TIMEOUT.
///
/// SwiftUI on tvOS has no one place every press passes through, so this watches the window
/// itself: a gesture recognizer that sees every press and touch-surface swipe, notes the time,
/// and never recognizes, so it never takes a press away from the focus engine or a view.
enum RemoteActivityMonitor {
    private(set) static var lastActivity = Date()

    /// Restarts the clock, e.g. when the guide comes back from fullscreen or Settings.
    static func noteActivity() { lastActivity = Date() }

    /// Adds the watcher to the app's key window once. Safe to call on every appearance.
    static func install() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is Watcher }) {
            window.addGestureRecognizer(Watcher())
        }
    }

    private final class Watcher: UIGestureRecognizer {
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            allowedPressTypes = [
                UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow,
                .select, .menu, .playPause, .pageUp, .pageDown,
            ].map { NSNumber(value: $0.rawValue) }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            RemoteActivityMonitor.noteActivity()
            state = .failed
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            RemoteActivityMonitor.noteActivity()
            state = .failed
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            RemoteActivityMonitor.noteActivity()
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
