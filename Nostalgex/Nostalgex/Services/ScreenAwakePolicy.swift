import Foundation

/// Whether the Apple TV may go to sleep right now.
///
/// tvOS has one switch for it, `UIApplication.isIdleTimerDisabled`, and two things in the
/// app want it held: playback, and a load the viewer is sitting in front of on the loading
/// screen (the first load, or a RESCAN LIBRARY). A 15,000-movie first load ran 11 minutes
/// on a TV set to sleep after 15 (N-033); a slower server or a bigger library loses that
/// race and the TV sleeps on the loading screen. `RootView` writes the switch from this one
/// answer, so neither holder can release the other's hold.
///
/// A background refresh behind the guide does not count: the viewer is not waiting on it.
enum ScreenAwakePolicy {
    /// - `playbackState`: `.playing` holds the TV awake, as it always has.
    /// - `isLoading`: a foreground load; a background refresh sets `isBackgroundRefreshing`
    ///   instead and never this.
    /// - `hasCredentials`: the loading screen only shows for a sign-in (`RootView`). A sign-out
    ///   during a load drops this at once, which releases the hold.
    static func keepsAwake(playbackState: PlaybackState, isLoading: Bool, hasCredentials: Bool) -> Bool {
        if playbackState == .playing { return true }
        return isLoading && hasCredentials
    }
}
