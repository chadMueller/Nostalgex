import Testing
import Foundation
@testable import Nostalgex

struct MusicMetadataTests {

    @Test func parseArtistDashTitle() {
        let parsed = MusicTitleParser.parse("Michael Jackson - Billie Jean")
        #expect(parsed.artist == "Michael Jackson")
        #expect(parsed.song == "Billie Jean")
    }

    @Test func parseTitleByArtist() {
        let parsed = MusicTitleParser.parse("Billie Jean by Michael Jackson")
        #expect(parsed.artist == "Michael Jackson")
        #expect(parsed.song == "Billie Jean")
    }

    @Test func mapMusicBrainzTagsToChannelGenres() {
        let genres = MusicBrainzService.mapTagsToChannelGenres(["pop rock", "hip hop", "soul"])
        #expect(genres.contains("Pop"))
        #expect(genres.contains("Hip-Hop"))
        #expect(genres.contains("Soul"))
    }

    @Test @MainActor func thinPlexGenresDetected() {
        #expect(MusicEnrichmentService.plexGenresAreThin(["Music Video"]))
        #expect(!MusicEnrichmentService.plexGenresAreThin(["Pop", "Music Video"]))
    }

    @Test func applyingMusicEnrichmentUpdatesDisplayFields() {
        let raw = PlexMediaItem(
            id: "1",
            title: "Thriller.mp4",
            artist: nil,
            episodeTitle: nil,
            seTag: nil,
            summary: "",
            year: nil,
            originallyAvailableAt: nil,
            contentRating: nil,
            duration: 5,
            ratingKey: "1",
            partKey: nil,
            container: "mp4",
            videoCodec: nil,
            audioCodec: nil,
            videoProfile: nil,
            bitrate: nil,
            genres: ["Music Video"],
            rating: 0,
            userRating: 0,
            type: .movie,
            thumb: nil,
            art: nil,
            viewCount: 0,
            addedAt: 0,
            studio: nil,
            tmdbID: nil,
            imdbID: nil,
            librarySource: .musicVideo
        )
        let music = MusicVideoEnrichment(
            ratingKey: "1",
            recordingTitle: "Thriller",
            artist: "Michael Jackson",
            musicBrainzID: "mbid",
            genres: ["Pop", "Rock"],
            releaseYear: 1982,
            fetchedAt: Date()
        )
        let merged = raw.applyingMusicEnrichment(music)
        #expect(merged.title == "Thriller")
        #expect(merged.artist == "Michael Jackson")
        #expect(merged.year == 1982)
        #expect(merged.musicDisplayLine == "Michael Jackson · Thriller")
        #expect(merged.musicGenreDisplay?.contains("Pop") == true)
    }
}

/// Deezer genre pass, added 2026-10-07. Titles are real rows from Chad's library that
/// MusicBrainz left without a genre; the expectations are what the measured run found.
struct DeezerEnrichmentTests {

    @Test func cleanerTakesRippedFilenamesDownToSearchableText() {
        #expect(MusicTitleParser.clean("Ruff_Ryders_-_Get_Wild_[MMV]") == "Ruff Ryders - Get Wild")
        #expect(MusicTitleParser.clean("Avril Lavigne - Don't Tell Me video!") == "Avril Lavigne - Don't Tell Me")
        #expect(MusicTitleParser.clean("Beatles - From Me To You(11-4-1963 Royal Variety)") == "Beatles - From Me To You")
        #expect(MusicTitleParser.clean("the_used-take_it_away-vgb-prv") == "the used-take it away")
        #expect(MusicTitleParser.clean("Michael Jackson - Smooth Criminal (1988)") == "Michael Jackson - Smooth Criminal")
    }

