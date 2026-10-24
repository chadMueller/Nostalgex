import Foundation

enum MediaType: String, Hashable {
    case movie
    case episode
}

enum LibrarySource: String, Hashable, Codable {
    case movie
    case tv
    case musicVideo
}

struct PlexPartPlaybackInfo: Codable, Hashable {
    let key: String
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let bitDepth: Int?
    let doviProfile: Int?
    var durationSeconds: Double? = nil
    var audioChannelCount: Int? = nil
    var doviCompatibilityID: Int? = nil
    var audioStreamID: Int? = nil
}

struct PlexMediaItem: Identifiable, Hashable {
    let id: String         // ratingKey
    let title: String
    /// Artist when Plex or title parsing provides it (music videos).
    let artist: String?
    let episodeTitle: String?
    let seTag: String?     // e.g. "S01E04"
    let summary: String
    let year: Int?
    let originallyAvailableAt: String? // YYYY-MM-DD from Plex; more precise than year
    let contentRating: String?
    let duration: Int      // minutes
    let ratingKey: String
    let partKey: String?
    let container: String? // "mp4", "mkv", etc.
    let videoCodec: String?  // "h264", "hevc", "mpeg4", "vp9", etc.
    let audioCodec: String?  // "aac", "ac3", "eac3", "dts", "truehd", etc.
    let videoProfile: String? // "main", "high", "main 10", etc.
    let bitrate: Int?        // kbps
    let genres: [String]
    let rating: Double
    let userRating: Double
    let type: MediaType
    let thumb: String?     // relative path, e.g. /library/metadata/123/thumb/...
    let art: String?
    let viewCount: Int
    let addedAt: Int
    let studio: String?
    let tmdbID: String?    // extracted from Plex GUID (tmdb://12345)
    let imdbID: String?    // extracted from Plex GUID (imdb://tt1234567)
    // Optional so existing cached snapshots still decode. Nil treated as .movie.
    let librarySource: LibrarySource?
    // Machine identifier of the Plex server this item came from. Optional so older
    // single-server snapshots still decode; nil routes playback to the primary server.
    var serverID: String? = nil
    // Additional Plex part keys for multi-disc movies (disc 2, disc 3, …).
    // When set, Nostalgex plays each part consecutively before advancing to the next
    // scheduled item. Nil for single-file items (the common case).
    var additionalPartKeys: [String]? = nil
    // Video stream facts a codec name alone does not carry. 10-bit H.264 has no decoder on
    // any Apple device (black picture, sound plays), and Dolby Vision profile 7 is a
    // dual-layer format AVPlayer cannot render. Optional so older snapshots still decode.
    var videoBitDepth: Int? = nil
    var doviProfile: Int? = nil
    var videoWidth: Int? = nil
    var videoHeight: Int? = nil
    var mediaIndex: Int = 0
    var partIndex: Int = 0
    var playbackParts: [PlexPartPlaybackInfo]? = nil
    var exactDurationSeconds: Double? = nil
    /// Episodes only: the server-local id of the show (Plex `grandparentRatingKey`,
    /// Jellyfin and Emby `SeriesId`). A collection of shows lists the shows, not their
    /// episodes, so this is what lets the collection scan expand a show into the
    /// episodes the library load already holds. Optional so older snapshots still
    /// decode; nil until the next full library scan.
    var showKey: String? = nil
    var audioChannelCount: Int? = nil
    var doviCompatibilityID: Int? = nil
    var audioStreamID: Int? = nil
}

