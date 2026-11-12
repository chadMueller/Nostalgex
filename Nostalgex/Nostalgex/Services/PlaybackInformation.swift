import Foundation

/// The information screen accepts only enums, bounded numbers and allowlisted codec
/// names. It never stores a media item, URL, server identity, session id or error text.
struct PlaybackInformation: Equatable {
    enum Backend: String, Equatable {
        case plex = "Plex", jellyfin = "Jellyfin", emby = "Emby", demo = "Demo"
    }

    enum Delivery: Equatable {
        case unknown, directPlay, serverStream
        var label: String {
            switch self {
            case .unknown: return "Unknown"
            case .directPlay: return "Direct Play"
            case .serverStream: return "Server stream"
            }
        }
    }

    /// What the server said it does to the streams of a server stream, read from its own
    /// answer (Plex's `decision` reply), never inferred: Plex lists each stream as copied or
    /// transcoded. Remux is the container rewritten with both streams copied.
    enum ServerStream: Equatable, Sendable {
        case remux, transcodeVideo, transcodeAudio, transcodeVideoAndAudio
        var label: String {
            switch self {
            case .remux: return "Remux"
            case .transcodeAudio: return "Transcode (audio)"
            case .transcodeVideo: return "Transcode (video)"
            case .transcodeVideoAndAudio: return "Transcode (video and audio)"
            }
        }

        static let allLabels = [ServerStream.remux, .transcodeAudio, .transcodeVideo, .transcodeVideoAndAudio].map(\.label)

        /// From each stream's `decision` attribute. Anything but copy or transcode is not an
        /// answer: nil, and the row keeps saying "Server stream".
        init?(video: String?, audio: String?) {
            switch (video, audio) {
            case ("copy", "copy"): self = .remux
            case ("copy", "transcode"): self = .transcodeAudio
            case ("transcode", "copy"): self = .transcodeVideo
            case ("transcode", "transcode"): self = .transcodeVideoAndAudio
            default: return nil
            }
        }
    }

    /// These describe observed recovery decisions, never a guessed root cause such as
    /// "slow Wi-Fi" or an arbitrary server error that might contain credentials.
    enum FallbackReason: Equatable {
        case none, serverStreamSelected, directPlayFailed, startupNoPicture, streamStalled, playerRetry, originalVideoRetry
        var message: String {
            switch self {
            case .originalVideoRetry: return "Original video retry requested. Server approved video copy."
            case .none: return "No fallback used."
            case .serverStreamSelected: return "Server streaming was selected for this source."
            case .directPlayFailed: return "Direct Play failed. Trying a server stream."
            case .startupNoPicture: return "No picture reached the startup deadline. Trying a different stream."
            case .streamStalled: return "Playback stopped making progress. Trying a different stream."
            case .playerRetry: return "The player could not open the stream. Retrying it once."
            }
        }
    }

    enum RecoveryRequest: Equatable {
        case compatibility1080p
        var label: String { "Compatibility retry, up to 1080p" }
    }

    struct Source: Equatable {
        let videoCodec: String
        let audioCodec: String

        init(videoCodec: String?, audioCodec: String?) {
            // Never echo unknown metadata. Even codec fields can contain arbitrary
            // server text; only fixed display labels cross this boundary.
            self.videoCodec = Self.codec(videoCodec, video: true)
            self.audioCodec = Self.codec(audioCodec, video: false)
        }

        private static func codec(_ value: String?, video: Bool) -> String {
            let key = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let known: [String: String] = video
                ? ["h264": "H.264", "avc": "H.264", "avc1": "H.264", "hevc": "HEVC", "h265": "HEVC", "hev1": "HEVC", "hvc1": "HEVC", "mpeg2video": "MPEG-2", "mpeg4": "MPEG-4", "av1": "AV1", "vp9": "VP9", "vc1": "VC-1"]
                : ["aac": "AAC", "ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS", "dca": "DTS", "truehd": "TrueHD", "flac": "FLAC", "alac": "ALAC", "mp3": "MP3", "opus": "Opus", "vorbis": "Vorbis", "pcm": "PCM"]
            return known[key] ?? "Unknown"
        }
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
    }

    let generation: Int
    let backend: Backend
    let qualityAtTune: StreamQuality
    let source: Source
    private(set) var delivery: Delivery = .unknown
    /// Set only when the server said which streams it copies or converts.
    private(set) var serverStream: ServerStream?
    private(set) var reason: FallbackReason = .none
    private(set) var recoveryRequest: RecoveryRequest?
    private(set) var isReady = false
    private(set) var attemptID: UUID?

    /// A retired player may stay installed during recovery negotiation. Its ready
    /// state and dimensions must not describe the replacement that is still loading.
    mutating func invalidateAttempt() {
        attemptID = nil
        isReady = false
    }

    /// A retry shares a load generation, so generation alone cannot distinguish an old
    /// ready callback from the replacement. Each attempt gets a separate owner token.
    @discardableResult
    mutating func beginAttempt(generation: Int, delivery: Delivery,
                               reason: FallbackReason = .none,
                               recoveryRequest: RecoveryRequest? = nil,
                               serverStream: ServerStream? = nil) -> UUID? {
        guard generation == self.generation else { return nil }
        let attempt = UUID()
        attemptID = attempt
        isReady = false
        self.delivery = delivery
        // A new attempt describes its own stream; a direct play has none.
        self.serverStream = delivery == .serverStream ? serverStream : nil
        self.reason = reason
        if let recoveryRequest { self.recoveryRequest = recoveryRequest }
        return attempt
    }

    @discardableResult
    mutating func markReady(generation: Int, attemptID: UUID?) -> Bool {
        guard generation == self.generation, let attemptID, attemptID == self.attemptID else { return false }
        isReady = true
        return true
    }

    func rows(presentationWidth: Double? = nil, presentationHeight: Double? = nil) -> [Row] {
        var rows = [
            Row(id: "backend", label: "BACKEND", value: backend.rawValue),
            Row(id: "delivery", label: "PLAYBACK", value: isReady ? deliveryLabel : "Loading"),
            Row(id: "quality", label: "QUALITY AT TUNE", value: qualityAtTune.displayName),
        ]
        if let recoveryRequest {
            rows.append(Row(id: "recovery", label: "RECOVERY REQUEST", value: recoveryRequest.label))
        }
        rows += [
            Row(id: "presentation", label: "PLAYER SIZE", value: isReady ? Self.sizeLabel(width: presentationWidth, height: presentationHeight) : "Unknown"),
            Row(id: "source", label: "SOURCE METADATA", value: "Video: \(source.videoCodec) · Audio: \(source.audioCodec)"),
            Row(id: "reason", label: "FALLBACK", value: reason.message),
        ]
        return rows
    }

    /// "Server stream" until the server has said which streams it copies or converts.
    private var deliveryLabel: String {
        delivery == .serverStream ? (serverStream?.label ?? delivery.label) : delivery.label
    }

    private static func sizeLabel(width: Double?, height: Double?) -> String {
        guard let width, let height, width.isFinite, height.isFinite,
              width >= 1, height >= 1, width <= 65_536, height <= 65_536 else { return "Unknown" }
        return "\(Int(width.rounded())) × \(Int(height.rounded()))"
    }

    var evidenceNote: String {
        "Source codecs come from library metadata. Player size is reported by AVPlayer. Quality is the selection at tune time, not a measured output. A server stream is shown as Remux or Transcode only when the server's own answer said which streams it copies or converts; otherwise it stays Server stream."
    }
}