    @Test func parserSplitsTheShapesTheLibraryActuallyHas() {
        let a = MusicTitleParser.parse("Ruff_Ryders_-_Get_Wild_[MMV]")
        #expect(a.artist == "Ruff Ryders" && a.song == "Get Wild")
        let b = MusicTitleParser.parse("B.o.B - Airplanes ft. Hayley Williams of Paramore")
        #expect(b.artist == "B.o.B" && b.song == "Airplanes")
        let c = MusicTitleParser.parse("Nelly ft. Akon ft. Ashanti - Body On Me")
        #expect(c.artist == "Nelly" && c.song == "Body On Me")
        let d = MusicTitleParser.parse("Beatles - I'm A Loser - Boys(Shindig 1964)")
        #expect(d.artist == "Beatles" && d.song == "I'm A Loser")
        let e = MusicTitleParser.parse("the_used-take_it_away-vgb-prv")
        #expect(e.artist == "the used" && e.song == "take it away")
        let f = MusicTitleParser.parse("Anaconda")
        #expect(f.artist == nil && f.song == "Anaconda")
    }

    @Test func existingShapesStillParse() {
        let a = MusicTitleParser.parse("Michael Jackson - Billie Jean (1983)")
        #expect(a.artist == "Michael Jackson" && a.song == "Billie Jean")
        let b = MusicTitleParser.parse("Billie Jean by Michael Jackson")
        #expect(b.artist == "Michael Jackson" && b.song == "Billie Jean")
        // A hyphenated title with no artist must not be split into nonsense.
        let c = MusicTitleParser.parse("Twenty-One")
        #expect(c.artist == nil || c.song.count >= 2)
    }

    @Test func deezerGenresMapOntoChannelVocabulary() {
        #expect(DeezerService.mapGenres(["Rap/Hip Hop"]) == ["Hip-Hop", "Hip Hop", "Rap"])
        #expect(DeezerService.mapGenres(["Soul & Funk"]) == ["Soul", "Funk"])
        #expect(DeezerService.mapGenres(["Latin Music"]) == ["Latin"])
        #expect(DeezerService.mapGenres(["Metal"]).contains("Metal"))
        #expect(DeezerService.mapGenres(["Dance"]).contains("Electronic"))
        #expect(DeezerService.mapGenres(["Films/Games", "Film Scores", "Kids"]).isEmpty)
        #expect(DeezerService.mapGenres(["Pop", "International Pop", "Rock"]) == ["Pop", "Rock"])
    }

    @Test func bestHitPrefersTheArtistWeAskedFor() {
        let hits = [
            DeezerService.SearchHit(trackID: 1, albumID: 1, title: "Afternoon Delight", artist: "Starland Vocal Band"),
            DeezerService.SearchHit(trackID: 2, albumID: 2, title: "Afternoon Delight", artist: "Will Ferrell"),
        ]
        #expect(DeezerService.bestHit(hits, artistHint: "Will Ferrell")?.trackID == 2)
        #expect(DeezerService.bestHit(hits, artistHint: nil)?.trackID == 1)
        #expect(DeezerService.bestHit(hits, artistHint: "Nobody Here")?.trackID == 1)
        #expect(DeezerService.bestHit([], artistHint: "x") == nil)
    }

    private func row(genres: [String], artist: String?, mbid: String?, checked: Date?, fetched: Date = Date()) -> MusicVideoEnrichment {
        var r = MusicVideoEnrichment(ratingKey: "1", recordingTitle: "Song", artist: artist, musicBrainzID: mbid,
                                     genres: genres, releaseYear: nil, fetchedAt: fetched)
        r.deezerCheckedAt = checked
        return r
    }

