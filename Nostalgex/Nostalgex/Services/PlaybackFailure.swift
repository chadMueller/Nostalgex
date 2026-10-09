import Foundation

/// Why a scheduled programme could not be played, in words a person can act on.
///
/// The app used to skip a failed programme in silence. From the couch that is
/// indistinguishable from a broken app, and it is the wrong conclusion: the three common
/// causes are a server that refuses the job, a server that cannot keep up, and a file the
/// Apple TV cannot render, and the user can only fix the first two if they are told which
/// one happened.
///
/// The case that prompted this: an Emby server answered HTTP 500 in 0.12s for every
/// transcode of two 4K HDR10 files, at every resolution and codec asked of it, while
/// ordinary files on the same server transcoded at 3x real time. Nothing the app could
/// change would have played them, and nothing the app showed said so.
///
/// Pure value type. `classify` takes only what the player observed, so the mapping is
/// unit-testable without a server, a player, or a screen.
enum PlaybackFailure: Equatable, Sendable {

    /// The server answered the request and said no. `status` is the HTTP code.
    case serverRefused(server: String, status: Int)
    /// The server does not have the file it told us about.
    case fileMissing(server: String)
    /// The server rejected our credentials.
    case notAuthorised(server: String)
    /// The server tried, and could not produce video fast enough to watch, even reduced.
    case serverTooSlow(server: String)
    /// Nothing answered at the address.
    case serverUnreachable(server: String)
    /// Bytes arrived, the device could not turn them into a picture.
    case deviceCannotRender(codec: String?)
    /// Nothing in the library row gave us a URL to open.
    case noPlayableSource(server: String)
    /// The server will not convert this title and the device cannot take it as it stands.
    case transcodingUnavailable(server: String)
    /// Something failed and the signals do not say what.
    case unknown(server: String)

    // MARK: - Classification

    /// What the player saw, gathered at the moment the app gave up on an item.
    struct Evidence: Equatable, Sendable {
        /// HTTP statuses from `AVPlayerItemErrorLogEvent.httpStatusCode`, positive ones only.
        /// A value of -1 means the event was not an HTTP failure and must be filtered out
        /// before it gets here.
        var httpStatuses: [Int] = []
        /// `AVPlayerItemErrorLogEvent.errorStatusCode`, which carries CoreMedia codes such
        /// as -15628 (segment abandoned).
        var coreMediaStatuses: [Int] = []
        var urlErrorCode: Int?
        /// True once the starvation ladder has already dropped to its lowest rung and the
        /// stream starved again. Decisive on its own: the server answered, it just lost.
        var starvedAfterCappedRetry: Bool = false
        /// Whether a frame ever reached the screen for this item.
        var everShowedPicture: Bool = false
        /// Source video codec, for the message when the device is the limit.
        var sourceCodec: String?
        /// Whether any frame reached the screen for this item. A decoded frame is proof the
        /// device can decode the stream, so it vetoes `deviceCannotRender` outright even
        /// when the playhead never advanced.
        var decodedAFrame: Bool = false
        /// Whether the server actually delivered media for this item.
        var serverDeliveredBytes: Bool = false
    }

    /// Order matters. A server that answered with an error is a more specific and more
    /// actionable fact than a device that then failed to decode nothing, so HTTP statuses
    /// are read before decode failures. Starvation outranks everything because it is the
    /// one case where the server answered correctly and still could not be watched.
    static func classify(backend: MediaBackendKind, evidence e: Evidence) -> PlaybackFailure {
        let server = backend.displayName

        if e.starvedAfterCappedRetry { return .serverTooSlow(server: server) }

        let statuses = e.httpStatuses.filter { $0 > 0 }
        if statuses.contains(401) || statuses.contains(403) {
            return .notAuthorised(server: server)
        }
        if statuses.contains(404) { return .fileMissing(server: server) }
        if let bad = statuses.first(where: { $0 >= 400 }) {
            return .serverRefused(server: server, status: bad)
        }

        if let code = e.urlErrorCode, Self.unreachableURLErrorCodes.contains(code) {
            return .serverUnreachable(server: server)
        }

        // These two CoreMedia codes mean the media did not arrive in time, not that it
        // could not be decoded: -12889 is "no response for media file in 3s" and -15628 is
        // a segment abandoned for being too slow. Measured 2026-10-08 on an Apple TV HD,
        // which has no HEVC decoder and so forces the server into a full HEVC to h264
        // re-encode: the server held 1.07x at the 4K ceiling and 1.28x at the 1080p rung,
        // with a 2.1 to 2.7s first segment against CoreMedia's 3s patience. The same file
        // for a client that accepts HEVC is a remux at 17.3x. Nothing was undecodable; it
        // was late.
        if e.coreMediaStatuses.contains(where: Self.deliveryTooSlowCodes.contains) {
            return .serverTooSlow(server: server)
        }

        // Bytes arrived and no picture came of them. A frame that did decode is proof the
        // device can handle the stream, so it vetoes this outright: without that check a
        // stream that decoded one frame and then starved was reported as "Apple TV
        // couldn't play this file", which blames the wrong thing entirely.
        if !e.everShowedPicture, !e.decodedAFrame, !e.coreMediaStatuses.isEmpty {
            return .deviceCannotRender(codec: e.sourceCodec)
        }

        // The server answered, kept answering, and the picture still never moved.
        if !e.everShowedPicture, e.serverDeliveredBytes {
            return .serverTooSlow(server: server)
        }

        return .unknown(server: server)
    }