extension PlexMediaItem {
    // Returns a copy of this item with the given partKey substituted.
    // Used to play disc 2, disc 3, etc. of a multi-part movie without
    // creating a full new scheduled entry.
    func withPartKey(_ key: String) -> PlexMediaItem {
        let part = playbackParts?.first { $0.key == key }
        return PlexMediaItem(
            id: id, title: title, artist: artist, episodeTitle: episodeTitle,
            seTag: seTag, summary: summary, year: year,
            originallyAvailableAt: originallyAvailableAt,
            contentRating: contentRating, duration: duration,
            ratingKey: ratingKey, partKey: key,
            container: part?.container ?? container, videoCodec: part?.videoCodec ?? videoCodec, audioCodec: part?.audioCodec ?? audioCodec,
            videoProfile: videoProfile, bitrate: bitrate, genres: genres,
            rating: rating, userRating: userRating, type: type,
            thumb: thumb, art: art, viewCount: viewCount, addedAt: addedAt,
            studio: studio, tmdbID: tmdbID, imdbID: imdbID,
            librarySource: librarySource, serverID: serverID,
            additionalPartKeys: additionalPartKeys,
            videoBitDepth: part == nil ? videoBitDepth : part?.bitDepth, doviProfile: part == nil ? doviProfile : part?.doviProfile,
            videoWidth: videoWidth, videoHeight: videoHeight,
            mediaIndex: mediaIndex, partIndex: (additionalPartKeys?.firstIndex(of: key).map { $0 + 1 }) ?? partIndex,
            playbackParts: playbackParts, exactDurationSeconds: exactDurationSeconds,
            showKey: showKey,
            audioChannelCount: part == nil ? audioChannelCount : part?.audioChannelCount,
            doviCompatibilityID: part == nil ? doviCompatibilityID : part?.doviCompatibilityID,
            audioStreamID: part == nil ? audioStreamID : part?.audioStreamID
        )
    }

    /// Translate the schedule's whole-film offset only when the server knows every part length.
    func playbackPosition(at seconds: Int) -> (item: PlexMediaItem, baseSeconds: Double, offsetSeconds: Int) {
        guard let parts = playbackParts, parts.count > 1,
              parts.allSatisfy({ ($0.durationSeconds ?? 0).isFinite && ($0.durationSeconds ?? 0) > 0 })
        else { return (self, 0, max(0, seconds)) }
        var base: Double = 0
        for (index, part) in parts.enumerated() {
            let duration = part.durationSeconds!
            if Double(seconds) < base + duration || index == parts.count - 1 {
                var selected = withPartKey(part.key)
                selected.partIndex = index
                let offset = min(max(0, Double(seconds) - base), max(0, duration - 1))
                return (selected, base, Int(offset))
            }
            base += duration
        }
        return (self, 0, max(0, seconds))
    }

}

extension MediaType: Codable {}

