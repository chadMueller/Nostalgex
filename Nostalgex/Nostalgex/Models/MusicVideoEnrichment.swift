import Foundation

/// Metadata resolved outside Plex (MusicBrainz + local title parsing) for music-video items.
struct MusicVideoEnrichment: Codable, Sendable, Hashable {
    let ratingKey: String
    /// Song/recording title used for lookup (may differ from Plex `title` when parsed).
    let recordingTitle: String
    /// Primary artist when known (Plex field, parsed from title, or MusicBrainz).
    let artist: String?
    /// MusicBrainz recording MBID when a match was found.
    let musicBrainzID: String?
    /// Genres/tags for channel matching (mapped from MusicBrainz tags + artist tags).
    let genres: [String]
    /// Release year from MusicBrainz when Plex has none.
    let releaseYear: Int?
    let fetchedAt: Date
    /// Deezer track id when Deezer supplied genres. Optional so rows cached before
    /// Deezer existed still decode.
    var deezerID: Int? = nil
    /// When Deezer was last consulted for this row, matched or not. A row with an artist
    /// but no genres used to count as done; this is what lets it get its second pass.
    var deezerCheckedAt: Date? = nil

    var hasUsefulGenres: Bool {
        genres.contains { g in
            let l = g.lowercased()
            return !l.contains("music video") && l != "music" && l != "musical"
        }
    }
}

/// Heuristic parsing for common music-video filename / Plex title patterns.
enum MusicTitleParser {
    /// Strips trailing ` (YYYY)` Plex often appends.
    static func stripYearSuffix(_ title: String) -> String {
        title.replacingOccurrences(of: #" \(\d{4}\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `(1988)` a ripped filename carries. Measured 2026-10-07: the Plex year on
    /// Chad's music videos was 1970 (epoch) or the date added for most rows, and
    /// Deezer's year is the album's (remasters, compilations), so this suffix and the
    /// MusicBrainz first-release date are the only years the decade channels can trust.
    static func yearInTitle(_ raw: String) -> Int? {
        guard let m = raw.range(of: #"\(((?:19|20)\d\d)\)"#, options: .regularExpression) else { return nil }
        return Int(raw[m].dropFirst().dropLast())
    }

    /// Takes a ripped filename down to something a music service can search for.
    /// Measured on Chad's library 2026-10-07: underscores for spaces, `[MMV]` / `{smg}`
    /// tags, `(Shindig 1964)` notes, scene suffixes (`-vgb-prv`, `XviD`), and a stray
    /// "video!" were the reasons 13 of 60 titles found nothing; this recovered 10.
    static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "_", with: " ")
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\{[^}]*\}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\((?:19|20)\d\d\)\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\([^)]*(?:19|20)\d\d[^)]*\)"#, with: "", options: .regularExpression)
        // N-034: a bracket made only of YouTube-style noise words goes whole ("(Official Music Video)",
        // "(Official Video)", "(Lyrics)", "(HD)"); removing just the words used to leave "( Music )" and
        // "( )". The nine steps and the word lists are the same in the web tuner (`cleanTitle` in
        // nostalgex-music-brainz.js) and the Roku port, and `scripts/music-title-golden.json` holds all three.
        let noise = "official|music|video|audio|visualizer|lyrics?|remaster(?:ed)?|hd|hq|mv|4k|uhd|xvid|dvdrip|vgb|prv"
        t = t.replacingOccurrences(of: "(?i)\\(\\s*(?:\(noise))(?:[\\s,&/+-]+(?:\(noise)))*\\s*\\)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(official|video|hd|hq|lyrics?|remaster(?:ed)?|mv|xvid|dvdrip|vgb|prv)\b!?"#, with: "", options: .regularExpression)
        // Brackets the word strip emptied or left padded.
        t = t.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+\)"#, with: ")", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " -!."))
    }

    /// Drops featured artists: "Nelly ft. Akon ft. Ashanti" → "Nelly", "Airplanes ft. Hayley Williams" → "Airplanes".
    static func stripFeaturing(_ s: String, artistSide: Bool) -> String {
        let pattern = artistSide
            ? #"(?i)\s+(?:ft\.?|feat\.?|featuring|with|and the)\s+.*$"#
            : #"(?i)\s+(?:ft\.?|feat\.?|featuring)\s+.*$"#
        return s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    /// Returns `(artist, songTitle)` when the string looks like `Artist - Song`,
    /// `Artist-Song` or `Song by Artist`. The song is the first dash-separated part
    /// after the artist, so "Beatles - I'm A Loser - Boys" searches for I'm A Loser.
    static func parse(_ raw: String) -> (artist: String?, song: String) {
        let cleaned = clean(raw)
        if let sep = cleaned.range(of: " - ") {
            let artist = stripFeaturing(String(cleaned[..<sep.lowerBound]), artistSide: true)
            var song = String(cleaned[sep.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let next = song.range(of: " - ") { song = String(song[..<next.lowerBound]) }
            song = stripFeaturing(song, artistSide: false)
            if !artist.isEmpty, !song.isEmpty { return (artist, song) }
        }
        if let sep = cleaned.range(of: " by ", options: [.caseInsensitive, .backwards]) {
            let song = stripFeaturing(String(cleaned[..<sep.lowerBound]), artistSide: false)
            let artist = stripFeaturing(String(cleaned[sep.upperBound...]), artistSide: true)
            if !artist.isEmpty, !song.isEmpty { return (artist, song) }
        }
        // "Black eyed peas-shut up": a lone hyphen with letters on both sides.
        if let match = cleaned.range(of: #"^(.{2,}?)-(.+)$"#, options: .regularExpression),
           let dash = cleaned.range(of: "-", range: match) {
            let artist = stripFeaturing(String(cleaned[..<dash.lowerBound]), artistSide: true)
            let song = stripFeaturing(String(cleaned[dash.upperBound...]), artistSide: false)
            if artist.count >= 2, song.count >= 2, !artist.contains(" - ") { return (artist, song) }
        }
        return (nil, stripFeaturing(cleaned, artistSide: false))
    }
}

/// Which year a music video gets, in trust order: the year in its own filename, the
/// MusicBrainz first release, then Plex only when it is plausible. 1970 is Plex's
/// "unknown", and anything at or past the current year is the date it was added.
enum MusicYear {
    static func resolve(titleYear: Int?, musicBrainzYear: Int?, plexYear: Int?, now: Date = Date()) -> Int? {
        if let titleYear { return titleYear }
        if let musicBrainzYear { return musicBrainzYear }
        guard let plexYear else { return nil }
        let thisYear = Calendar.current.component(.year, from: now)
        return (plexYear > 1970 && plexYear < thisYear) ? plexYear : nil
    }
}
