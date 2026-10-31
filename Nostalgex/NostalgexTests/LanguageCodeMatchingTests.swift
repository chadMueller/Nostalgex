import XCTest
@testable import Nostalgex

/// Jellyfin and Emby label a track with a three-letter ISO 639-2 code; the viewer's
/// language is a two-letter ISO 639-1 one. The audio pick used to compare the first two
/// letters of the track's code, so "est" (Estonian) passed as Spanish, "arm" (Armenian)
/// as Arabic and "jav" (Javanese) as Japanese, while "cze", "ger", "pol" and "swe" never
/// matched Czech, German, Polish or Swedish at all.
///
/// The fix is one ISO 639-2 table, both the terminology and the bibliographic forms, and
/// an exact compare. The Roku app already has that table (issue #119), so these tests read
/// it from `roku/source/subtitles/SubtitleSettings.brs` and hold the Apple TV to it: the two
/// apps must agree on every code.
final class LanguageCodeMatchingTests: XCTestCase {

    private typealias Stream = JellyfinPlaybackResolver.PlaybackInfoResponse.MediaStream

    private func stream(_ index: Int, _ type: String, lang: String?, isDefault: Bool = false,
                        isForced: Bool = false, channels: Int? = nil) -> Stream {
        let json = """
        {"Index": \(index), "Type": "\(type)", \(lang.map { "\"Language\": \"\($0)\"," } ?? "")
         "IsDefault": \(isDefault), "IsForced": \(isForced),
         \(channels.map { "\"Channels\": \($0)," } ?? "") "x": 0}
        """
        return try! JSONDecoder().decode(Stream.self, from: Data(json.utf8))
    }

