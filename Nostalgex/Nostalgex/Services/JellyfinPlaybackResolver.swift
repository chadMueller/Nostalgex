import Foundation

/// Result of resolving how to play a Jellyfin item. `playSessionId` is nil when Jellyfin
/// fell back to a hand-built URL (no PlaybackInfo handshake), in which case there is no
/// server-tracked transcode session to stop. Emby's hand-built URL carries its own id.
struct PlaybackResolution: Sendable {
    let url: URL
    let playSessionId: String?
    let isDirectPlay: Bool
    var requiresOriginalVideo: Bool = false
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
    /// Emby goes through here too. Measured against Emby Server 4.10.1.0 on 2026-10-08: a
    /// mid-schedule join started at 47 minutes into a 2:50:00 film and held real time.
    ///
    /// Emby would take the start time: it does not copy the query string onto segment URLs
    /// (they carry only `PlaySessionId`), and a `StartTimeTicks` on PlaybackInfo comes back
    /// as `#EXT-X-START` with every request answering 200 on 4.8.11.0, 4.9.5.0 and
    /// 4.10.1.0 (measured 2026-10-16). It is still not used, because it does not fix what
    /// the seek gets wrong there: AVPlayer fetches init.mp4 first, which starts the encode
    /// at zero, and the join segment restarts it, the same as a seek. Even an encode that
    /// starts at the join point played 1.78 s out of sync on fMP4. What fixes that is the
    /// segment format; see `embySegmentContainer`.
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
    /// No start time goes on this URL, so the caller seeks instead;
    /// `cappedStreamStartsAtOffset` is false on both backends to say so. Jellyfin refuses a
    /// start time on segment requests, and on Emby it does not help (see `offsetPlayback`).
    /// `segmentContainer` is "mp4" for Jellyfin; Emby passes `embySegmentContainer`.
    static func cappedTranscodeURL(
        serverURL: String,
        item: PlexMediaItem,
        accessToken: String,
        deviceID: String,
        sessionID: String,
        supportsHEVC: Bool,
        segmentContainer: String = "mp4"
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/Videos/\(item.ratingKey)/master.m3u8") else {
            return nil
        }
        components.queryItems = [
            .init(name: "MediaSourceId", value: item.partKey ?? item.ratingKey),
            .init(name: "api_key", value: accessToken),
            .init(name: "DeviceId", value: deviceID),
            .init(name: "PlaySessionId", value: sessionID),
            .init(name: "VideoCodec", value: transcodeVideoCodecs(supportsHEVC: supportsHEVC, segmentContainer: segmentContainer)),
            .init(name: "AudioCodec", value: "aac,ac3,eac3,mp3"),
            .init(name: "VideoBitrate", value: "8000000"),
            .init(name: "MaxWidth", value: "1920"),
            .init(name: "TranscodingMaxAudioChannels", value: "6"),
            .init(name: "SegmentContainer", value: segmentContainer),
        ]
        return components.url
    }

    /// Emby only: the HLS segment format to ask for. MPEG-TS whenever the stream's video can
    /// only come out as H.264, fMP4 only when it may come out as HEVC, which AVPlayer will
    /// not render from TS.
    ///
    /// Why: on Emby, every mid-programme join restarts the encode at the join segment (the
    /// client seek; asking for the start time up front restarts it too, see
    /// `offsetPlayback`). When the video is copied and the audio is not (DTS, TrueHD, FLAC
    /// and other sources AVPlayer cannot decode), the copied video starts at the keyframe
    /// before the join point and the audio exactly at it. fMP4 stamps both tracks from zero
    /// and records the gap only in the init segment's edit list, which AVPlayer does not
    /// apply, so the sound runs early by up to a whole GOP for the rest of the programme
    /// and never catches up. TS segments carry the source timestamps, so the player lines
    /// the tracks up itself. Measured on a Mac with AVPlayer against Emby 4.10.1.0
    /// (2026-10-16), joining at 247 s, sound minus picture: H.264 + DTS (2 s GOP) -1720 ms
    /// on fMP4, +35 ms on TS; H.264 + FLAC (5 s GOP) -731 / +24 ms; H.264 + TrueHD (10.4 s
    /// GOP) about -6.2 s / +24 ms; the same files played from the start, +25 to +36 ms.
    /// Asking Emby not to copy the video was rejected: it puts the gap the other way round
    /// when the audio is copied (H.264 + AC3, +1829 ms) and fails outright on 10-bit
    /// sources on Emby 4.10.1.0.
    ///
    /// An unknown codec on an HEVC-capable device keeps fMP4, which is what every stream
    /// used before. HEVC copied into fMP4 still has the offset (H.265 + DTS -1720 ms,
    /// 10-bit H.265 + TrueHD -1731 ms, on Emby 4.8, 4.9 and 4.10). Jellyfin does not need
    /// this: the same fMP4 join measured in sync on Jellyfin 12.2.0 (+35 ms, +24 ms).
    static func embySegmentContainer(videoCodec: String?, supportsHEVC: Bool) -> String {
        let codec = videoCodec?.lowercased() ?? ""
        let mayBeHEVC = supportsHEVC && (codec.isEmpty || codec == "hevc" || codec == "h265")
        return mayBeHEVC ? "mp4" : "ts"
    }

    /// The video codecs a server stream may carry. TS is H.264 only: offering HEVC there
    /// would let the server copy HEVC into TS, which plays as sound over a black picture.
    static func transcodeVideoCodecs(supportsHEVC: Bool, segmentContainer: String) -> String {
        supportsHEVC && segmentContainer != "ts" ? "h264,hevc" : "h264"
    }
}

