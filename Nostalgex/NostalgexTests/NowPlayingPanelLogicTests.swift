import XCTest
@testable import Nostalgex

/// Unit tests for the pure logic behind the in-player Now Playing panel:
/// audio-track descriptor building and sleep-timer math/formatting.
final class NowPlayingPanelLogicTests: XCTestCase {

    // MARK: - AudioTrackDescriptorBuilder

    func testDescriptors_assignsSequentialIndexIDs() {
        let tracks = AudioTrackDescriptorBuilder.buildDescriptors(from: [
            (displayName: "English", ext: "en", locale: "en_US"),
            (displayName: "Français", ext: "fr", locale: "fr_FR"),
        ])
        XCTAssertEqual(tracks.map(\.id), [0, 1])
        XCTAssertEqual(tracks[0].displayName, "English")
        XCTAssertEqual(tracks[1].displayName, "Français")
    }

    func testDescriptors_emptyDisplayName_fallsBackToLanguageTag() {
        let tracks = AudioTrackDescriptorBuilder.buildDescriptors(from: [
            (displayName: "   ", ext: "ja", locale: "ja_JP"),
        ])
        XCTAssertEqual(tracks[0].displayName, "JA")
        XCTAssertEqual(tracks[0].languageTag, "ja")
    }

    func testDescriptors_emptyNameAndNoTag_fallsBackToTrackNumber() {
        let tracks = AudioTrackDescriptorBuilder.buildDescriptors(from: [
            (displayName: "", ext: nil, locale: nil),
        ])
        XCTAssertEqual(tracks[0].displayName, "Track 1")
        XCTAssertNil(tracks[0].languageTag)
    }

    func testDescriptors_languageTagDelegatesToSubtitleLogic() {
        // Extended tag wins and is lowercased; locale identifier is normalized to primary.
        let tracks = AudioTrackDescriptorBuilder.buildDescriptors(from: [
            (displayName: "A", ext: "EN-US", locale: nil),
            (displayName: "B", ext: nil, locale: "pt_BR"),
        ])
        XCTAssertEqual(tracks[0].languageTag, "en-us")
        XCTAssertEqual(tracks[1].languageTag, "pt")
    }

    func testDescriptors_empty_returnsEmpty() {
        XCTAssertTrue(AudioTrackDescriptorBuilder.buildDescriptors(from: []).isEmpty)
    }

