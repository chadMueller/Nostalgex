import Foundation
import VideoToolbox

/// Which media server the user authenticated with. Persisted; defaults to `.plex`
/// so existing installs keep working without re-auth.
enum MediaBackendKind: String, Codable, Sendable {
    case plex
    case jellyfin
    case emby
}

/// Abstraction over a media server the app can tune into (Plex, Jellyfin, …).
///
/// Everything downstream of this boundary — channel building, enrichment, scheduling,
/// snapshots, playback — operates on the generic `PlexMediaItem` and `channels.json`
/// rules, so adding a backend means implementing only this protocol. The naming keeps
/// the `Plex`-prefixed model types for back-compat with persisted snapshots.
protocol MediaBackend: Sendable {
    /// Machine identifier of this server. Stamped onto every parsed item so playback,
    /// images, and lookups route back to the right server when several are connected.
    var serverID: String { get }

    /// HTTP headers carrying auth — used by `AVURLAsset` for direct play (token not in URL).
    var authHeaders: [String: String] { get }

    /// Validates connectivity + auth; returns the server's friendly name.
    func testConnection() async throws -> String

    /// Loads every playable item across all libraries on this server.
    func loadLibrary(progress: LoadProgress?) async throws -> [PlexMediaItem]

    /// Library sections/views on this server.
    func loadSections() async throws -> [PlexSection]

    /// Collections within a library section.
    func loadCollections(sectionKey: String) async throws -> [PlexCollection]

    /// Item identifiers belonging to a collection.
    func loadCollectionItems(collectionKey: String) async throws -> [String]

    /// Direct-play URL (raw file) when the container/codecs are AVPlayer-native; else nil.
    func buildDirectPlayURL(for item: PlexMediaItem) -> URL?

    /// HLS transcode URL for when direct play isn't possible.
    func buildTranscodeURL(for item: PlexMediaItem) -> URL?

    /// Tries direct play first, falls back to transcode.
    func buildStreamURL(for item: PlexMediaItem) -> URL?

    /// Resolves the playback URL for an item that needs transcoding (direct play wasn't
    /// possible). Backends that have a playback-negotiation handshake (Jellyfin's
    /// PlaybackInfo) override this to get a valid session + server-chosen remux/transcode;
    /// others fall back to the synchronous `buildTranscodeURL`. Returns nil when the server
    /// cannot produce any playable stream (e.g. transcoding disabled).
    func resolveTranscodePlayback(for item: PlexMediaItem) async -> PlaybackResolution?

    /// Like the above, but the backend may start the stream at `offsetSeconds` itself.
    /// `startsAtOffset` true means the client must NOT seek: seeking into a Plex HLS transcode
    /// that began at zero fails (finished=false) and nothing ever renders. Only Plex does
    /// this. Jellyfin and Emby return false (`JellyfinPlaybackResolver.offsetPlayback`): their
    /// HLS playlist covers the whole runtime and the server transcodes from whichever segment
    /// is requested, so the client seeks, and an offset on the URL breaks the segment requests.
    func resolveTranscodePlayback(for item: PlexMediaItem, offsetSeconds: Int) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)?

    /// Stops an active server-side transcode session so it doesn't linger (matters on a
    /// 24/7 channel-flipping app). `playSessionId` is the backend's session token when it
    /// has one (Jellyfin); backends keyed off a stable client id (Plex) may ignore it.
    func stopTranscode(playSessionId: String?) async

    /// A second HLS attempt with video forced down to 1080p. Used when the server copied a
    /// stream the device turned out not to decode (4K H.264 on an older Apple TV, say): a
    /// re-encode the device can play beats a skipped program. Nil means no such option.
    func cappedTranscodeURL(for item: PlexMediaItem, offsetSeconds: Int, sessionID: String) -> URL?

    /// Registers a hand-built HLS start URL with the server before the player opens it.
    /// Plex needs its `decision` call first or it rejects `start.m3u8`; other backends
    /// have nothing to do.
    func prepareTranscodeSession(startURL: URL) async

    /// Server-side thumbnail URL for an item.
    func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL?
}

/// Play count the rewatch channels use. A server that only says "played", with no
/// count, still counts as one watch, so watched and unwatched channels keep working.
enum ServerWatchCount {
    static func viewCount(playCount: Int?, played: Bool?) -> Int {
        let count = max(0, playCount ?? 0)
        if count > 0 { return count }
        return (played == true) ? 1 : 0
    }
}

/// Jellyfin and Emby session reports. Both servers increment PlayCount themselves
/// when a stop lands near the end of the item, so the tracker sends the real
/// position and only calls `markPlayed` when a watch crossed Plex's 75% gate
/// without reaching that completion zone.
enum MediaServerPlaybackReport {
    enum Event {
        case started
        case progress
        case stopped

        var path: String {
            switch self {
            case .started: return "/Sessions/Playing"
            case .progress: return "/Sessions/Playing/Progress"
            case .stopped: return "/Sessions/Playing/Stopped"
            }
        }
    }

    private struct Body: Encodable {
        let ItemId: String
        let PlaySessionId: String
        let MediaSourceId: String
        let PositionTicks: Int
        let IsPaused: Bool
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    static func post(
        serverURL: String,
        authorization: String,
        event: Event,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionTicks: Int
    ) async {
        guard let url = URL(string: "\(serverURL)\(event.path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(Body(
            ItemId: itemId,
            PlaySessionId: playSessionId,
            MediaSourceId: mediaSourceId,
            PositionTicks: positionTicks,
            IsPaused: false
        ))
        _ = try? await session.data(for: req)
    }

