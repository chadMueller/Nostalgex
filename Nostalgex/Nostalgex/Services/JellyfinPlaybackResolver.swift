import Foundation

/// Result of resolving how to play a Jellyfin item. `playSessionId` is nil when we fell
/// back to a hand-built URL (no PlaybackInfo handshake), in which case there is no
/// server-tracked transcode session to stop.
struct PlaybackResolution: Sendable {
    let url: URL
    let playSessionId: String?
    let isDirectPlay: Bool
}

extension JellyfinPlaybackResolver {
    /// How a Jellyfin HLS stream reaches a schedule offset: the client seeks, the URL is
    /// left exactly as PlaybackInfo handed it over.
    ///
    /// Jellyfin keeps the file's own timeline. `main.m3u8` lists the whole runtime from
    /// zero whatever the request says, and every segment URL repeats the playlist's query
    /// string, so a `StartTimeTicks` added to the master URL reaches the segment handler,
    /// which refuses it: HTTP 400, server log "StartTimeTicks is not allowed." (measured
    /// against Jellyfin 12.2.0 on 2026-10-06; the same check is in the 10.10.7 and 10.11.0
    /// sources). AVPlayer then failed, the one retry failed the same way, and the auto-skip
    /// played the next scheduled title from its first frame on every tuned-in channel whose
    /// file was not directly playable, which is what DarkGhost101 saw on builds 41 and 42.
    /// A cold request for segment N starts the transcode at N (measured: segment 11 came
    /// back in 9 ms with its first PTS at 114.58 s), so a client-side seek on the full
    /// playlist is the designed path, and the one Jellyfin's own web player takes.
    /// Emby goes through here too. Jellyfin's HLS controller is forked from Emby's, with the
    /// same full-runtime playlist and query string copied onto every segment URL. Not yet
    /// measured against an Emby server.
    static func offsetPlayback(
        _ resolution: PlaybackResolution,
        offsetSeconds: Int
    ) -> (resolution: PlaybackResolution, startsAtOffset: Bool) {
        (resolution, false)
    }
}

/// Device profile we send to Jellyfin's PlaybackInfo endpoint. It tells the server exactly
/// what this Apple TV can play so the server makes the right direct-play / remux / transcode
/// decision instead of us guessing. The two load-bearing rules:
///   • HEVC is only an acceptable codec when the device can hardware-decode it.
///   • Transcoding always targets fMP4 HLS (`Container: "mp4"`), never MPEG-TS — AVPlayer
///     cannot render HEVC from a TS segment (the original black-screen bug).
struct JellyfinDeviceProfile: Encodable, Sendable {
    let MaxStreamingBitrate: Int
    let MaxStaticBitrate: Int
    let DirectPlayProfiles: [DirectPlayProfile]
    let TranscodingProfiles: [TranscodingProfile]

    struct DirectPlayProfile: Encodable, Sendable {
        let Container: String
        let mediaType: String
        let VideoCodec: String?
        let AudioCodec: String?

        enum CodingKeys: String, CodingKey {
            case Container, VideoCodec, AudioCodec
            case mediaType = "Type"
        }
    }

    struct TranscodingProfile: Encodable, Sendable {
        let Container: String
        let mediaType: String
        let VideoCodec: String
        let AudioCodec: String
        let Context: String
        let MaxAudioChannels: String
        let protocolName: String

        enum CodingKeys: String, CodingKey {
            case Container, VideoCodec, AudioCodec, Context, MaxAudioChannels
            case mediaType = "Type"
            case protocolName = "Protocol"
        }
    }
}

enum JellyfinPlaybackResolver {
    /// Codecs AVPlayer can decode. HEVC is gated separately on hardware support.
    private static let audioCodecs = "aac,ac3,eac3,mp3"

