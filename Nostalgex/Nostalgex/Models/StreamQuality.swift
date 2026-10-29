import Foundation

/// Ceiling for transcoded playback, shared by every backend.
///
/// Playback previously asked every server for a 40 Mbps 4K transcode with adaptive
/// bitrate switched off, regardless of connection. On anything short of a fast local
/// network that either buffers forever or fails outright. Nostalgex plays catalogue-era
/// content on a retro guide, so maximum fidelity matters far less than a stream that
/// keeps playing — but `.maximum` preserves the old behaviour for people who want it.
enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case auto
    case maximum
    case high
    case medium
    case low

    var id: String { rawValue }

    static let storageKey = "nostalgex_stream_quality"

    /// Defaults to `.auto`, which lets the server step quality down when the connection
    /// can't sustain it. Nothing had that behaviour before.
    static var current: StreamQuality {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey),
                  let quality = StreamQuality(rawValue: raw) else { return .auto }
            return quality
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    var displayName: String {
        switch self {
        case .auto:    return "Auto"
        case .maximum: return "Maximum"
        case .high:    return "High"
        case .medium:  return "Medium"
        case .low:     return "Low"
        }
    }

    var detail: String {
        switch self {
        case .auto:    return "Up to 4K, drops quality when the connection can't keep up."
        case .maximum: return "4K, 40 Mbps, never reduced. Fast local networks only."
        case .high:    return "1080p, 12 Mbps."
        case .medium:  return "720p, 4 Mbps. Works on most hotel and cafe wifi."
        case .low:     return "480p, 1.5 Mbps. For weak or metered connections."
        }
    }

    /// Kilobits per second — Plex's `maxVideoBitrate` unit.
    var maxBitrateKbps: Int {
        switch self {
        case .auto:    return 40_000
        case .maximum: return 40_000
        case .high:    return 12_000
        case .medium:  return 4_000
        case .low:     return 1_500
        }
    }

    /// Bits per second — Jellyfin and Emby's `MaxStreamingBitrate` / `VideoBitrate` unit.
    var maxBitrateBps: Int { maxBitrateKbps * 1_000 }

    var width: Int {
        switch self {
        case .auto, .maximum: return 3840
        case .high:           return 1920
        case .medium:         return 1280
        case .low:            return 854
        }
    }

    var height: Int {
        switch self {
        case .auto, .maximum: return 2160
        case .high:           return 1080
        case .medium:         return 720
        case .low:            return 480
        }
    }

    var resolutionString: String { "\(width)x\(height)" }

    /// Plex's 0-100 quality index, paired with the bitrate ceiling above.
    var videoQualityIndex: Int {
        switch self {
        case .auto, .maximum: return 100
        case .high:           return 90
        case .medium:         return 75
        case .low:            return 60
        }
    }

    /// Bitrate ceiling for *direct play* over a remote connection, in kbps.
    ///
    /// Transcoded playback negotiates down on its own via adaptive HLS, so its ceiling can
    /// sit high. Direct play streams the original file with no such safety net — if the
    /// connection can't carry it, playback simply fails. So `.auto` stays deliberately
    /// conservative here even though its transcode ceiling is 4K/40 Mbps.
    ///
    /// Only applied to remote servers. On a LAN there is no reason to refuse direct play,
    /// and transcoding instead would burn server CPU for nothing.
    var remoteDirectPlayCeilingKbps: Int {
        switch self {
        case .maximum: return .max
        case .auto:    return 20_000
        case .high:    return 12_000
        case .medium:  return 4_000
        case .low:     return 1_500
        }
    }

    /// Whether the server may drop quality mid-stream (`autoAdjustQuality` on the request).
    ///
    /// Always off. Measured 2026-10-06 against Chad's Plex server: with it on, every stream
    /// where both video and audio are re-encoded came back as 3-second segments, served the
    /// first eight at full speed, then one segment every 6.1 seconds for the rest of the
    /// film. tvOS 26 abandons a segment that slow (CoreMedia -15628) and the picture died at
    /// 24 seconds, at 4K and at the 1080p retry alike, on every such file. With it off the
    /// same request came back as 1-second segments and ran 75 seconds of content in 75
    /// seconds. Quality stepping is the app's own job now (PlaybackStarvation).
    var allowsAutoAdjust: Bool { false }
}

/// Independent local Plex opt-in. Capped quality remains stored for remote servers,
/// other backends and formats outside the verified original-video path.
enum LocalPlexOriginalQuality {
    static let storageKey = "nostalgex_local_plex_original_video"
    static let requestCeilingKbps = 100_000
    static let detail = "Keep supported local 4K video unchanged, up to 100 Mbps. Audio may convert to 5.1. Other playback keeps your capped quality. Applies on the next tune."
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}
