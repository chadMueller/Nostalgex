import UIKit

// The app plays no tvOS focus tick (Chad, 2026-11-10): moving focus along the channel strip ticked on every step
// over the playing video's audio.
//
// UIKit asks the focus environment chain what sound a focus update should make:
//   UIFocusEnvironment.soundIdentifierForFocusUpdate(in:)   // Obj-C: soundIdentifierForFocusUpdateInContext:
//   returning UIFocusSoundIdentifier.none to opt out, .default for the system sound, nil to defer to the parent.
// SwiftUI has no modifier for it on tvOS and the app has no UIKit root of its own (it is a SwiftUI `App` with a
// `WindowGroup`), so the answer is given where every chain ends: the window, and every view controller that does not
// answer for itself. A view or controller that returns a sound of its own still wins, because it is asked first.
//
// This silences only the focus sounds. Playback audio, the channel-change static and the system sound settings are
// not touched. The simulator plays no focus sounds, so this is checked by ear on a TV.

private let silentFocusSound: UIFocusSoundIdentifier? = UIFocusSoundIdentifier.none

extension UIWindow {
    public override func soundIdentifierForFocusUpdate(in context: UIFocusUpdateContext) -> UIFocusSoundIdentifier? { silentFocusSound }
}

extension UIViewController {
    @objc func soundIdentifierForFocusUpdate(in context: UIFocusUpdateContext) -> UIFocusSoundIdentifier? { silentFocusSound }
}