    private func audioPick(_ streams: [Stream], viewer: String) -> Int? {
        JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: [viewer])
    }

    // MARK: - The Roku table, read from the repo

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every `three:two` pair in the Roku app's `NxIso639Table`.
    private static func rokuPairs() throws -> [(three: String, two: String)] {
        let url = repoRoot.appendingPathComponent("roku/source/subtitles/SubtitleSettings.brs")
        let source = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(
            source.components(separatedBy: "\n").first { $0.contains("pairs = \"") },
            "NxIso639Table's pairs string not found in \(url.path)"
        )
        let body = try XCTUnwrap(line.split(separator: "\"").dropFirst().first)
        return body.split(separator: " ").map {
            let kv = $0.split(separator: ":")
            return (String(kv[0]), String(kv[1]))
        }
    }

    func testTheRokuTableIsWhereTheseTestsExpectIt() throws {
        let pairs = try Self.rokuPairs()
        XCTAssertGreaterThanOrEqual(pairs.count, 200, "both forms of every ISO 639-1 language")
        XCTAssertTrue(pairs.contains { $0 == ("cze", "cs") })
        XCTAssertTrue(pairs.contains { $0 == ("ces", "cs") })
    }

    /// The Swift table is the Roku string, character for character: a pair added on one
    /// side only fails here, whichever side it is.
    func testTheSwiftTableIsTheRokuTable() throws {
        let rokuString = try Self.rokuPairs().map { "\($0.three):\($0.two)" }.joined(separator: " ")
        XCTAssertEqual(SubtitleSelectionLogic.iso639Pairs, rokuString)
    }

    /// Both apps reduce every three-letter code to the same two-letter one.
    func testEveryCodeInTheRokuTableReducesTheSameWayOnAppleTV() throws {
        var wrong: [String] = []
        for (three, two) in try Self.rokuPairs() {
            let got = SubtitleSelectionLogic.primaryLanguage(three)
            if got != two { wrong.append("\(three)->\(got ?? "nil") (want \(two))") }
        }
        XCTAssertEqual(wrong, [], "\(wrong.count) codes disagree with the Roku table")
    }

    // MARK: - Audio: the look-alikes the card names

    /// An Estonian track is not Spanish. Before: the 6-channel Estonian track won for a
    /// Spanish viewer because "est" starts with "es".
    func testEstonianIsNotSpanish() {
        let streams = [
            stream(1, "Audio", lang: "est", channels: 6),
            stream(2, "Audio", lang: "spa", channels: 2),
        ]
        XCTAssertEqual(audioPick(streams, viewer: "es-MX"), 2)
        XCTAssertEqual(audioPick(streams, viewer: "et"), 1, "an Estonian viewer still gets Estonian")
    }

    func testArmenianIsNotArabic() {
        let streams = [
            stream(1, "Audio", lang: "arm", channels: 6),
            stream(2, "Audio", lang: "ara", channels: 2),
        ]
        XCTAssertEqual(audioPick(streams, viewer: "ar"), 2)
        XCTAssertEqual(audioPick(streams, viewer: "hy"), 1, "an Armenian viewer gets the arm track")
    }

    func testJavaneseIsNotJapanese() {
        let streams = [
            stream(1, "Audio", lang: "jav", channels: 6),
            stream(2, "Audio", lang: "jpn", channels: 2),
        ]
        XCTAssertEqual(audioPick(streams, viewer: "ja-JP"), 2)
        XCTAssertEqual(audioPick(streams, viewer: "jv"), 1)
    }

    /// Both Czech codes match a Czech viewer. Before: "cze" and "ces" both missed, and the
    /// file's default won instead.
    func testCzechMatchesInBothForms() {
        for code in ["cze", "ces"] {
            let streams = [
                stream(1, "Audio", lang: "hun", isDefault: true, channels: 2),
                stream(2, "Audio", lang: code, channels: 2),
            ]
            XCTAssertEqual(audioPick(streams, viewer: "cs-CZ"), 2, code)
        }
    }

    /// Slovak's bibliographic code "slo" starts like Slovenian's "sl".
    func testSlovakIsNotSlovenian() {
        let streams = [
            stream(1, "Audio", lang: "slo", channels: 6),
            stream(2, "Audio", lang: "slv", channels: 2),
        ]
        XCTAssertEqual(audioPick(streams, viewer: "sl"), 2)
        XCTAssertEqual(audioPick(streams, viewer: "sk"), 1)
    }

    /// Romanian's bibliographic "rum" starts like Russian "ru"; Swedish "swe" like Swahili "sw".
    func testRomanianIsNotRussianAndSwedishIsNotSwahili() {
        let ro = [stream(1, "Audio", lang: "rum", channels: 6), stream(2, "Audio", lang: "rus", channels: 2)]
        XCTAssertEqual(audioPick(ro, viewer: "ru"), 2)
        XCTAssertEqual(audioPick(ro, viewer: "ro"), 1)
        let sv = [stream(1, "Audio", lang: "swe", channels: 6), stream(2, "Audio", lang: "swa", channels: 2)]
        XCTAssertEqual(audioPick(sv, viewer: "sw"), 2)
        XCTAssertEqual(audioPick(sv, viewer: "sv"), 1)
    }

    /// Every bibliographic or terminology code whose first two letters spell some other
    /// language's code: a viewer of that other language must not get it. Each case puts the
    /// look-alike on 6 channels and English on 2, so a false match wins on channel count.
    func testNoThreeLetterCodeMatchesTheLanguageItsFirstTwoLettersSpell() throws {
        let pairs = try Self.rokuPairs()
        let twoLetter = Set(pairs.map(\.two))
        var wrong: [String] = []
        for (three, two) in pairs {
            let lookalike = String(three.prefix(2))
            guard lookalike != two, lookalike != "en", twoLetter.contains(lookalike) else { continue }
            // "nob" spells "no": both Norwegian, the one deliberate equivalence.
            if SubtitleSelectionLogic.norwegianCodes.contains(three),
               SubtitleSelectionLogic.norwegianCodes.contains(lookalike) { continue }
            let streams = [
                stream(1, "Audio", lang: three, channels: 6),
                stream(2, "Audio", lang: "eng", channels: 2),
            ]
            if audioPick(streams, viewer: lookalike) != 2 { wrong.append("\(three) passed as \(lookalike)") }
        }
        XCTAssertEqual(wrong, [], "\(wrong.count) look-alikes matched")
    }

    /// Every language in the table, in either of its codes, is found for its own viewer.
    /// The other track is "qaa", ISO's reserved local-use code, which is nobody's language
    /// (English is not used here: it is always wanted, so it would tie).
    func testEveryCodeMatchesItsOwnViewer() throws {
        var missed: [String] = []
        for (three, two) in try Self.rokuPairs() where two != "en" {
            let streams = [
                stream(1, "Audio", lang: "qaa", isDefault: true, channels: 2),
                stream(2, "Audio", lang: three, channels: 2),
            ]
            if audioPick(streams, viewer: two) != 2 { missed.append("\(three) for \(two)") }
        }
        XCTAssertEqual(missed, [], "\(missed.count) codes missed their own viewer")
    }

    /// The everyday cases still work.
    func testCommonLanguagesStillMatch() {
        let cases: [(track: String, viewer: String)] = [
            ("eng", "en-US"), ("en", "en-GB"), ("spa", "es-ES"), ("fre", "fr-CA"), ("fra", "fr"),
            ("ger", "de-DE"), ("deu", "de"), ("ita", "it"), ("por", "pt-BR"), ("jpn", "ja"),
            ("kor", "ko"), ("chi", "zh-Hans"), ("zho", "zh-Hant"), ("rus", "ru"), ("dut", "nl"),
            ("nld", "nl-BE"), ("pol", "pl"), ("swe", "sv"), ("tur", "tr"), ("gre", "el"),
        ]
        for (track, viewer) in cases {
            let streams = [
                stream(1, "Audio", lang: "hin", isDefault: true, channels: 2),
                stream(2, "Audio", lang: track, channels: 2),
            ]
            XCTAssertEqual(audioPick(streams, viewer: viewer), 2, "\(track) for \(viewer)")
        }
    }

    /// A code the table does not know is not anyone's language, and garbage stays nil.
    func testUnknownCodesMatchNothing() {
        let streams = [
            stream(1, "Audio", lang: "qaa", channels: 6),
            stream(2, "Audio", lang: "eng", channels: 2),
        ]
        XCTAssertEqual(audioPick(streams, viewer: "qa"), 2)
        XCTAssertFalse(SubtitleSelectionLogic.sameLanguage("und", "und"))
        XCTAssertFalse(SubtitleSelectionLogic.sameLanguage("est", "es"))
    }

    // MARK: - Forced subtitles take the same compare

    func testForcedSubtitleLookalikesAreNotBurned() {
        let cases: [(track: String, viewer: String)] = [
            ("est", "es"), ("arm", "ar"), ("jav", "ja"), ("slo", "sl"), ("rum", "ru"), ("swe", "sw"),
        ]
        for (track, viewer) in cases {
            let streams = [stream(3, "Subtitle", lang: track, isForced: true)]
            XCTAssertNil(JellyfinPlaybackResolver.forcedSubtitleToBurn(in: streams, preferredLanguage: viewer),
                         "\(track) burned for \(viewer)")
        }
    }

    func testForcedSubtitleInTheViewersLanguageIsBurnedInEitherForm() {
        let cases: [(track: String, viewer: String)] = [
            ("cze", "cs"), ("ces", "cs"), ("ger", "de"), ("deu", "de"), ("arm", "hy"), ("hye", "hy"),
            ("est", "et"), ("jav", "jv"), ("eng", "en"),
        ]
        for (track, viewer) in cases {
            let streams = [stream(3, "Subtitle", lang: track, isForced: true)]
            XCTAssertEqual(JellyfinPlaybackResolver.forcedSubtitleToBurn(in: streams, preferredLanguage: viewer), 3,
                           "\(track) not burned for \(viewer)")
        }
    }

    // MARK: - Norwegian: Bokmål and Nynorsk are one language

    private let norwegian = ["no", "nb", "nn", "nor", "nob", "nno"]

    /// Any Norwegian code matches any other: a preference for Bokmål takes a track tagged
    /// "nor" or "nno", and the other way round.
    func testEveryNorwegianCodeMatchesEveryOther() {
        for a in norwegian {
            for b in norwegian {
                XCTAssertTrue(SubtitleSelectionLogic.sameLanguage(a, b), "\(a) vs \(b)")
            }
            XCTAssertTrue(SubtitleSelectionLogic.sameLanguage(a, "nb-NO"), "\(a) vs nb-NO")
            XCTAssertTrue(SubtitleSelectionLogic.sameLanguage(a.uppercased(), "nn_NO"), "\(a) vs nn_NO")
        }
    }

    /// Only Norwegian: its neighbours, and codes that merely start with n, stay apart.
    func testNorwegianStaysApartFromItsNeighbours() {
        for other in ["da", "dan", "sv", "swe", "nl", "dut", "nld", "ne", "nep", "is", "isl", "fo", "se"] {
            for code in norwegian {
                XCTAssertFalse(SubtitleSelectionLogic.sameLanguage(code, other), "\(code) vs \(other)")
            }
        }
    }

    /// The table itself is unchanged: "nob" is still "nb" and "nno" still "nn"; the fold is
    /// applied when two codes are compared.
    func testTheTableStillReducesNorwegianToItsOwnCodes() {
        XCTAssertEqual(SubtitleSelectionLogic.primaryLanguage("nob"), "nb")
        XCTAssertEqual(SubtitleSelectionLogic.primaryLanguage("nno"), "nn")
        XCTAssertEqual(SubtitleSelectionLogic.primaryLanguage("nor"), "no")
        XCTAssertEqual(SubtitleSelectionLogic.languageKey("nob"), "no")
        XCTAssertEqual(SubtitleSelectionLogic.languageKey("nn-NO"), "no")
        XCTAssertEqual(SubtitleSelectionLogic.languageKey("swe"), "sv")
    }

    /// Jellyfin and Emby audio: a Bokmål viewer (the TV set to nb-NO) gets the track tagged
    /// "nor", not the Swedish one, and a Nynorsk setting takes "nob".
    func testJellyfinAudioPicksNorwegianInAnySpelling() {
        let streams = [
            stream(1, "Audio", lang: "swe", channels: 6),
            stream(2, "Audio", lang: "nor", channels: 2),
        ]
        XCTAssertEqual(audioPick(streams, viewer: "nb-NO"), 2)
        XCTAssertEqual(audioPick(streams, viewer: "nn"), 2)
        let bokmal = [
            stream(1, "Audio", lang: "dan", isDefault: true, channels: 6),
            stream(2, "Audio", lang: "nob", channels: 2),
        ]
        XCTAssertEqual(audioPick(bokmal, viewer: "nn-NO"), 2)
        XCTAssertEqual(audioPick(bokmal, viewer: "da"), 1, "a Danish viewer still gets Danish")
    }

    func testForcedNorwegianSubtitleIsBurnedForAnyNorwegianSetting() {
        for track in norwegian {
            let streams = [stream(3, "Subtitle", lang: track, isForced: true)]
            for viewer in ["no", "nb", "nn"] {
                XCTAssertEqual(JellyfinPlaybackResolver.forcedSubtitleToBurn(in: streams, preferredLanguage: viewer), 3,
                               "\(track) not burned for \(viewer)")
            }
        }
    }

    /// Plex and the player's own tracks (AVFoundation's extended tags): the same fold.
    func testPlayerTracksMatchNorwegianInAnySpelling() {
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: ["sv", "nb-no"], preferredLowercased: "no"), 1)
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: ["da", "nn"], preferredLowercased: "nb"), 1)
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: ["da", "no"], preferredLowercased: "nn"), 1)
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: ["sv", "da"], preferredLowercased: "nb"), 0,
                       "no Norwegian track: the first, as before")
        XCTAssertFalse(SubtitleSelectionLogic.shouldAutoEnableSubtitles(audioTags: ["nb"], preferredAudioLowercased: "no"),
                       "Bokmål audio is not foreign to a Norwegian viewer")
        XCTAssertTrue(SubtitleSelectionLogic.shouldAutoEnableSubtitles(audioTags: ["sv"], preferredAudioLowercased: "nb"))
        // Everything else keeps the old rule.
        XCTAssertTrue(SubtitleSelectionLogic.tagMatchesPreferred("en-us", "en"))
        XCTAssertFalse(SubtitleSelectionLogic.tagMatchesPreferred("nl", "no"))
        XCTAssertFalse(SubtitleSelectionLogic.tagMatchesPreferred("da", "nb"))
    }

    /// The TV's own locale: "nb-NO" resolves to "nb", which matches a "nor" track.
    func testANorwegianTVLocaleMatchesANorTrack() {
        let resolved = SubtitleSelectionLogic.resolvedLanguageCode(storedCode: "__system__", locale: Locale(identifier: "nb_NO"))
        XCTAssertTrue(SubtitleSelectionLogic.sameLanguage("nor", resolved), "resolved \(resolved)")
        XCTAssertTrue(SubtitleSelectionLogic.tagMatchesPreferred("no", resolved.lowercased()), "resolved \(resolved)")
    }
}