    /// One increment, matching a Plex scrobble. Used when the watch cleared the
    /// 75% gate but the stop position is still short of the server's own
    /// "finished" threshold, which would otherwise not count it.
    static func markPlayed(serverURL: String, authorization: String, userId: String, itemId: String) async {
        guard let itemPath = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let userPath = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(serverURL)/Users/\(userPath)/PlayedItems/\(itemPath)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: req)
    }
}

protocol WatchActivityReporting: Sendable {
    func reportWatchActivity(
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionTicks: Int,
        event: MediaServerPlaybackReport.Event
    ) async

    func markWatched(itemId: String) async
}

extension MediaBackend {
    /// Default convenience: try direct play, fall back to transcode.
    func buildStreamURL(for item: PlexMediaItem) -> URL? {
        buildDirectPlayURL(for: item) ?? buildTranscodeURL(for: item)
    }

    /// Default convenience matching the legacy `width: Int = 400` call sites.
    func thumbnailURL(for item: PlexMediaItem) -> URL? {
        thumbnailURL(for: item, width: 400)
    }

    /// Default convenience matching the legacy `progress: nil` call sites.
    func loadLibrary() async throws -> [PlexMediaItem] {
        try await loadLibrary(progress: nil)
    }

    /// Default: no playback handshake — use the synchronous hand-built transcode URL with
    /// no session to track. Plex inherits this (its server-side decision logic already emits
    /// an AVPlayer-playable stream); Jellyfin overrides it with the PlaybackInfo flow.
    func resolveTranscodePlayback(for item: PlexMediaItem) async -> PlaybackResolution? {
        guard let url = buildTranscodeURL(for: item) else { return nil }
        return PlaybackResolution(url: url, playSessionId: nil, isDirectPlay: false)
    }

    /// Default: backend has no stoppable session.
    func stopTranscode(playSessionId: String?) async {}

    func resolveTranscodePlayback(for item: PlexMediaItem, offsetSeconds: Int) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)? {
        guard let r = await resolveTranscodePlayback(for: item) else { return nil }
        return (r, false)
    }

    func cappedTranscodeURL(for item: PlexMediaItem, offsetSeconds: Int, sessionID: String) -> URL? { nil }

    func prepareTranscodeSession(startURL: URL) async {}
}

// MARK: - Shared library-load progress reporting

/// Progress event from a library load. `showsCompleted`/`totalShows` are populated
/// only during a TV section's per-show batch updates, so the loading view can show
/// `60/130 shows` granularity instead of waiting for the whole section.
struct LoadProgressEvent: Sendable {
    let sectionIndex: Int
    let totalSections: Int
    let sectionTitle: String
    let sectionType: String
    let itemsLoadedSoFar: Int
    let showsCompleted: Int?
    let totalShows: Int?
}

typealias LoadProgress = @Sendable (LoadProgressEvent) -> Void

/// Thrown when a scan is cancelled mid-flight after whole sections had already been read.
///
/// Carrying those items out is what lets a stalled load still land the user in a working
/// guide: an abandoned scan that threw a bare `CancellationError` would discard minutes of
/// fetched library for nothing. Only sections that finished are included — the section that
/// was in flight is dropped.
struct LibraryScanInterrupted: Error {
    let partialItems: [PlexMediaItem]
}


/// Which video codecs this DEVICE can direct-play. HEVC is hardware-dependent: every
/// Apple TV 4K decodes it, the Apple TV HD (A1625) does not — and handing an HEVC file
/// to AVPlayer there produces a silent black screen rather than an error. Gating the
/// direct-play list routes those files to the server transcoder instead, and because the
/// same list feeds the transcode codec advertisement, an incapable device also stops
/// asking the server for HEVC output.
enum CodecSupport {
    static let deviceSupportsHEVC: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)

    static func directPlayVideoCodecs(hevcCapable: Bool) -> Set<String> {
        hevcCapable ? ["h264", "hevc", "mpeg4"] : ["h264", "mpeg4"]
    }

    static let directPlayAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]

    /// What the server may produce for HLS. Lossless targets are excluded on purpose.
    static let transcodeAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3"]

    /// Containers AVPlayer opens as a raw file. MKV and AVI are not, whatever their codecs.
    static let directPlayContainers: Set<String> = ["mp4", "mov", "m4v"]

    /// Codec and bit depth together. 10-bit H.264 (endemic in anime releases) has no
    /// hardware decoder on any Apple device and no software fallback: it direct plays as
    /// audio over a black picture with no error to catch. HEVC Main 10 is fine.
    static func canDecodeVideo(codec: String?, bitDepth: Int?, hevcCapable: Bool) -> Bool {
        guard let codec, !codec.isEmpty else { return true }
        guard directPlayVideoCodecs(hevcCapable: hevcCapable).contains(codec) else { return false }
        if codec == "h264", let bitDepth, bitDepth > 8 { return false }
        return true
    }

    /// Whether HEVC may be offered to the server for THIS file. A device with an HEVC
    /// decoder still cannot render Dolby Vision profile 7; telling the server we take HEVC
    /// invites it to copy the stream through, and the player then fails with a CoreMedia
    /// error. Saying no makes the server produce H.264, which plays.
    static func offersHEVC(doviProfile: Int?, deviceCapable: Bool = deviceSupportsHEVC) -> Bool {
        deviceCapable && doviProfile != 7
    }
}