/// Device profile we send to Jellyfin's PlaybackInfo endpoint. It tells the server exactly
/// what this Apple TV can play so the server makes the right direct-play / remux / transcode
/// decision instead of us guessing. The two load-bearing rules:
///   • HEVC is only an acceptable codec when the device can hardware-decode it.
///   • HEVC is only ever streamed as fMP4 HLS (`Container: "mp4"`), never MPEG-TS: AVPlayer
///     cannot render HEVC from a TS segment (the original black-screen bug). Jellyfin always
///     gets fMP4; Emby gets TS when the video can only be H.264 (`embySegmentContainer`).
/// CodecProfiles add the decode limits a codec name does not express; see `deviceProfile`.
/// SubtitleProfiles stop the server painting subtitles into the picture; see `subtitleProfiles(burning:)`.
struct JellyfinDeviceProfile: Encodable, Sendable {
    let MaxStreamingBitrate: Int
    let MaxStaticBitrate: Int
    let DirectPlayProfiles: [DirectPlayProfile]
    let TranscodingProfiles: [TranscodingProfile]
    let CodecProfiles: [CodecProfile]
    let SubtitleProfiles: [SubtitleProfile]

    /// `Method` is the server's word for how a subtitle reaches the client: "Encode" burns
    /// it into the video, "External" leaves it as a separate file the client may fetch.
    struct SubtitleProfile: Encodable, Sendable, Equatable {
        let Format: String
        let Method: String
    }

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

/// Body of the PlaybackInfo POST, shared by Jellyfin and Emby.
///
/// `EnableDirectPlay` and `EnableDirectStream` are nil on the first attempt, so the keys are
/// left out and the server decides exactly as it always has. They are false only when the
/// file has already been played directly and gave no picture or starved; see
/// `JellyfinPlaybackResolver.playbackInfoBody`.
///
/// `SubtitleStreamIndex` is -1, no subtitle stream in the video, unless the source has a
/// forced track in the viewer's subtitle language; then it names that track and the server
/// burns it in. See `JellyfinPlaybackResolver.noSubtitleStream` and `forcedSubtitleToBurn`.
struct PlaybackInfoBody: Encodable, Sendable {
    let DeviceProfile: JellyfinDeviceProfile
    let MediaSourceId: String
    let MaxStreamingBitrate: Int
    let SubtitleStreamIndex: Int
    let EnableDirectPlay: Bool?
    let EnableDirectStream: Bool?
}

enum JellyfinPlaybackResolver {
    /// Codecs AVPlayer can decode. HEVC is gated separately on hardware support.
    private static let audioCodecs = "aac,ac3,eac3,mp3"

