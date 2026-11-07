import Foundation

/// Decides which analytics events actually leave the device.
///
/// TelemetryDeck counts (and bills) every signal. Before this gate the app sent signals
/// at the rate the viewer used the remote: every channel change sent `channel.tuned`,
/// a `playback.stopped` for the channel being left and a `playback.ready` for the one
/// arriving, and every programme boundary sent another stopped/ready pair. A channel
/// whose items all failed sent `playback.error` every few seconds for as long as the TV
/// stayed on. Usage grew with the 2026-10-14 launch and the signal count grew with it.
///
/// Every rule below works per *session*: one foreground visit, closed by
/// `app.session.ended`. An Apple TV left playing never goes to the background, so a
/// session longer than `windowSeconds` gets a fresh allowance each window.
///
/// - High-rate signals are sent the first time each kind happens in a session (one
///   `playback.error` per backend and code, one `playback.ready` per backend and
///   delivery, one `channel.tuned` per backend and method), then only counted.
/// - `playback.stopped` is merged per channel stay: programme boundaries on the same
///   channel add up into one signal, and stays shorter than `minStaySeconds` (surfing)
///   are dropped. The summed watch time per channel survives.
/// - Every signal name has a ceiling and the window has one overall, so a loop nobody
///   has found yet cannot run up the bill.
/// - `app.session.ended` always goes out and carries the session's counts (tunes,
///   playback starts, errors, signals held back) so nothing is lost from the totals.
///
/// A plain value type with the clock passed in, so the caps are tested without timers.
struct AnalyticsGate {
    struct Limits: Sendable {
        /// Allowance reset for sessions that never background (TV left on overnight).
        var windowSeconds: TimeInterval = 4 * 3600
        /// Most signals one window may send, whatever their names. Backstop only: the
        /// per-name rules below stay well under it in normal use.
        var perWindow: Int = 60
        /// A channel stay shorter than this is surfing, not watching, and is not sent.
        var minStaySeconds: Double = 60
        /// Most merged `playback.stopped` signals per window.
        var stopsPerWindow: Int = 12

        static let standard = Limits()
    }

    /// How one signal name is thinned. `identity` lists the parameters that make two
    /// events "the same kind" (empty = the name alone, nil = every parameter); only the
    /// first of each kind per window is sent. `limit` caps the name per window.
    struct Rule: Equatable {
        let identity: [String]?
        let limit: Int
    }

    /// The policy table. `nil` means the signal always goes out.
    static func rule(for name: String) -> Rule? {
        switch name {
        case "app.launch", "app.session.ended":
            return nil
        case "channel.tuned":
            return Rule(identity: ["backend", "method"], limit: 4)
        case "playback.ready":
            return Rule(identity: ["backend", "delivery"], limit: 4)
        case "playback.error":
            return Rule(identity: ["backend", "code"], limit: 6)
        case "playback.transcode_fallback":
            return Rule(identity: ["backend"], limit: 2)
        case "setting.changed":
            return Rule(identity: nil, limit: 20)
        case "rate.tapped", "rate.opened", "rating_nudge.shown", "rating_nudge.tapped", "rating_nudge.opened", "signup.qr.shown",
             "library.load.empty", "library.load.stop_waiting_tapped":
            return Rule(identity: [], limit: 1)
        default:
            // connect.*, credentials.*, library.*, and anything added later.
            return Rule(identity: nil, limit: 5)
        }
    }

    let limits: Limits

    private var windowStart: Date?
    private var seenKinds: Set<String> = []
    private var sentByName: [String: Int] = [:]
    private var sentInWindow = 0
    private var stopsInWindow = 0
    /// The current channel stay, held until the viewer leaves it or the session ends.
    private var heldStop: (event: AnalyticsEvent, kind: String, seconds: Double)?
    private var summary = AnalyticsSessionSummary()

    init(limits: Limits = .standard) {
        self.limits = limits
    }