    static func deviceProfile(supportsHEVC: Bool) -> JellyfinDeviceProfile {
        let videoCodecs = supportsHEVC ? "h264,hevc" : "h264"
        return JellyfinDeviceProfile(
            MaxStreamingBitrate: StreamQuality.current.maxBitrateBps,
            MaxStaticBitrate: StreamQuality.current.maxBitrateBps,
            DirectPlayProfiles: [
                // Containers AVPlayer can open as a raw file. NB: NOT mkv — AVPlayer cannot
                // demux Matroska no matter the codec, so mkv must always go through the
                // transcoding profile (which remuxes to fMP4 when the codec is compatible).
                .init(Container: "mp4,m4v,mov", mediaType: "Video", VideoCodec: videoCodecs, AudioCodec: audioCodecs),
            ],
            TranscodingProfiles: [
                // fMP4 HLS, h264 (+hevc when capable), audio forced into AVPlayer-friendly codecs.
                .init(Container: "mp4", mediaType: "Video", VideoCodec: videoCodecs, AudioCodec: audioCodecs,
                      Context: "Streaming", MaxAudioChannels: "6", protocolName: "hls"),
            ]
        )
    }

    /// Decoded shape of a PlaybackInfo response (capital-letter Jellyfin keys).
    struct PlaybackInfoResponse: Decodable, Sendable {
        let MediaSources: [PlaybackMediaSource]?
        let PlaySessionId: String?

        struct PlaybackMediaSource: Decodable, Sendable {
            let Id: String?
            let SupportsDirectPlay: Bool?
            let SupportsDirectStream: Bool?
            let SupportsTranscoding: Bool?
            let TranscodingUrl: String?
        }
    }

    /// Pure selection of the playback URL from a decoded PlaybackInfo. No networking — unit
    /// testable. Returns nil only when there is genuinely no playable source (transcoding
    /// disabled and not directly playable), which the caller maps to a `.error` state.
    static func resolve(
        _ info: PlaybackInfoResponse,
        serverURL: String,
        apiKey: String,
        itemId: String,
        mediaSourceId: String?
    ) -> PlaybackResolution? {
        let sources = info.MediaSources ?? []
        let source = sources.first(where: { $0.Id == mediaSourceId }) ?? sources.first

        // 1) Server handed us a transcode/remux URL — use it verbatim (it carries the right
        //    session + params). Only ensure api_key is present for the segment requests.
        if let relative = source?.TranscodingUrl, !relative.isEmpty {
            if let url = makeURL(serverURL: serverURL, relativeOrAbsolute: relative, apiKey: apiKey) {
                return PlaybackResolution(url: url, playSessionId: info.PlaySessionId, isDirectPlay: false)
            }
        }

        // 2) No transcode URL but the source is directly playable — static stream.
        if source?.SupportsDirectPlay == true {
            guard var c = URLComponents(string: "\(serverURL)/Videos/\(itemId)/stream") else { return nil }
            c.queryItems = [
                .init(name: "Static", value: "true"),
                .init(name: "MediaSourceId", value: source?.Id ?? mediaSourceId ?? itemId),
                .init(name: "api_key", value: apiKey),
            ]
            if let url = c.url {
                return PlaybackResolution(url: url, playSessionId: info.PlaySessionId, isDirectPlay: true)
            }
        }

        // 3) Nothing playable (e.g. transcoding disabled server-side).
        return nil
    }

    /// Builds an absolute URL from Jellyfin's (usually server-relative) TranscodingUrl,
    /// guaranteeing a single `api_key` query item.
    private static func makeURL(serverURL: String, relativeOrAbsolute: String, apiKey: String) -> URL? {
        let absolute = relativeOrAbsolute.hasPrefix("http") ? relativeOrAbsolute : serverURL + relativeOrAbsolute
        guard var c = URLComponents(string: absolute) else { return nil }
        var items = c.queryItems ?? []
        if !items.contains(where: { $0.name == "api_key" }) {
            items.append(.init(name: "api_key", value: apiKey))
        }
        c.queryItems = items
        return c.url
    }
}
