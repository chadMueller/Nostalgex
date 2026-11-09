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
