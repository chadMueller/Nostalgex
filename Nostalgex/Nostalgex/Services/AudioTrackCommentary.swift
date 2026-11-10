import Foundation

/// A director's or cast commentary is an audio track a channel should never start on when
/// the file has another. Servers name it in the track title ("Commentary", "Director's
/// Commentary", "Audio Commentary with ...") and often flag it as the default or give it the
/// viewer's language, so a language match alone lands on it (I-075, #153).
enum AudioTrackCommentary {
    /// True when any of the track's titles says "commentary", whatever the case.
    static func isCommentary(_ titles: String?...) -> Bool {
        titles.contains { ($0 ?? "").range(of: "commentary", options: .caseInsensitive) != nil }
    }

    /// `items` without the commentary ones, unless that would leave nothing: a file whose
    /// only audio is a commentary still plays it. Order is kept.
    static func skippingCommentary<T>(_ items: [T], titles: (T) -> [String?]) -> [T] {
        let rest = items.filter { !titles($0).contains { isCommentary($0) } }
        return rest.isEmpty ? items : rest
    }
}