    /// Takes one event and returns what to send now: usually zero or one event, two
    /// when a held `playback.stopped` is released alongside it.
    mutating func admit(_ event: AnalyticsEvent, at now: Date) -> [AnalyticsEvent] {
        var out: [AnalyticsEvent] = []
        if let start = windowStart, now.timeIntervalSince(start) >= limits.windowSeconds {
            releaseHeldStop(into: &out)
            startWindow(at: now)
        } else if windowStart == nil {
            startWindow(at: now)
        }
        summary.observe(event)

        switch event {
        case .sessionEnded(let seconds, _):
            releaseHeldStop(into: &out)
            out.append(.sessionEnded(activeSeconds: seconds, summary: summary))
            self = AnalyticsGate(limits: limits)

        case .playbackStopped(_, _, _, _, let seconds):
            let kind = Self.kind(of: event, identity: nil)
            if let held = heldStop, held.kind == kind {
                heldStop = (held.event, kind, held.seconds + seconds)
            } else {
                releaseHeldStop(into: &out)
                heldStop = (event, kind, seconds)
            }

        default:
            if admitByRule(event) {
                out.append(event)
            } else {
                summary.suppressed += 1
            }
        }
        return out
    }

    // MARK: - Private

    private mutating func startWindow(at now: Date) {
        windowStart = now
        seenKinds = []
        sentByName = [:]
        sentInWindow = 0
        stopsInWindow = 0
    }

    private mutating func admitByRule(_ event: AnalyticsEvent) -> Bool {
        guard let rule = Self.rule(for: event.name) else { return true }
        let kind = Self.kind(of: event, identity: rule.identity)
        guard !seenKinds.contains(kind),
              sentByName[event.name, default: 0] < rule.limit,
              sentInWindow < limits.perWindow else { return false }
        seenKinds.insert(kind)
        sentByName[event.name, default: 0] += 1
        sentInWindow += 1
        return true
    }

    /// Sends the held channel stay if it was long enough to be watching and there is
    /// room for it; otherwise counts it as held back.
    private mutating func releaseHeldStop(into out: inout [AnalyticsEvent]) {
        guard let held = heldStop else { return }
        heldStop = nil
        guard held.seconds >= limits.minStaySeconds,
              stopsInWindow < limits.stopsPerWindow,
              sentInWindow < limits.perWindow,
              case let .playbackStopped(number, backend, delivery, channel, _) = held.event else {
            summary.suppressed += 1
            return
        }
        stopsInWindow += 1
        sentInWindow += 1
        out.append(.playbackStopped(channelNumber: number, backend: backend, delivery: delivery,
                                    channel: channel, activeWatchSeconds: held.seconds))
    }

    /// `name|key=value|...` over the identity parameters, in a fixed order.
    static func kind(of event: AnalyticsEvent, identity: [String]?) -> String {
        let params = event.parameters
        let keys = identity ?? params.keys.sorted()
        return ([event.name] + keys.map { "\($0)=\(params[$0] ?? "")" }).joined(separator: "|")
    }
}

/// Counts for one session, sent as parameters on `app.session.ended`. Counts go out as
/// coarse buckets: they are for "how many sessions surf heavily" charts, and a bucket
/// says nothing more precise about one household than it needs to.
struct AnalyticsSessionSummary: Sendable, Equatable {
    var tunes = 0
    var playbackStarts = 0
    var playbackErrors = 0
    /// Signals the gate counted but did not send.
    var suppressed = 0
    /// The last backend any event this session named. Nil for a session that never
    /// touched one (Settings only, or signed out).
    var backend: String?

    mutating func observe(_ event: AnalyticsEvent) {
        switch event {
        case .channelTuned(_, let backend, _, _):
            tunes += 1; self.backend = backend.rawValue
        case .playbackReady(_, let backend, _, _):
            playbackStarts += 1; self.backend = backend.rawValue
        case .playbackError(_, let backend, _):
            playbackErrors += 1; self.backend = backend.rawValue
        default:
            if let backend = event.parameters["backend"] { self.backend = backend }
        }
    }

    var wireParameters: [String: String] {
        var params = [
            "tunes": Self.bucket(tunes),
            "playbackStarts": Self.bucket(playbackStarts),
            "playbackErrors": Self.bucket(playbackErrors),
            "suppressed": Self.bucket(suppressed),
        ]
        if let backend { params["backend"] = backend }
        return params
    }

    static func bucket(_ n: Int) -> String {
        switch n {
        case ..<1: return "0"
        case 1: return "1"
        case 2...5: return "2-5"
        case 6...20: return "6-20"
        case 21...50: return "21-50"
        case 51...200: return "51-200"
        default: return "201+"
        }
    }
}
