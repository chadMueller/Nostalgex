import Foundation

/// Where the guide's focus goes when tvOS hands it back after full screen (I-041).
///
/// Leaving full screen asks for the focus ring on the live channel, but at that moment nothing in
/// the guide has focus, and a focus request made while nothing is focused does not stick: tvOS
/// hands focus back a moment later, to the row it remembers, which is the one the viewer left
/// from, not the channel they have since changed to. So the guide waits for that handout (focus
/// arriving from none) and, once, moves it to the live channel.
enum GuideReturnFocus {
    /// The channel to move focus to when tvOS has just handed it to `handedTo`, or nil to leave
    /// it there (it already is the live channel, or there is no live channel).
    static func target(handedTo: Int?, liveChannelID: Int?) -> Int? {
        guard let handedTo, let liveChannelID, handedTo != liveChannelID else { return nil }
        return liveChannelID
    }

    /// The playing channel, if the guide has a row for it. Asking for focus on a row that is not there
    /// moves nothing, so with no row there is nothing to anchor to and the handout is left alone (the
    /// ordinary path then runs, and the info panel follows the row focus really is on).
    static func liveRowID(liveChannelID: Int?, hasRow: (Int) -> Bool) -> Int? {
        guard let liveChannelID, hasRow(liveChannelID) else { return nil }
        return liveChannelID
    }

    /// The row the guide draws highlighted. While it is coming back (`LiveHighlightHold`) that is the
    /// live channel's row, whatever row tvOS has put focus on for the moment: the viewer must not see the
    /// highlight on the row they left from, and then move. Otherwise it is the row that has focus.
    static func highlighted(focused: Int?, holdingLive: Bool, liveRow: Int?) -> Int? {
        guard holdingLive, let liveRow else { return focused }
        return liveRow
    }

    /// Whether the hold carries on after a focus change. It does only through the handout of the wrong
    /// row, which the guide is about to correct. Every other change ends it: focus is on the live
    /// channel, or the viewer moved it, and the highlight follows the focus again.
    static func holdSurvives(isHandout: Bool, handedTo: Int?, liveRow: Int?) -> Bool {
        isHandout && target(handedTo: handedTo, liveChannelID: liveRow) != nil
    }

    /// How long the guide draws the live row highlighted at most, from the moment it comes back. It has
    /// to outlast the cover closing: tvOS hands focus back when full screen has finished going away, about
    /// 0.5 s after it was asked to close on a simulator, and the guide is on screen all that time. The
    /// same 2 seconds as the handout window, and the hard limit: nothing keeps the highlight on a row
    /// longer.
    static let holdTimeout: TimeInterval = 2

    /// How long the hold carries on once the wrong row has been handed out: the time the move to the
    /// live row has to land. If it has not by then (the engine ignored it), the highlight goes back to the
    /// row that really has focus, so the viewer never presses Select on a row that is not the one shown.
    static let correctionTimeout: TimeInterval = 0.3

    /// The hold on the live row's highlight. Each opening has its own generation, like `HandoutWindow`,
    /// so the timer of an earlier opening cannot end a later one.
    struct LiveHighlightHold: Equatable {
        private(set) var generation = 0
        private(set) var isActive = false

        /// Starts a hold. The returned generation goes with the timer that will end it.
        mutating func begin() -> Int {
            generation += 1
            isActive = true
            return generation
        }

        /// Focus is where it belongs, or the viewer moved it: the highlight follows focus again.
        mutating func end() {
            generation += 1
            isActive = false
        }

        /// A timer ran out. Ends the hold only if it is still the one that timer belongs to.
        mutating func expire(generation timerGeneration: Int) {
            if timerGeneration == generation { isActive = false }
        }
    }

    /// The window in which the guide waits for the handout. Closing full screen, or the guide first
    /// appearing, opens it; the handout, or a timer, closes it. Each opening has its own generation,
    /// so the timer of an earlier opening (a close of full screen two seconds ago) cannot close a
    /// later one.
    struct HandoutWindow: Equatable {
        private(set) var generation = 0
        private(set) var isOpen = false

        /// Opens the window. The returned generation goes with the timer that will close it.
        mutating func open() -> Int {
            generation += 1
            isOpen = true
            return generation
        }

        /// The handout arrived: closes the window, and makes any timer still running stale.
        mutating func close() {
            generation += 1
            isOpen = false
        }

        /// A timer ran out. Closes the window only if it is still the opening that timer belongs to.
        mutating func expire(generation timerGeneration: Int) {
            if timerGeneration == generation { isOpen = false }
        }
    }
}
