import Foundation

/// Which image the Now Playing poster asks for, in order (#312). A movie has one: its poster. A TV episode's own
/// `thumb` is a frame grabbed from the episode, landscape and arbitrary, so it comes last: the season's poster
/// first, then the series poster, and the frame only when neither loads. Plex only, like the poster itself.
///
/// The paths are library image paths for the server's thumbnail transcode. They are derived from keys the item
/// already holds (`parentRatingKey`, `showKey`), so no extra request is made to find them, and an item restored
/// from an older snapshot, which lacks the keys, simply has a shorter list.
enum PlexPosterChain {
    static func paths(for item: PlexMediaItem) -> [String] {
        var paths: [String] = []
        if item.type == .episode {
            if let season = item.parentRatingKey, !season.isEmpty { paths.append("/library/metadata/\(season)/thumb") }
            if let show = item.showKey, !show.isEmpty { paths.append("/library/metadata/\(show)/thumb") }
        }
        if let own = item.thumb, !own.isEmpty, !paths.contains(own) { paths.append(own) }
        return paths
    }
}