    func testDescriptors_singleTrack() {
        let tracks = AudioTrackDescriptorBuilder.buildDescriptors(from: [
            (displayName: "Stereo", ext: "en", locale: "en_US"),
        ])
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].id, 0)
    }

    // MARK: - SleepTimerLogic.remaining

    func testRemaining_nilEndDate_isNil() {
        XCTAssertNil(SleepTimerLogic.remaining(from: nil, now: Date()))
    }

    func testRemaining_future_isPositive() {
        let now = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_600)
        XCTAssertEqual(SleepTimerLogic.remaining(from: end, now: now), 600)
    }

    func testRemaining_past_clampsToZero() {
        let now = Date(timeIntervalSince1970: 2_000)
        let end = Date(timeIntervalSince1970: 1_600)
        XCTAssertEqual(SleepTimerLogic.remaining(from: end, now: now), 0)
    }

    func testRemaining_exactBoundary_isZero() {
        let t = Date(timeIntervalSince1970: 1_500)
        XCTAssertEqual(SleepTimerLogic.remaining(from: t, now: t), 0)
    }

    // MARK: - SleepTimerLogic.isExpired

    func testIsExpired_nil_isFalse() {
        XCTAssertFalse(SleepTimerLogic.isExpired(endDate: nil, now: Date()))
    }

    func testIsExpired_past_isTrue() {
        let now = Date(timeIntervalSince1970: 2_000)
        let end = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(SleepTimerLogic.isExpired(endDate: end, now: now))
    }

    func testIsExpired_future_isFalse() {
        let now = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(SleepTimerLogic.isExpired(endDate: end, now: now))
    }

    // MARK: - SleepTimerLogic.label

    func testLabel_minutesOnly() {
        XCTAssertEqual(SleepTimerLogic.label(minutes: 15), "15 MIN")
        XCTAssertEqual(SleepTimerLogic.label(minutes: 45), "45 MIN")
    }

    func testLabel_wholeHours() {
        XCTAssertEqual(SleepTimerLogic.label(minutes: 60), "1 HR")
        XCTAssertEqual(SleepTimerLogic.label(minutes: 120), "2 HR")
    }

    func testLabel_hoursAndMinutes() {
        XCTAssertEqual(SleepTimerLogic.label(minutes: 90), "1 HR 30 MIN")
    }

    func testLabel_zeroOrNegative_isOff() {
        XCTAssertEqual(SleepTimerLogic.label(minutes: 0), "OFF")
        XCTAssertEqual(SleepTimerLogic.label(minutes: -5), "OFF")
    }

    // MARK: - SleepTimerLogic.countdownLabel

    func testCountdown_subMinuteZeroPads() {
        XCTAssertEqual(SleepTimerLogic.countdownLabel(remaining: 9), "0:09")
    }

    func testCountdown_minutesAndSeconds() {
        XCTAssertEqual(SleepTimerLogic.countdownLabel(remaining: 754), "12:34")
    }

    func testCountdown_overAnHour() {
        XCTAssertEqual(SleepTimerLogic.countdownLabel(remaining: 3_661), "1:01:01")
    }

    func testCountdown_zero() {
        XCTAssertEqual(SleepTimerLogic.countdownLabel(remaining: 0), "0:00")
    }

    // MARK: - Presets

    func testPresets_expectedOrder() {
        XCTAssertEqual(SleepTimerLogic.presets, [15, 30, 60])
    }

    // MARK: - SleepTimerLogic.offeredMinutes

    func testOfferedMinutes_noTimerArmed_isPresets() {
        XCTAssertEqual(SleepTimerLogic.offeredMinutes(armed: nil), [15, 30, 60])
    }

    func testOfferedMinutes_armedOnAPreset_doesNotDuplicateIt() {
        XCTAssertEqual(SleepTimerLogic.offeredMinutes(armed: 30), [15, 30, 60])
    }

    func testOfferedMinutes_armedOnARetiredPreset_keepsItInOrder() {
        // A 45 or 90 minute timer armed before the list shrank still has to render its
        // own countdown, and in its natural position.
        XCTAssertEqual(SleepTimerLogic.offeredMinutes(armed: 45), [15, 30, 45, 60])
        XCTAssertEqual(SleepTimerLogic.offeredMinutes(armed: 90), [15, 30, 60, 90])
    }

    func testOfferedMinutes_armedBelowEveryPreset_sortsFirst() {
        XCTAssertEqual(SleepTimerLogic.offeredMinutes(armed: 5), [5, 15, 30, 60])
    }

    func testOfferedMinutes_zeroOrNegative_isPresets() {
        XCTAssertEqual(SleepTimerLogic.offeredMinutes(armed: 0), [15, 30, 60])
        XCTAssertEqual(SleepTimerLogic.offeredMinutes(armed: -30), [15, 30, 60])
    }

    // MARK: - NowPlayingPanelLayout.programRows

    func testProgramRows_openInPlex_appendsLast() {
        let rows = NowPlayingPanelLayout.programRows(
            hasSubtitleTracks: true, audioTrackCount: 2, canOpenInPlex: true
        )
        XCTAssertEqual(rows.last, .openInPlex)
        // Leaving the app must never displace an in-app control.
        XCTAssertEqual(rows.dropLast().count, rows.count - 1)
        XCTAssertFalse(
            NowPlayingPanelLayout.programRows(
                hasSubtitleTracks: true, audioTrackCount: 2, canOpenInPlex: false
            ).contains(.openInPlex)
        )
    }

    func testProgramRows_noSubtitlesSingleAudioTrack_isCaptionsAndAudioOnly() {
        // Nothing to pick between, so neither language preference is offered.
        XCTAssertEqual(
            NowPlayingPanelLayout.programRows(hasSubtitleTracks: false, audioTrackCount: 1, canOpenInPlex: false),
            [.header, .captions, .audio]
        )
    }

    func testProgramRows_ccRowSurvivesAProgramWithNoSubtitles() {
        // Initial panel focus lands on the CC row, so it has to exist regardless.
        let rows = NowPlayingPanelLayout.programRows(hasSubtitleTracks: false, audioTrackCount: 0, canOpenInPlex: false)
        XCTAssertTrue(rows.contains(.captions))
        XCTAssertFalse(rows.contains(.subtitleLanguage))
        XCTAssertFalse(rows.contains(.autoSubtitles))
    }

    func testProgramRows_withSubtitles_addsSubtitlePreferences() {
        XCTAssertEqual(
            NowPlayingPanelLayout.programRows(hasSubtitleTracks: true, audioTrackCount: 1, canOpenInPlex: false),
            [.header, .captions, .subtitleLanguage, .autoSubtitles, .audio]
        )
    }

    func testProgramRows_multipleAudioTracks_addsAudioLanguage() {
        XCTAssertEqual(
            NowPlayingPanelLayout.programRows(hasSubtitleTracks: false, audioTrackCount: 2, canOpenInPlex: false),
            [.header, .captions, .audio, .audioLanguage]
        )
    }

    func testProgramRows_everythingAvailable_fullOrder() {
        XCTAssertEqual(
            NowPlayingPanelLayout.programRows(hasSubtitleTracks: true, audioTrackCount: 3, canOpenInPlex: true),
            [.header, .captions, .subtitleLanguage, .autoSubtitles, .audio, .audioLanguage, .openInPlex]
        )
    }

    func testProgramRows_theGroupLabelLeadsAndIsOneRow() {
        let rows = NowPlayingPanelLayout.programRows(hasSubtitleTracks: true, audioTrackCount: 2, canOpenInPlex: false)
        XCTAssertEqual(rows.first, .header)
        XCTAssertEqual(rows.filter { $0 == .header }.count, 1, "AUDIO & CAPTIONS is one group, not two")
    }

    // MARK: - The AUDIO row and the hint line

    func testAudioRow_opensAListOnlyWhenThereIsAChoice() {
        XCTAssertFalse(NowPlayingPanelLayout.audioRowOpensList(trackCount: 0))
        XCTAssertFalse(NowPlayingPanelLayout.audioRowOpensList(trackCount: 1))
        XCTAssertTrue(NowPlayingPanelLayout.audioRowOpensList(trackCount: 2))
    }

    func testHints_everyControlRowHasOneAndAnOptionInsideAListDoesNot() {
        let rows: [NowPlayingFocus] = [.cc, .subtitleLanguage, .autoSubtitles, .audioRow, .audioLanguage, .openInPlex,
                                       .retro, .streamQuality, .compatibilityRetry, .playbackInformation, .sleepRow]
        for focus in rows {
            XCTAssertNotNil(NowPlayingPanelHints.hint(for: focus), "\(focus)")
        }
        for focus: NowPlayingFocus? in [.audio(1), .sleep(30), .option("en"), nil] {
            XCTAssertNil(NowPlayingPanelHints.hint(for: focus), "\(String(describing: focus))")
        }
    }

    func testHints_arePlainWordsWithNoDashesEmojiOrFutureTalk() {
        for hint in NowPlayingPanelHints.all {
            XCTAssertFalse(hint.contains("\u{2014}") || hint.contains("\u{2013}"), hint)
            XCTAssertTrue(hint.unicodeScalars.allSatisfy { $0.value < 0x2000 }, "no emoji or symbols: \(hint)")
            XCTAssertTrue(hint.hasSuffix("."), hint)
            XCTAssertLessThanOrEqual(hint.count, 100, "two lines at 25 pt: \(hint)")
        }
    }

    func testHints_reuseSettingsWordsWhereTheyExist() {
        XCTAssertEqual(NowPlayingPanelHints.retro, "CRT scanlines, vignette, flicker, 4:3 aspect ratio.")
        XCTAssertEqual(NowPlayingPanelHints.subtitleLanguage, "Choose which subtitle track to prefer when multiple are available.")
        XCTAssertEqual(NowPlayingPanelHints.audioLanguage, "Choose which audio track to prefer when multiple are available.")
        XCTAssertEqual(NowPlayingPanelHints.streamQuality, "Takes effect on the next program.")
    }

    // MARK: - SubtitleLanguagePreset

    func testShortLabel_systemSentinel_isSystem() {
        XCTAssertEqual(SubtitleLanguagePreset.shortLabel(for: SubtitleLanguagePreset.systemCode), "SYSTEM")
    }

    func testShortLabel_languageCode_isUppercased() {
        XCTAssertEqual(SubtitleLanguagePreset.shortLabel(for: "en"), "EN")
        XCTAssertEqual(SubtitleLanguagePreset.shortLabel(for: "pt-BR"), "PT-BR")
        XCTAssertEqual(SubtitleLanguagePreset.shortLabel(for: "zh-Hans"), "ZH-HANS")
    }

    func testDisplayLabel_knownAndUnknownCodes() {
        XCTAssertEqual(SubtitleLanguagePreset.displayLabel(for: "de"), "GERMAN")
        XCTAssertEqual(SubtitleLanguagePreset.displayLabel(for: "xx"), "XX")
    }

    func testPresetCodes_areUnique() {
        // The panel keys picker focus off the raw code, so a duplicate would give two
        // rows the same focus identity.
        let codes = SubtitleLanguagePreset.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
    }
}
