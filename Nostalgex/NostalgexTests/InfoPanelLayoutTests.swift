import XCTest
@testable import Nostalgex

/// The guide's info panel (top left of the guide): channel line, title, then the badges, then the description, then the
/// progress bar, then UP NEXT. The description used to sit above the badges and took no room when a programme had none,
/// so everything under it moved from one programme to the next.
final class InfoPanelLayoutTests: XCTestCase {

    private func item(type: MediaType = .movie, source: LibrarySource = .movie, summary: String, artist: String? = nil,
                      genres: [String] = ["Action"], episodeTitle: String? = nil, seTag: String? = nil,
                      year: Int? = 1989, rating: Double = 7.5, certificate: String? = "PG-13") -> PlexMediaItem {
        PlexMediaItem(
            id: "x", title: "Title", artist: artist, episodeTitle: episodeTitle, seTag: seTag, summary: summary,
            year: year, originallyAvailableAt: nil, contentRating: certificate, duration: 90, ratingKey: "x", partKey: nil,
            container: nil, videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil, genres: genres,
            rating: rating, userRating: 0, type: type, thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil,
            tmdbID: nil, imdbID: nil, librarySource: source)
    }

    /// Badges, then the description, then the progress bar, then UP NEXT, for a film, an episode and a music video.
    func testTheDescriptionComesAfterTheBadgesAndBeforeTheProgress() {
        let film = InfoPanelLayout.sections(for: item(summary: "A film."), hasUpNext: true)
        XCTAssertEqual(film, [.title, .divider, .badges, .description, .progress, .upNext])

        let episode = InfoPanelLayout.sections(for: item(type: .episode, source: .tv, summary: "An episode.",
                                                         episodeTitle: "Pilot", seTag: "S01E01"), hasUpNext: true)
        XCTAssertEqual(episode, [.title, .episode, .divider, .badges, .description, .progress, .upNext])

        let video = InfoPanelLayout.sections(for: item(source: .musicVideo, summary: "A video.", artist: "a-ha",
                                                       genres: ["Pop", "Synth-pop"]), hasUpNext: true)
        XCTAssertEqual(video, [.title, .artist, .genres, .divider, .badges, .description, .progress, .upNext])
    }

    /// With or without a description the panel has the same lines in the same order, so the progress bar and UP NEXT
    /// stay where they are: the description is always a section, and its height is always two lines.
    func testNothingMovesWhenAProgrammeHasNoDescription() {
        for source: (MediaType, LibrarySource) in [(.movie, .movie), (.episode, .tv), (.movie, .musicVideo)] {
            let with = InfoPanelLayout.sections(for: item(type: source.0, source: source.1, summary: "Some text.",
                                                          artist: source.1 == .musicVideo ? "Artist" : nil,
                                                          episodeTitle: "E", seTag: "S01E01"), hasUpNext: true)
            let without = InfoPanelLayout.sections(for: item(type: source.0, source: source.1, summary: "",
                                                             artist: source.1 == .musicVideo ? "Artist" : nil,
                                                             episodeTitle: "E", seTag: "S01E01"), hasUpNext: true)
            XCTAssertEqual(with, without, "\(source)")
            XCTAssertTrue(without.contains(.description))
        }
        XCTAssertEqual(InfoPanelLayout.descriptionLines, 2)
    }

    /// Only what a programme has is drawn: no UP NEXT line without a next programme, no badges row for a programme with
    /// no year, certificate or rating.
    func testLinesAProgrammeLacksAreLeftOut() {
        let bare = InfoPanelLayout.sections(for: item(summary: "x", year: nil, rating: 0, certificate: nil), hasUpNext: false)
        XCTAssertEqual(bare, [.title, .divider, .description, .progress])
    }
}