    /// What the app asks PlaybackInfo. `serverStreamOnly` is the retry after a direct play
    /// that gave no picture or starved, and it has to come back as an HLS stream the server
    /// makes, not the file that just failed.
    ///
    /// Asked the first-attempt question, both servers call an 8-bit H.264 MP4 directly
    /// playable and hand back no TranscodingUrl, so the resolver returned the same static
    /// file and the ladder played it a second time before it reached the 1080p rung.
    /// Measured 2026-10-13 against Jellyfin 12.2.0 and Emby 4.10.1.0: first-attempt body
    /// gives `SupportsDirectPlay=true`, no TranscodingUrl, on both. `EnableDirectPlay=false`
    /// alone is enough for Jellyfin but not for Emby, which then reports
    /// `SupportsDirectStream=true` and still no TranscodingUrl. With both flags false each
    /// server returns a `master.m3u8` TranscodingUrl whose variant, init and first three
    /// segments answer 200. An MKV is unaffected: it never direct plays, and the flags
    /// change nothing about the TranscodingUrl it already gets.
    ///
    /// `burningSubtitle` is the forced track to burn in, from `forcedSubtitleToBurn`; nil
    /// asks for no subtitle at all.
    ///
    /// `segmentContainer` is the HLS segment format; Jellyfin leaves it at "mp4" and Emby
    /// passes `embySegmentContainer`, on both the usual request and the one burning a track.
    static func playbackInfoBody(
        mediaSourceId: String,
        supportsHEVC: Bool,
        serverStreamOnly: Bool,
        burningSubtitle: Int? = nil,
        segmentContainer: String = "mp4"
    ) -> PlaybackInfoBody {
        PlaybackInfoBody(
            DeviceProfile: deviceProfile(
                supportsHEVC: supportsHEVC,
                burningSubtitle: burningSubtitle != nil,
                segmentContainer: segmentContainer
            ),
            MediaSourceId: mediaSourceId,
            MaxStreamingBitrate: StreamQuality.current.maxBitrateBps,
            SubtitleStreamIndex: burningSubtitle ?? noSubtitleStream,
            EnableDirectPlay: serverStreamOnly ? false : nil,
            EnableDirectStream: serverStreamOnly ? false : nil
        )
    }

    /// No subtitle stream goes into the video, whatever the file or the server account says,
    /// with one exception: a forced track in the viewer's language (`forcedSubtitleToBurn`).
    ///
    /// Left to itself the server picks a subtitle track by the account's subtitle mode and,
    /// with no way to hand it to this client, burns it into the picture: a full video
    /// re-encode for the whole film, subtitles in the guide preview, and no way to turn
    /// them off. Measured 2026-10-19 against Jellyfin 12.2.0 (mode Default) and Emby
    /// 4.10.1.0 (mode Smart) with MKVs carrying SRT, ASS, PGS and VobSub tracks: Jellyfin
    /// burned in every default or forced track, Emby every forced one, both with libx264
    /// and an overlay or subtitles filter. On Jellyfin an MP4 with a default mov_text track
    /// or a sidecar .srt lost direct play and was re-encoded the same way (the app asks about
    /// HEVC MP4s, and on the retry). With -1 every case copies the video, and the MP4s
    /// direct play again. Neither server put a subtitle track into the HLS stream either
    /// way, so the app had no other way to show a server's subtitles.
    ///
    /// Not used: Jellyfin's HLS subtitle delivery. It does add text tracks to the master
    /// playlist, but its WebVTT says `X-TIMESTAMP-MAP=MPEGTS:900000` (10 s), the start of its
    /// MPEG-TS output, while its fMP4 output starts at 0. AVPlayer showed every cue 10 s
    /// late. Emby has no HLS subtitle delivery at all.
    ///
    /// -1 is honoured only when `MediaSourceId` matches the source: without one, Jellyfin
    /// burned in as before. Jellyfin still writes `SubtitleMethod=Encode` on the URL with -1;
    /// that is its default value, and nothing is encoded.
    static let noSubtitleStream = -1

