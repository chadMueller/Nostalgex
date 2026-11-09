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
}
