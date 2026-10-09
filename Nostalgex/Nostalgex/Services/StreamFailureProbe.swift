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

    /// Follows an HLS playlist down to real media and reports the first refusal it meets.
    ///
    /// Asking the master playlist alone proves nothing. A server that cannot build the
    /// transcode still serves the master and the variant happily and only fails when the
    /// first segment is demanded: measured 2026-10-08 against Emby, master 200, variant
    /// 200, segment 0 **500**. A probe that stopped at the master reported "no reason came
    /// back" for a server that was refusing every segment.
    ///
    /// At most three hops (master, variant, segment), each with its own timeout, and only
    /// ever on the failure path where the programme is already lost.
    static func refusalStatus(of url: URL, headers: [String: String] = [:],
                              timeout: TimeInterval = 5,
                              session: URLSession = .shared) async -> Int? {
        var current = url
        var last: Int?
        for hop in 0..<3 {
            let isPlaylist = current.pathExtension.lowercased() == "m3u8"
            let (status, body) = await fetch(current, headers: headers, wantBody: isPlaylist,
                                             timeout: timeout, session: session)
            // Every hop is logged so a walk that stops short can be read off a device.
            InstallDiagnostics.note("FAILURE PROBE hop \(hop): \(current.lastPathComponent) -> "
                + (status.map(String.init) ?? "no answer")
                + (isPlaylist ? " (playlist, \(body?.count ?? 0) chars)" : " (media)"))
            guard let status else { return last }
            last = status
            if isRefusal(status) { return status }
            guard isPlaylist, let body,
                  let next = firstMediaURL(inPlaylist: body, relativeTo: current) else { return last }
            current = next
        }
        return last
    }

    /// First non-comment line of an m3u8, resolved against the playlist's own URL. That is
    /// the next variant for a master playlist and the first segment for a media playlist,
    /// which is exactly the walk this needs. Relative, because Emby writes segment URIs
    /// relative to the playlist and repeats its query string on each one.
    static func firstMediaURL(inPlaylist text: String, relativeTo base: URL) -> URL? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return URL(string: line, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    private static func fetch(_ url: URL, headers: [String: String], wantBody: Bool,
                              timeout: TimeInterval, session: URLSession) async -> (Int?, String?) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        // A playlist has to arrive whole; only media is worth truncating.
        if !wantBody { req.setValue("bytes=0-1", forHTTPHeaderField: "Range") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode
            return (status, wantBody ? String(data: data, encoding: .utf8) : nil)
        } catch {
            return (nil, nil)
        }
    }
}