    /// CoreMedia codes that mean the media was late rather than unplayable.
    /// -12889: no response for a media file within 3s. -15628: segment abandoned.
    private static let deliveryTooSlowCodes: Set<Int> = [-12889, -15628]

    /// `URLError.Code` raw values that mean nothing answered. Spelled as integers so the
    /// type stays free of Foundation networking at the point of use.
    private static let unreachableURLErrorCodes: Set<Int> = [
        URLError.cannotFindHost.rawValue,
        URLError.cannotConnectToHost.rawValue,
        URLError.dnsLookupFailed.rawValue,
        URLError.networkConnectionLost.rawValue,
        URLError.notConnectedToInternet.rawValue,
        URLError.timedOut.rawValue,
    ]

    // MARK: - What the screen says

    /// One short line, the size a person reads from a sofa.
    var headline: String {
        switch self {
        case .serverRefused:      return "Your server wouldn't start this one"
        case .fileMissing:        return "Your server can't find this file"
        case .notAuthorised:      return "Your server refused the request"
        case .serverTooSlow:      return "Your server couldn't keep up"
        case .serverUnreachable:  return "Can't reach your server"
        case .deviceCannotRender: return "Apple TV couldn't play this file"
        case .noPlayableSource:   return "Nothing to play for this title"
        case .transcodingUnavailable: return "Your server won't convert this one"
        case .unknown:            return "This one wouldn't play"
        }
    }

    /// The sentence that tells them whose problem it is and what to do about it. Says
    /// "the server, not the file" explicitly where that is the useful distinction, because
    /// the natural assumption from the couch is that the app is broken.
    var detail: String {
        switch self {
        case let .serverRefused(server, status):
            return "\(server) answered HTTP \(status) before it started sending video. "
                 + "That's the server, not this file and not your network. "
                 + "Other titles on the same server are unaffected."
        case let .fileMissing(server):
            return "\(server) listed this title but couldn't open the file. "
                 + "It was probably moved or deleted since the last library scan."
        case let .notAuthorised(server):
            return "\(server) rejected the sign-in saved on this device. "
                 + "Open Settings and reconnect."
        case let .serverTooSlow(server):
            return "\(server) couldn't produce video fast enough to watch, even after "
                 + "dropping to 1080p. The file is probably too heavy for it to convert."
        case let .serverUnreachable(server):
            return "Nothing answered at the address saved for your \(server) server. "
                 + "Check it's awake and on the same network."
        case let .deviceCannotRender(codec):
            let what = codec.map { "This \($0.uppercased()) file" } ?? "This file"
            return "\(what) arrived, but Apple TV couldn't turn it into a picture. "
                 + "The server sent it in a format this device can't decode."
        case let .noPlayableSource(server):
            return "\(server) listed this title but gave no stream to open. "
                 + "A library rescan in Settings usually clears it."
        case let .transcodingUnavailable(server):
            return "\(server) won't convert this title, and Apple TV can't play it as it is. "
                 + "Check that transcoding is enabled on the server."
        case let .unknown(server):
            return "No reason came back from \(server) or from the player. "
                 + "Settings keeps the last few playback verdicts if it keeps happening."
        }
    }

    /// Short form for `PlaybackDiagnostics` and the Settings row.
    var diagnosticSummary: String {
        switch self {
        case let .serverRefused(server, status): return "\(server) HTTP \(status), refused before video"
        case let .fileMissing(server):           return "\(server) HTTP 404, file not on disk"
        case let .notAuthorised(server):         return "\(server) rejected credentials"
        case let .serverTooSlow(server):         return "\(server) below real time on the capped stream"
        case let .serverUnreachable(server):     return "\(server) unreachable"
        case let .deviceCannotRender(codec):     return "device could not decode \(codec ?? "the stream")"
        case let .noPlayableSource(server):      return "\(server) returned no stream URL"
        case let .transcodingUnavailable(server): return "\(server) declined to transcode"
        case let .unknown(server):               return "\(server) failed with no usable signal"
        }
    }

    /// The analytics code that goes with this failure, so the wire signal and the words on
    /// screen can never drift apart.
    var analyticsCode: AnalyticsPlaybackErrorCode {
        switch self {
        case .noPlayableSource:       return .noPlayableSource
        case .transcodingUnavailable: return .transcodingUnavailable
        case .serverTooSlow:          return .watchdogSkip
        default:                      return .playerFailed
        }
    }

    /// Whether the fault lies with the server. Drives nothing today beyond wording, but it
    /// is the question every support thread opens with.
    var isServerSide: Bool {
        switch self {
        case .deviceCannotRender, .unknown: return false
        default: return true
        }
    }
}