    @Test @MainActor func cachedRowsWithANameButNoGenreGetTheDeezerPass() {
        // The 87%: MusicBrainz named them, tags were empty, and the old rule called them done.
        let named = row(genres: ["Music Video"], artist: "Incubus", mbid: "mb-1", checked: nil)
        #expect(!MusicEnrichmentService.isSettled(named))
        #expect(MusicEnrichmentService.needsOnlyGenres(named))

        let done = row(genres: ["Alternative"], artist: "Incubus", mbid: "mb-1", checked: nil)
        #expect(MusicEnrichmentService.isSettled(done))

        let askedAlready = row(genres: ["Music Video"], artist: "Incubus", mbid: "mb-1", checked: Date())
        #expect(MusicEnrichmentService.isSettled(askedAlready))
        #expect(!MusicEnrichmentService.needsOnlyGenres(askedAlready))

        let nameless = row(genres: [], artist: nil, mbid: nil, checked: nil)
        #expect(!MusicEnrichmentService.needsOnlyGenres(nameless), "nothing to search with; full resolve, not a genre pass")

        let stale = row(genres: ["Alternative"], artist: "Incubus", mbid: "mb-1", checked: Date(), fetched: Date(timeIntervalSinceNow: -100 * 86_400))
        #expect(!MusicEnrichmentService.isSettled(stale))
    }

    @Test func rowsCachedBeforeDeezerStillDecode() throws {
        let legacy = """
        {"ratingKey":"7","recordingTitle":"Vogue","artist":"Madonna","musicBrainzID":null,"genres":["Music Video"],"releaseYear":1990,"fetchedAt":780000000}
        """
        let decoded = try JSONDecoder().decode(MusicVideoEnrichment.self, from: Data(legacy.utf8))
        #expect(decoded.deezerID == nil)
        #expect(decoded.deezerCheckedAt == nil)
        #expect(decoded.artist == "Madonna")
    }
}

/// Year trust order, measured 2026-10-07: Plex gave 1970 or the date added for most of
/// Chad's music videos, Deezer gives the album/remaster year, so Y2K and CURRENT SPIN
/// were sorting Smooth Criminal (1970) and Waves (2026) into the wrong decades.
struct MusicYearTests {
    @Test func yearInTheFilenameWinsOverEverything() {
        #expect(MusicTitleParser.yearInTitle("Michael Jackson - Smooth Criminal (1988)") == 1988)
        #expect(MusicTitleParser.yearInTitle("Beatles - From Me To You(11-4-1963 Royal Variety)") == nil, "a date inside a note is not a (YYYY) suffix")
        #expect(MusicTitleParser.yearInTitle("Anaconda") == nil)
        #expect(MusicYear.resolve(titleYear: 1988, musicBrainzYear: 2009, plexYear: 1970) == 1988)
    }

    @Test func musicBrainzBeatsPlexAndPlexOnlyCountsWhenPlausible() {
        let now = Date()
        let thisYear = Calendar.current.component(.year, from: now)
        #expect(MusicYear.resolve(titleYear: nil, musicBrainzYear: 1977, plexYear: 2026, now: now) == 1977)
        #expect(MusicYear.resolve(titleYear: nil, musicBrainzYear: nil, plexYear: 1970, now: now) == nil, "1970 is Plex's unknown")
        #expect(MusicYear.resolve(titleYear: nil, musicBrainzYear: nil, plexYear: thisYear, now: now) == nil, "this year is the date added")
        #expect(MusicYear.resolve(titleYear: nil, musicBrainzYear: nil, plexYear: 2014, now: now) == 2014)
    }

    @Test func plexItemWithoutARowStillGetsTheTrustedYear() {
        let item = PlexMediaItem.musicVideoFixture(title: "Bee Gees - Night Fever (1977)", year: 1970)
        #expect(item.applyingTrustedMusicYear().year == 1977)
        let movie = PlexMediaItem.musicVideoFixture(title: "Night Fever (1977)", year: 1970, source: .movie)
        #expect(movie.applyingTrustedMusicYear().year == 1970, "only music videos get this treatment")
    }
}

extension PlexMediaItem {
    static func musicVideoFixture(title: String, year: Int?, source: LibrarySource = .musicVideo) -> PlexMediaItem {
        PlexMediaItem(
            id: "f", title: title, artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: year,
            originallyAvailableAt: nil, contentRating: nil, duration: 4, ratingKey: "f", partKey: nil,
            container: "mp4", videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: ["Music Video"], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: source
        )
    }
}

