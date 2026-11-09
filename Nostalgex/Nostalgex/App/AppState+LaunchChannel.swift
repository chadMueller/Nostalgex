import Foundation

/// OPEN ON LAST CHANNEL (I-017). See `LaunchChannelMemory`.
extension AppState {
    /// The channel a launch tunes first: the last one the viewer tuned when OPEN ON LAST CHANNEL is
    /// on and that channel is still in the lineup under the same name, otherwise the first
    /// channel, as before. Demo mode (what App Review sees) always opens on the first channel.
    var channelToOpenFirst: Channel? {
        if !isDemoMode, let remembered = LaunchChannelMemory.channelToOpen(in: channels) {
            return remembered
        }
        return channels.first
    }

    /// Called when the viewer tunes a channel. Saved whether or not the switch is on, so turning
    /// it on opens on what was last watched, not on a channel from before.
    func rememberLaunchChannel(_ channel: Channel) {
        guard !isDemoMode else { return }
        LaunchChannelMemory.remember(channel)
    }
}
