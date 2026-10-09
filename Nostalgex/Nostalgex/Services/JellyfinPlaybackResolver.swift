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
    /// same full-runtime playlist and query string copied onto every segment URL. Measured
    /// against Emby Server 4.10.1.0 on 2026-10-08: a mid-schedule join started at 47 minutes
    /// into a 2:50:00 film and held real time.
    static func offsetPlayback(
        _ resolution: PlaybackResolution,
        offsetSeconds: Int
    ) -> (resolution: PlaybackResolution, startsAtOffset: Bool) {
        (resolution, false)
    }

    /// The 1080p rung of the starvation ladder, for both Jellyfin and Emby.
    ///
    /// Without this the ladder had no rung at all on these backends: `cappedTranscodeURL`
    /// was implemented only on Plex, the protocol default returned nil, and a single stall
    /// fell straight through to "nothing smaller to ask for" and skipped to the next
    /// programme. A slow server therefore jumped out of a film mid-scene instead of
    /// stepping the quality down, which is what a movie channel looked like on an Emby
    /// server producing each 6-second segment in 3.4 seconds (measured 2026-10-08).
    ///
    /// 1920 wide at 8 Mbps is deliberately below the `.high` preset: the point is to ask
    /// the server for materially less work than the stream that just starved, not to
    /// re-request the same bitrate under a new session id.
    ///
    /// No start time goes on this URL. The segment handler rejects one, same as the first
    /// attempt, so the caller seeks instead; `cappedStreamStartsAtOffset` is false on both
    /// backends to say so.
    static func cappedTranscodeURL(
        serverURL: String,
        item: PlexMediaItem,
        accessToken: String,
        deviceID: String,
        sessionID: String,
        supportsHEVC: Bool
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/Videos/\(item.ratingKey)/master.m3u8") else {
            return nil
        }
        components.queryItems = [
            .init(name: "MediaSourceId", value: item.partKey ?? item.ratingKey),
            .init(name: "api_key", value: accessToken),
            .init(name: "DeviceId", value: deviceID),
            .init(name: "PlaySessionId", value: sessionID),
            .init(name: "VideoCodec", value: supportsHEVC ? "h264,hevc" : "h264"),
            .init(name: "AudioCodec", value: "aac,ac3,eac3,mp3"),
            .init(name: "VideoBitrate", value: "8000000"),
            .init(name: "MaxWidth", value: "1920"),
            .init(name: "TranscodingMaxAudioChannels", value: "6"),
            .init(name: "SegmentContainer", value: "mp4"),
        ]
        return components.url
    }
}

/// Device profile we send to Jellyfin's PlaybackInfo endpoint. It tells the server exactly
/// what this Apple TV can play so the server makes the right direct-play / remux / transcode
/// decision instead of us guessing. The two load-bearing rules:
///   • HEVC is only an acceptable codec when the device can hardware-decode it.
///   • Transcoding always targets fMP4 HLS (`Container: "mp4"`), never MPEG-TS — AVPlayer
///     cannot render HEVC from a TS segment (the original black-screen bug).
/// CodecProfiles add the two decode limits a codec name does not express; see `deviceProfile`.
struct JellyfinDeviceProfile: Encodable, Sendable {
    let MaxStreamingBitrate: Int
    let MaxStaticBitrate: Int
    let DirectPlayProfiles: [DirectPlayProfile]
    let TranscodingProfiles: [TranscodingProfile]
    let CodecProfiles: [CodecProfile]

    struct CodecProfile: Encodable, Sendable {
        let mediaType: String
        let Codec: String
        let Conditions: [ProfileCondition]

        enum CodingKeys: String, CodingKey {
            case Codec, Conditions
            case mediaType = "Type"
        }
    }