extension PlexMediaItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, artist, episodeTitle, seTag, summary, year, originallyAvailableAt
        case audioChannelCount, doviCompatibilityID, audioStreamID
        case contentRating, duration, ratingKey, partKey, container, videoCodec, audioCodec
        case videoProfile, bitrate, genres, rating, userRating, type, thumb, art
        case viewCount, addedAt, studio, tmdbID, imdbID, librarySource, serverID
        case additionalPartKeys
        case videoBitDepth, doviProfile, videoWidth, videoHeight, mediaIndex, partIndex, playbackParts, exactDurationSeconds
        case showKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle)
        seTag = try c.decodeIfPresent(String.self, forKey: .seTag)
        summary = try c.decode(String.self, forKey: .summary)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        originallyAvailableAt = try c.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        duration = try c.decode(Int.self, forKey: .duration)
        ratingKey = try c.decode(String.self, forKey: .ratingKey)
        partKey = try c.decodeIfPresent(String.self, forKey: .partKey)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec)
        videoProfile = try c.decodeIfPresent(String.self, forKey: .videoProfile)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        genres = try c.decode([String].self, forKey: .genres)
        rating = try c.decode(Double.self, forKey: .rating)
        userRating = try c.decode(Double.self, forKey: .userRating)
        type = try c.decode(MediaType.self, forKey: .type)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        art = try c.decodeIfPresent(String.self, forKey: .art)
        viewCount = try c.decode(Int.self, forKey: .viewCount)
        addedAt = try c.decode(Int.self, forKey: .addedAt)
        studio = try c.decodeIfPresent(String.self, forKey: .studio)
        tmdbID = try c.decodeIfPresent(String.self, forKey: .tmdbID)
        imdbID = try c.decodeIfPresent(String.self, forKey: .imdbID)
        librarySource = try c.decodeIfPresent(LibrarySource.self, forKey: .librarySource)
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID)
        additionalPartKeys = try c.decodeIfPresent([String].self, forKey: .additionalPartKeys)
        videoBitDepth = try c.decodeIfPresent(Int.self, forKey: .videoBitDepth)
        doviProfile = try c.decodeIfPresent(Int.self, forKey: .doviProfile)
        audioChannelCount = try c.decodeIfPresent(Int.self, forKey: .audioChannelCount)
        doviCompatibilityID = try c.decodeIfPresent(Int.self, forKey: .doviCompatibilityID)
        audioStreamID = try c.decodeIfPresent(Int.self, forKey: .audioStreamID)
        videoWidth = try c.decodeIfPresent(Int.self, forKey: .videoWidth)
        videoHeight = try c.decodeIfPresent(Int.self, forKey: .videoHeight)
        mediaIndex = try c.decodeIfPresent(Int.self, forKey: .mediaIndex) ?? 0
        partIndex = try c.decodeIfPresent(Int.self, forKey: .partIndex) ?? 0
        playbackParts = try c.decodeIfPresent([PlexPartPlaybackInfo].self, forKey: .playbackParts)
        exactDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .exactDurationSeconds)
        showKey = try c.decodeIfPresent(String.self, forKey: .showKey)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(artist, forKey: .artist)
        try c.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try c.encodeIfPresent(seTag, forKey: .seTag)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(originallyAvailableAt, forKey: .originallyAvailableAt)
        try c.encodeIfPresent(contentRating, forKey: .contentRating)
        try c.encode(duration, forKey: .duration)
        try c.encode(ratingKey, forKey: .ratingKey)
        try c.encodeIfPresent(partKey, forKey: .partKey)
        try c.encodeIfPresent(container, forKey: .container)
        try c.encodeIfPresent(videoCodec, forKey: .videoCodec)
        try c.encodeIfPresent(audioCodec, forKey: .audioCodec)
        try c.encodeIfPresent(videoProfile, forKey: .videoProfile)
        try c.encodeIfPresent(bitrate, forKey: .bitrate)
        try c.encode(genres, forKey: .genres)
        try c.encode(rating, forKey: .rating)
        try c.encode(userRating, forKey: .userRating)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(thumb, forKey: .thumb)
        try c.encodeIfPresent(art, forKey: .art)
        try c.encode(viewCount, forKey: .viewCount)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(studio, forKey: .studio)
        try c.encodeIfPresent(tmdbID, forKey: .tmdbID)
        try c.encodeIfPresent(imdbID, forKey: .imdbID)
        try c.encodeIfPresent(librarySource, forKey: .librarySource)
        try c.encodeIfPresent(serverID, forKey: .serverID)
        try c.encodeIfPresent(additionalPartKeys, forKey: .additionalPartKeys)
        try c.encodeIfPresent(videoBitDepth, forKey: .videoBitDepth)
        try c.encodeIfPresent(doviProfile, forKey: .doviProfile)
        try c.encodeIfPresent(audioChannelCount, forKey: .audioChannelCount)
        try c.encodeIfPresent(doviCompatibilityID, forKey: .doviCompatibilityID)
        try c.encodeIfPresent(audioStreamID, forKey: .audioStreamID)
        try c.encodeIfPresent(videoWidth, forKey: .videoWidth)
        try c.encodeIfPresent(videoHeight, forKey: .videoHeight)
        try c.encode(mediaIndex, forKey: .mediaIndex)
        try c.encode(partIndex, forKey: .partIndex)
        try c.encodeIfPresent(playbackParts, forKey: .playbackParts)
        try c.encodeIfPresent(exactDurationSeconds, forKey: .exactDurationSeconds)
        try c.encodeIfPresent(showKey, forKey: .showKey)
    }
}
