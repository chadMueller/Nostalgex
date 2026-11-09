import Foundation

/// OPEN ON LAST CHANNEL (I-017): start the app on the channel the viewer last tuned, instead of
/// the first one in the guide.
///
/// Per Apple TV. The switch is not in `PreferenceSync.syncedKeys`, so iCloud never carries it, or
/// the channel, to another Apple TV. On unless someone turns it off. With it off,
/// a launch opens exactly where it did before this setting existed.
///
/// The channel is saved whether the switch is on or off, so a launch only has something to open
/// once the viewer has tuned a channel on this build. Until then, and for a viewer who updated
/// from a build without this setting, a launch opens the first channel as before.
///
/// What is saved is the channel's id AND its name. A collection or franchise channel can be
/// renumbered when the lineup is rebuilt, so an id alone could tune a different channel than the
/// one the viewer left. A saved channel that is gone, or whose name no longer matches, opens the
/// first channel, as the app does today.
enum LaunchChannelMemory {
    /// The Settings switch. Local to this Apple TV.
    static let enabledKey = "nostalgex_open_on_last_channel"
    /// The one line the default lives on. A switch the viewer has pressed is stored under
    /// `enabledKey` and always wins over it.
    static let enabledByDefault = true
    /// The channel the viewer last tuned: `Saved`, JSON.
    static let savedKey = "nostalgex_last_watched_channel"

    struct Saved: Codable, Equatable {
        let id: Int
        let name: String
    }

    static func isEnabled(defaults: UserDefaults = AppDefaults.standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? enabledByDefault
    }

    /// Records a channel the viewer tuned (the guide, the next and previous keys, the mini
    /// strip). Not called for a tune the app makes on its own, so falling back to the first
    /// channel at launch does not forget the one that was missing.
    static func remember(_ channel: Channel, defaults: UserDefaults = AppDefaults.standard) {
        let value = Saved(id: channel.id, name: channel.name)
        guard saved(defaults: defaults) != value, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: savedKey)
    }

    static func saved(defaults: UserDefaults = AppDefaults.standard) -> Saved? {
        guard let data = defaults.data(forKey: savedKey) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// Sign-out and server changes: the channel belongs to the lineup that was just left.
    static func clear(defaults: UserDefaults = AppDefaults.standard) {
        defaults.removeObject(forKey: savedKey)
    }

    /// The channel a launch should open on: the saved one when the switch is on and a channel
    /// with that same id and that same name is in `channels`. Nil otherwise, and the caller
    /// opens where it did before.
    static func channelToOpen(in channels: [Channel], defaults: UserDefaults = AppDefaults.standard) -> Channel? {
        guard isEnabled(defaults: defaults), let saved = saved(defaults: defaults) else { return nil }
        return channels.first { $0.id == saved.id && $0.name == saved.name }
    }
}