    /// Every subtitle format either server names. Names are the servers' own (Jellyfin
    /// `PGSSUB`, `DVDSUB`, `subrip`; Emby `srt`), matched without regard to case.
    static let subtitleFormats = [
        "srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "ttml", "sub", "smi", "sami",
        "pgs", "pgssub", "dvdsub", "vobsub", "dvbsub", "sup", "xsub",
    ]

    /// Normally "External" for every format: belt and braces for -1, so if a server ever
    /// picks a track anyway it does not burn it. Measured: with these profiles and no -1, no
    /// file in the matrix was burned in on either server. Image formats are listed too,
    /// because a list without them still burned PGS and VobSub.
    ///
    /// "Encode" when burning the forced track. "External" would stop that too: asked for a
    /// track by index with these External profiles, both servers answered External and
    /// copied the video. Asked with Encode, both burned it in (measured on SRT, PGS and
    /// VobSub forced tracks and the forced PGS of a Blu-ray layout, both clients).
    static func subtitleProfiles(burning: Bool) -> [JellyfinDeviceProfile.SubtitleProfile] {
        subtitleFormats.map { .init(Format: $0, Method: burning ? "Encode" : "External") }
    }

    /// The forced subtitle track to burn into the picture, or nil.
    ///
    /// Mirrors the app's own rule for subtitles the viewer has not turned on
    /// (`AppState.pickForcedLegibleOption`): a track flagged forced, in the viewer's
    /// subtitle language, is always shown. Those are the lines a film means to be read,
    /// such as Na'vi in Avatar. AVPlayer can show such a track only if it reaches the
    /// stream, and neither server sends one, so the server burns it in. That costs a video
    /// re-encode, for these files only. A track that is only flagged default is never burned:
    /// full subtitles are the viewer's choice, shown in full screen only. Text and image
    /// tracks both qualify. The first matching forced track wins, as in the app.
    static func forcedSubtitleToBurn(
        in streams: [PlaybackInfoResponse.MediaStream]?,
        preferredLanguage: String
    ) -> Int? {
        (streams ?? []).first {
            $0.mediaType?.lowercased() == "subtitle" && $0.IsForced == true
                && SubtitleSelectionLogic.sameLanguage($0.Language, preferredLanguage)
        }?.Index
    }