/// N-034: a YouTube-style suffix in brackets used to lose only its "official" and "video", so
/// "Song (Official Music Video)" became "Song ( Music )" and "Song (Official Video)" became
/// "Song ( )". The cleaned title is what MusicBrainz and Deezer are searched with and what the
/// guide shows, so the leftovers found nothing and read as noise. A bracket made only of those
/// words now goes whole; a bracket that says anything else stays.
struct MusicTitleSuffixTests {

    @Test func aBracketOfNoiseWordsGoesWhole() {
        let cases: [(String, String)] = [
            ("Song (Official Music Video)", "Song"),
            ("Song (Official Video)", "Song"),
            ("Artist - Song (Official Music Video)", "Artist - Song"),
            ("Artist - Song (Official Lyric Video)", "Artist - Song"),
            ("Artist - Song (Official Audio)", "Artist - Song"),
            ("Artist - Song (Official Visualizer)", "Artist - Song"),
            ("Artist - Song (Lyrics)", "Artist - Song"),
            ("Artist - Song (Music Video)", "Artist - Song"),
            ("Artist - Song (Video)", "Artist - Song"),
            ("Artist - Song (HD)", "Artist - Song"),
            ("Artist - Song (HQ)", "Artist - Song"),
            ("Artist - Song (4K)", "Artist - Song"),
            ("Artist - Song (Remastered)", "Artist - Song"),
            ("Artist - Song (Official Music Video HD)", "Artist - Song"),
            ("Artist - Song (OFFICIAL MUSIC VIDEO)", "Artist - Song"),
            ("Artist - Song (official video) [4K]", "Artist - Song"),
            ("Artist - Song (Official Video) (1999)", "Artist - Song"),
            ("Artist - Song (Official Video) ft. Other Artist", "Artist - Song ft. Other Artist"),
        ]
        for (raw, want) in cases {
            #expect(MusicTitleParser.clean(raw) == want, "\(raw)")
        }
    }

    @Test func aBracketThatSaysSomethingElseStays() {
        for title in ["Artist - Song (Live at Wembley)", "Artist - Song (Remix)", "Artist - Song (Radio Edit)",
                      "Artist - Song (Acoustic Version)", "Artist - Song (Part 2)", "Artist - (What's the Story) Morning Glory"] {
            #expect(MusicTitleParser.clean(title) == title, "\(title)")
        }
        // A noise word beside a real one in the same bracket is not "only noise".
        #expect(MusicTitleParser.clean("Artist - Song (Live Video)") == "Artist - Song (Live)")
    }

    @Test func theOldCasesStillClean() {
        #expect(MusicTitleParser.clean("Avril Lavigne - Don't Tell Me video!") == "Avril Lavigne - Don't Tell Me")
        #expect(MusicTitleParser.clean("the_used-take_it_away-vgb-prv") == "the used-take it away")
        #expect(MusicTitleParser.clean("Ruff_Ryders_-_Get_Wild_[MMV]") == "Ruff Ryders - Get Wild")
    }

    @Test func noCleanedTitleKeepsEmptyBrackets() {
        for raw in ["Song (Official Video)", "Song ( Official )", "Song (Official) (Video)", "Song ()", "Song (HD) (HQ)"] {
            let out = MusicTitleParser.clean(raw)
            #expect(!out.contains("()") && !out.contains("( )"), "\(raw) -> \(out)")
        }
    }

    @Test func parseGivesTheSongAndTheArtist() {
        let a = MusicTitleParser.parse("Michael Jackson - Billie Jean (Official Music Video)")
        #expect(a.artist == "Michael Jackson" && a.song == "Billie Jean")
        let b = MusicTitleParser.parse("Billie Jean (Official Video)")
        #expect(b.artist == nil && b.song == "Billie Jean")
    }
}