    /// `IsRequired` decides what an unknown value means: true fails the condition, false passes it.
    struct ProfileCondition: Encodable, Sendable {
        let Condition: String
        let Property: String
        let Value: String
        let IsRequired: Bool
    }

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
            ],
            CodecProfiles: codecProfiles(supportsHEVC: supportsHEVC)
        )
    }

    /// Files that pass the codec check and still play as sound over a black picture.
    ///   • 10-bit H.264 has no decoder on any Apple device. The bit-depth cap also stops the
    ///     server copying it into HLS, so it is re-encoded to 8-bit. Not required, so a file
    ///     with no reported bit depth still direct-plays as before.
    ///   • HEVC renders only when tagged hvc1 or dvh1 (jellyfin-web asks Safari for the same).
    ///     Jellyfin counts a tag mismatch as a reason to remux, not re-encode, and its HLS
    ///     muxer writes hvc1, so an hev1 file costs a remux. Required, so an unknown tag
    ///     remuxes rather than risk the black picture. That case is common: Jellyfin 12.1
    ///     records no codec tags at all (its probe reads `codec_tag_string?`), so on 12.1
    ///     every HEVC MP4 remuxes, hvc1 included. Measured against a 12.1 server.
    private static func codecProfiles(supportsHEVC: Bool) -> [JellyfinDeviceProfile.CodecProfile] {
        var profiles: [JellyfinDeviceProfile.CodecProfile] = [
            .init(mediaType: "Video", Codec: "h264", Conditions: [
                .init(Condition: "LessThanEqual", Property: "VideoBitDepth", Value: "8", IsRequired: false),
            ]),
        ]
        if supportsHEVC {
            profiles.append(.init(mediaType: "Video", Codec: "hevc", Conditions: [
                .init(Condition: "EqualsAny", Property: "VideoCodecTag", Value: "hvc1|dvh1", IsRequired: true),
            ]))
        }
        return profiles
    }

    /// Which audio track to ask for, when the file offers more than one.
    ///
    /// Jellyfin and Emby hand back whichever track the file marks default, and plenty of
    /// files mark a dubbed track. Measured 2026-10-08: Joe Dirt carries
    /// `spa 2ch "Spanish [Latinoamericano]" IsDefault=true` ahead of
    /// `eng 6ch "English [US]" IsDefault=false`, so the film played in Spanish on a
    /// channel with no way for the viewer to change it. A retro TV guide has no audio
    /// picker and should not need one; it should just pick the sensible track.
    ///
    /// Preference order: a track in one of the viewer's languages, most channels first so
    /// a 5.1 mix wins over a stereo one; then whatever the file calls default; then the
    /// first audio track there is. Returns nil when there is nothing to choose between,
    /// which leaves the server's own choice alone.
    static func preferredAudioIndex(
        in streams: [PlaybackInfoResponse.MediaStream]?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Int? {
        let audio = (streams ?? []).filter { $0.mediaType?.lowercased() == "audio" }
        guard audio.count > 1 else { return nil }

        // "en-GB" and "eng" both have to match a track tagged "eng" or "en".
        let wanted = Set(preferredLanguages.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier.lowercased()
        } + ["en"])
        func matches(_ language: String?) -> Bool {
            guard let l = language?.lowercased(), !l.isEmpty else { return false }
            return wanted.contains(String(l.prefix(2)))
        }

        let inLanguage = audio.filter { matches($0.Language) }
        if let best = inLanguage.max(by: { ($0.Channels ?? 0) < ($1.Channels ?? 0) }) {
            return best.Index
        }
        return audio.first(where: { $0.IsDefault == true })?.Index ?? audio.first?.Index
    }

    /// Puts `AudioStreamIndex` on a transcode URL, replacing any the server already set.
    static func pinningAudioStream(_ url: URL, index: Int?) -> URL {
        guard let index, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = (c.queryItems ?? []).filter { $0.name != "AudioStreamIndex" }
        items.append(.init(name: "AudioStreamIndex", value: "\(index)"))
        c.queryItems = items
        return c.url ?? url
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
            let MediaStreams: [MediaStream]?
        }

        struct MediaStream: Decodable, Sendable {
            let Index: Int?
            /// Wire key is "Type"; Swift reserves that as a member name.
            let mediaType: String?
            let Language: String?
            let IsDefault: Bool?
            let Channels: Int?

            enum CodingKeys: String, CodingKey {
                case Index, Language, IsDefault, Channels
                case mediaType = "Type"
            }
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
        //    session + params). Only ensure api_key is present for the segment requests,
        //    and pin the audio track, because the server picks the file's default and that
        //    is not always a language the viewer speaks.
        if let relative = source?.TranscodingUrl, !relative.isEmpty {
            if let url = makeURL(serverURL: serverURL, relativeOrAbsolute: relative, apiKey: apiKey) {
                let pinned = pinningAudioStream(
                    url, index: preferredAudioIndex(in: source?.MediaStreams)
                )
                return PlaybackResolution(url: pinned, playSessionId: info.PlaySessionId, isDirectPlay: false)
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