    static func deviceProfile(
        supportsHEVC: Bool,
        burningSubtitle: Bool = false,
        segmentContainer: String = "mp4"
    ) -> JellyfinDeviceProfile {
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
                // HLS, h264 (+hevc when capable and fMP4), audio forced into AVPlayer-friendly codecs.
                .init(Container: segmentContainer, mediaType: "Video",
                      VideoCodec: transcodeVideoCodecs(supportsHEVC: supportsHEVC, segmentContainer: segmentContainer),
                      AudioCodec: audioCodecs, Context: "Streaming", MaxAudioChannels: "6", protocolName: "hls"),
            ],
            CodecProfiles: codecProfiles(supportsHEVC: supportsHEVC),
            SubtitleProfiles: subtitleProfiles(burning: burningSubtitle)
        )
    }

    /// The dynamic ranges Apple TV renders, in Jellyfin's `VideoRangeType` names.
    ///
    /// Without it Jellyfin copied a Dolby Vision profile 5 file into the fMP4 stream as
    /// plain `hvc1`: no `dvcC` box, no colour information, `CODECS="hvc1..."`, though every
    /// frame still carried the DV RPU. AVFoundation read that track as SDR (`containsHDRVideo`
    /// false). Profile 5 has no HDR10 base layer, so a player that does not treat it as Dolby
    /// Vision shows the IPT picture as ordinary colour: green and purple. That is the
    /// classic "green tint on DV files". With the list Jellyfin writes `dvh1` with a profile
    /// 5 `dvcC` and `CODECS="dvh1.05.06"`, video still copied, the same stream our Plex path
    /// gets from `dolbyVisionRemuxURL`. Profile 8.1 gains its `dvvC` box and keeps `hvc1`
    /// with `SUPPLEMENTAL-CODECS="dvh1.08.03/db1p"`, Apple's form for DV with an HDR10
    /// base. Measured 2026-10-19 against Jellyfin 12.2.0.
    ///
    /// `DOVIWithEL` (profile 7, Blu-ray dual layer) is left out on purpose: AVPlayer cannot
    /// render it as Dolby Vision. With the cap lifted Jellyfin then copied it and removed
    /// the RPU (`hevc_metadata=remove_dovi=1`), a clean HDR10 stream; at the app's 40 Mbps
    /// cap these remuxes are re-encoded either way. HDR10+ is copied with its metadata with
    /// or without the list, and so are HDR10 and an 8-bit hev1 HEVC file with no colour
    /// tags. Emby ignores the property and decided every file exactly as before.
    static let videoRangeTypes = "SDR|HDR10|HLG|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR"

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
    ///   • HEVC also names the dynamic ranges it can show, so Dolby Vision arrives signalled
    ///     as Dolby Vision; see `videoRangeTypes`.
    private static func codecProfiles(supportsHEVC: Bool) -> [JellyfinDeviceProfile.CodecProfile] {
        var profiles: [JellyfinDeviceProfile.CodecProfile] = [
            .init(mediaType: "Video", Codec: "h264", Conditions: [
                .init(Condition: "LessThanEqual", Property: "VideoBitDepth", Value: "8", IsRequired: false),
            ]),
        ]
        if supportsHEVC {
            profiles.append(.init(mediaType: "Video", Codec: "hevc", Conditions: [
                .init(Condition: "EqualsAny", Property: "VideoCodecTag", Value: "hvc1|dvh1", IsRequired: true),
                .init(Condition: "EqualsAny", Property: "VideoRangeType", Value: videoRangeTypes, IsRequired: false),
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
            let IsForced: Bool?
            let Channels: Int?

            enum CodingKeys: String, CodingKey {
                case Index, Language, IsDefault, IsForced, Channels
                case mediaType = "Type"
            }
        }
    }

    /// Pure selection of the playback URL from a decoded PlaybackInfo. No networking — unit
    /// testable. Returns nil only when there is genuinely no playable source (transcoding
    /// disabled and not directly playable), which the caller maps to a `.error` state.
    ///
    /// `serverStreamOnly` never returns the static file: a server that still offers only
    /// direct play gets nil, and the caller falls back to its hand-built HLS stream.
    static func resolve(
        _ info: PlaybackInfoResponse,
        serverURL: String,
        apiKey: String,
        itemId: String,
        mediaSourceId: String?,
        serverStreamOnly: Bool = false
    ) -> PlaybackResolution? {
        let source = source(in: info, mediaSourceId: mediaSourceId)

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

        // 2) No transcode URL but the source is directly playable: static stream. Not on
        //    the retry after a direct play failed, because that is the file that just failed.
        if !serverStreamOnly, source?.SupportsDirectPlay == true {
            if let url = staticStreamURL(serverURL: serverURL, itemId: itemId,
                                         mediaSourceId: source?.Id ?? mediaSourceId ?? itemId, apiKey: apiKey) {
                return PlaybackResolution(url: url, playSessionId: info.PlaySessionId, isDirectPlay: true)
            }
        }

        // 3) Nothing playable (e.g. transcoding disabled server-side).
        return nil
    }

    /// The media source PlaybackInfo answered for: the one asked about, else the first.
    static func source(in info: PlaybackInfoResponse, mediaSourceId: String?) -> PlaybackInfoResponse.PlaybackMediaSource? {
        let sources = info.MediaSources ?? []
        return sources.first(where: { $0.Id == mediaSourceId }) ?? sources.first
    }

    typealias PlaybackInfoSend = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// PlaybackInfo for Jellyfin and Emby: the usual question, and a second one only when the
    /// answer lists a forced subtitle track to burn in (`forcedSubtitleToBurn`). The source's
    /// tracks are known only from the first answer. `request(nil)` is the usual body,
    /// `request(index)` the one burning that track. If the second request fails or offers
    /// nothing playable, the first answer is used: the film without its forced lines beats
    /// no film. Throws only when the first request does.
    static func negotiate(
        request: (Int?) -> URLRequest?,
        serverURL: String,
        apiKey: String,
        itemId: String,
        mediaSourceId: String,
        serverStreamOnly: Bool,
        preferredSubtitleLanguage: String,
        send: PlaybackInfoSend
    ) async throws -> PlaybackResolution? {
        guard let first = request(nil) else { return nil }
        let (data, response) = try await send(first)
        let info = try decodePlaybackInfo(data, response)
        if let forced = forcedSubtitleToBurn(
            in: source(in: info, mediaSourceId: mediaSourceId)?.MediaStreams,
            preferredLanguage: preferredSubtitleLanguage
        ), let second = request(forced),
           let (data2, response2) = try? await send(second),
           let burnedInfo = try? decodePlaybackInfo(data2, response2),
           let burned = resolve(burnedInfo, serverURL: serverURL, apiKey: apiKey, itemId: itemId,
                                mediaSourceId: mediaSourceId, serverStreamOnly: serverStreamOnly) {
            return burned
        }
        return resolve(info, serverURL: serverURL, apiKey: apiKey, itemId: itemId,
                       mediaSourceId: mediaSourceId, serverStreamOnly: serverStreamOnly)
    }

    private static func decodePlaybackInfo(_ data: Data, _ response: URLResponse) throws -> PlaybackInfoResponse {
        guard let http = response as? HTTPURLResponse else { throw PlexAPIService.APIError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw PlexAPIService.APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw PlexAPIService.APIError.httpFailure(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
    }

    /// The direct-play URL for Jellyfin and Emby: the file as stored, served whole.
    ///
    /// The `.mp4` on the path is load-bearing. Without it the server labels the response by
    /// the file's name, not by what is inside it, and AVPlayer goes by the label. An MP4
    /// saved as `.mkv` (common for downloads; ffprobe reads `mov,mp4,m4a,3gp,3g2,mj2`) came
    /// back as `video/x-matroska` and AVPlayer refused it in 0.3 s with -11828 "Cannot Open"
    /// (-12847, "This media format is not supported"). The same bytes asked for as
    /// `stream.mp4` came back as `video/mp4` and played. Measured on the tvOS 26.1
    /// simulator against Jellyfin 12.2.0 on 2026-10-12.
    ///
    /// `Static=true` still serves the file untouched, whatever the extension says; only the
    /// label changes. `.mp4` is right for every file that gets here: direct play is offered
    /// only for the `mp4`, `m4v` and `mov` containers, client and server side alike, and
    /// AVPlayer reads all three as `video/mp4` (a real QuickTime `.mov` played too).
    static func staticStreamURL(serverURL: String, itemId: String, mediaSourceId: String, apiKey: String) -> URL? {
        guard var c = URLComponents(string: "\(serverURL)/Videos/\(itemId)/stream.mp4") else { return nil }
        c.queryItems = [
            .init(name: "Static", value: "true"),
            .init(name: "MediaSourceId", value: mediaSourceId),
            .init(name: "api_key", value: apiKey),
        ]
        return c.url
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
