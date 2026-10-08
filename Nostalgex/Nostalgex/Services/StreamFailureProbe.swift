import Foundation

/// Asks the server directly why a stream would not play.
///
/// AVFoundation does not hand back the HTTP status of a failed HLS request. On tvOS,
/// `AVPlayerItemErrorLogEvent` carries `errorStatusCode` (a CoreMedia code such as -15628),
/// `errorDomain` and a free-text `errorComment`, and no status field, so "your server
/// answered 500" cannot be read out of the player. Without it the app can only say
/// "playback error", which is the sentence that sends someone to re-encode a file when
/// their server is broken.
///
/// So the app asks. One range-limited GET against the URL that just failed returns the
/// real status, and it returns it fast: measured against an Emby server that could not
/// transcode two 4K HDR10 files, the 500 came back in 0.12s while ordinary titles on the
/// same server were fine. That is a definitive answer for the price of one request, taken
/// only on the failure path where there is nothing left to lose.
enum StreamFailureProbe {

    /// The HTTP status the server gives for this URL now, or nil if nothing answered.
    ///
    /// `Range: bytes=0-1` so a working stream costs two bytes rather than a segment, and a
    /// short timeout so a dead server does not hold the channel. Never throws: a probe that
    /// cannot answer leaves the classification to the player's own signals.
    static func status(of url: URL, headers: [String: String] = [:],
                       timeout: TimeInterval = 5,
                       session: URLSession = .shared) async -> Int? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    /// Whether a status is worth reporting as "the server said no".
    ///
    /// 206 is the expected answer to a ranged request and 200 means the server is serving
    /// this URL happily, so neither tells the user anything: if the stream still failed,
    /// the fault is on this side and the player's own signals should classify it.
    static func isRefusal(_ status: Int) -> Bool { status >= 400 }
}
