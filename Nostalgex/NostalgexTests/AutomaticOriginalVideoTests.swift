import XCTest
@testable import Nostalgex

final class AutomaticOriginalVideoTests: XCTestCase {
    private func item() -> PlexMediaItem {
        PlexMediaItem(id: "1", title: "Synthetic", artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: 2020,
          originallyAvailableAt: nil, contentRating: nil, duration: 100, ratingKey: "1", partKey: "/part",
          container: "mkv", videoCodec: "hevc", audioCodec: "eac3", videoProfile: "main 10", bitrate: 15000,
          genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0,
          studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie,
          videoBitDepth: 10, doviProfile: 8, videoWidth: 3840, videoHeight: 2160,
          audioChannelCount: 6, doviCompatibilityID: 1, audioStreamID: 22)
    }
    private func eligible(_ i: PlexMediaItem, quality: StreamQuality = .auto, local: Bool = true, hevc: Bool = true, originalLocal: Bool = false) -> Bool {
        PlexAPIService.shouldPreferOriginalVideo(i, quality: quality, isLocal: local, hevcCapable: hevc, originalLocal: originalLocal)
    }
    func testNarrowFormatQualityAndCapabilityGate() {
        let good = item()
        XCTAssertTrue(eligible(good)); XCTAssertTrue(eligible(good, quality: .maximum))
        for q in [StreamQuality.high, .medium, .low] { XCTAssertFalse(eligible(good, quality: q)) }
        XCTAssertFalse(eligible(good, local: false)); XCTAssertFalse(eligible(good, hevc: false))
        var v = good; v.doviCompatibilityID = nil; XCTAssertFalse(eligible(v))
        v = good; v.doviCompatibilityID = 2; XCTAssertFalse(eligible(v))
        v = good; v.doviProfile = 7; XCTAssertFalse(eligible(v))
        v = good; v.audioChannelCount = 8; XCTAssertFalse(eligible(v))
        v = good; v.audioStreamID = nil; XCTAssertFalse(eligible(v))
        v = good; v.videoBitDepth = 12; XCTAssertFalse(eligible(v))
        v = good; v.videoWidth = 1920; XCTAssertFalse(eligible(v))
        v = good; v.videoHeight = 1080; XCTAssertFalse(eligible(v))
    }
    func testRequestRetainsQualityAndSelectedMediaClock() throws {
        let url = try XCTUnwrap(URL(string: "http://example.test/start.m3u8?session=fresh&path=/library/metadata/1&mediaIndex=2&partIndex=1&offset=345&maxVideoBitrate=40000&videoResolution=3840x2160&autoAdjustQuality=1&copyts=0&directStreamAudio=1"))
        let result = try XCTUnwrap(PlexAPIService.automaticOriginalVideoURL(from: url, audioStreamID: 22))
        let q = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        for (key,value) in ["session":"fresh", "mediaIndex":"2", "partIndex":"1", "offset":"345", "maxVideoBitrate":"40000", "videoResolution":"3840x2160", "autoAdjustQuality":"1", "copyts":"0", "audioStreamID":"22", "directStreamAudio":"1"] { XCTAssertEqual(q[key],value) }
        XCTAssertEqual(q["X-Plex-Platform"], "Generic")
        XCTAssertTrue(q["X-Plex-Client-Profile-Extra"]!.contains(PlexAPIService.eac3ChannelCap))
    }
    func testParsedSelectedAudioAndPartFactsSurviveSnapshot() throws {
        let json = #"{"container":"mkv","Part":[{"key":"/part","Stream":[{"streamType":1,"codec":"hevc","bitDepth":10,"DOVIProfile":8,"DOVIBLCompatID":1},{"streamType":2,"id":11,"codec":"aac","channels":2},{"streamType":2,"id":22,"codec":"eac3","channels":6,"selected":1}]}]}"#
        let media = try JSONDecoder().decode(PlexRawItem.PlexMedia.self, from: Data(json.utf8))
        XCTAssertEqual(media.audioStream?.id,22)
        let part = try XCTUnwrap(media.playbackParts.first)
        XCTAssertEqual(part.audioChannelCount,6); XCTAssertEqual(part.doviCompatibilityID,1)
        var i=item(); i.playbackParts=[part]
        let restored=try JSONDecoder().decode(PlexMediaItem.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(restored.audioChannelCount,6); XCTAssertEqual(restored.doviCompatibilityID,1)
        XCTAssertEqual(restored.withPartKey("/part").audioStreamID,22)
    }
    func testAudioConversionIsNotAcceptedAsOriginalAudio() {
        func data(_ audio: String) -> Data { Data("<MediaContainer><Part container=\"mp4\"><Stream streamType=\"1\" codec=\"hevc\" decision=\"copy\"/>\(audio)</Part></MediaContainer>".utf8) }
        XCTAssertTrue(PlexAPIService.decisionPreservesOriginalVideo(data("<Stream streamType=\"2\" codec=\"eac3\" decision=\"copy\" channels=\"6\"/>"), requireAudioCopy:true))
        XCTAssertFalse(PlexAPIService.decisionPreservesOriginalVideo(data("<Stream streamType=\"2\" codec=\"ac3\" decision=\"transcode\" channels=\"6\"/>"), requireAudioCopy:true))
        XCTAssertFalse(PlexAPIService.decisionPreservesOriginalVideo(data(""), requireAudioCopy:true))
    }
    func testRefusedUnknownAndAudioTranscodedCandidatesCleanOnlyTheirSession() async {
        let url=URL(string:"http://example.test/start.m3u8")!
        for decision in [PlexAPIService.TranscodeDecision.unknown,
                         .init(code:"2000",text:"refused"),
                         .init(code:"1001",text:"ok",preservesOriginalVideo:true)] {
            var stopped:[String]=[]
            let r=await PlexAPIService.prepareOriginalVideoCandidate(url:url,sessionID:"candidate",offsetSeconds:345,prepare:{_ in decision},stop:{stopped.append($0)})
            XCTAssertNil(r); XCTAssertEqual(stopped,["candidate"])
        }
    }
    func testAcceptedCopyCarriesPreservationPolicyAndOffset() async {
        let url=URL(string:"http://example.test/start.m3u8")!
        var stopped:[String]=[]
        let r=await PlexAPIService.prepareOriginalVideoCandidate(url:url,sessionID:"fresh",offsetSeconds:345,prepare:{_ in .init(code:"1001",text:"ok",preservesOriginalVideo:true,preservesOriginalAudio:true)},stop:{stopped.append($0)})
        XCTAssertEqual(r?.resolution.playSessionId,"fresh"); XCTAssertEqual(r?.startsAtOffset,true)
        XCTAssertEqual(r?.resolution.requiresOriginalVideo,true); XCTAssertTrue(stopped.isEmpty)
    }
    func testUnrelatedFormatsOverBudgetAndOldSnapshotsStayOnExistingPath() throws {
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item())) as? [String: Any])
        for (key,value) in [("container","mp4" as Any),("videoCodec","h264" as Any),("audioCodec","aac" as Any),("bitrate",40001 as Any)] {
            var json=base; json[key]=value
            let i=try JSONDecoder().decode(PlexMediaItem.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertFalse(eligible(i),key)
        }
        var old=base
        for key in ["audioChannelCount","doviCompatibilityID","audioStreamID"] { old.removeValue(forKey:key) }
        let i=try JSONDecoder().decode(PlexMediaItem.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertFalse(eligible(i)); XCTAssertNil(i.audioChannelCount)
    }
    func testCancelledPreparationCleansCandidate() async {
        let result = await Task { () -> (Bool, [String]) in
            withUnsafeCurrentTask { $0?.cancel() }
            var stopped:[String]=[]
            let r=await PlexAPIService.prepareOriginalVideoCandidate(url:URL(string:"http://example.test/start.m3u8")!,sessionID:"cancelled",offsetSeconds:0,prepare:{_ in .init(code:"1001",text:"ok",preservesOriginalVideo:true,preservesOriginalAudio:true)},stop:{stopped.append($0)})
            return (r == nil,stopped)
        }.value
        XCTAssertTrue(result.0); XCTAssertEqual(result.1,["cancelled"])
    }

    func testBulkListingEnrichmentUsesOnlyTheSelectedPart() throws {
        var cached=item(); cached.videoBitDepth=nil; cached.doviProfile=nil
        cached.audioChannelCount=nil; cached.audioStreamID=nil; cached.doviCompatibilityID=nil
        XCTAssertTrue(PlexAPIService.needsOriginalVideoFacts(cached,quality:.auto,isLocal:true,hevcCapable:true))
        let json = #"{"ratingKey":"1","type":"movie","title":"Synthetic","Media":[{"Part":[{"key":"/part","Stream":[{"streamType":1,"codec":"hevc","bitDepth":10,"DOVIProfile":8,"DOVIBLCompatID":1},{"streamType":2,"id":22,"codec":"eac3","channels":6,"selected":true}]}]}]}"#
        let raw=try JSONDecoder().decode(PlexRawItem.self,from:Data(json.utf8))
        let enriched=PlexAPIService.applyingPlaybackStreamFacts(raw,to:cached)
        XCTAssertTrue(eligible(enriched)); XCTAssertEqual(enriched.partKey,cached.partKey)
        XCTAssertEqual(enriched.mediaIndex,cached.mediaIndex); XCTAssertEqual(enriched.partIndex,cached.partIndex)
        cached.partIndex=1
        XCTAssertNil(PlexAPIService.applyingPlaybackStreamFacts(raw,to:cached).audioStreamID)
        XCTAssertFalse(PlexAPIService.needsOriginalVideoFacts(item(),quality:.auto,isLocal:true,hevcCapable:true))
        XCTAssertFalse(PlexAPIService.needsOriginalVideoFacts(cached,quality:.high,isLocal:true,hevcCapable:true))
    }

    func testHDR10SurroundRequiresExplicitColorFactsAndNoDolbyVision() {
        var i = item(); i.doviProfile = nil; i.doviCompatibilityID = nil
        XCTAssertFalse(eligible(i, originalLocal: true))
        i.hasHDR10ColorMetadata = true
        XCTAssertFalse(eligible(i)) // Existing capped playback stays unchanged.
        XCTAssertTrue(eligible(i, originalLocal: true))
        i.audioChannelCount = 8; XCTAssertTrue(eligible(i, originalLocal: true))
        i.audioChannelCount = 2; XCTAssertFalse(eligible(i, originalLocal: true))
        i.audioChannelCount = 8; i.hasHDR10ColorMetadata = false; XCTAssertFalse(eligible(i, originalLocal: true))
        i.hasHDR10ColorMetadata = true; i.doviProfile = 7; XCTAssertFalse(eligible(i, originalLocal: true))
        i.doviProfile = 8; i.doviCompatibilityID = 1; XCTAssertFalse(eligible(i, originalLocal: true))
        i.doviProfile = nil
        XCTAssertTrue(eligible(i, quality: .high, originalLocal: true)); XCTAssertFalse(eligible(i, local: false, originalLocal: true))
        XCTAssertFalse(eligible(i, hevc: false, originalLocal: true))
    }

    func testHDR10FactsComeFromSelectedStreamAndSurviveSnapshot() throws {
        var i = item(); i.doviProfile = nil; i.doviCompatibilityID = nil
        let json = #"{"ratingKey":"1","type":"movie","title":"Synthetic","Media":[{"Part":[{"key":"/part","Stream":[{"streamType":1,"codec":"hevc","bitDepth":10,"colorTrc":"smpte2084","colorPrimaries":"bt2020","colorSpace":"bt2020nc"},{"streamType":2,"id":22,"codec":"eac3","channels":8,"selected":true}]}]}]}"#
        let raw = try JSONDecoder().decode(PlexRawItem.self, from: Data(json.utf8))
        let enriched = PlexAPIService.applyingPlaybackStreamFacts(raw, to: i)
        XCTAssertTrue(eligible(enriched, originalLocal: true)); XCTAssertEqual(enriched.audioChannelCount, 8)
        var withParts = enriched; withParts.playbackParts = raw.Media?.first?.playbackParts
        let restored = try JSONDecoder().decode(PlexMediaItem.self, from: JSONEncoder().encode(withParts))
        XCTAssertEqual(restored.hasHDR10ColorMetadata, true)
        XCTAssertEqual(restored.withPartKey("/part").hasHDR10ColorMetadata, true)
        for invalid in [json.replacingOccurrences(of: "smpte2084", with: "bt709"),
                        json.replacingOccurrences(of: "bt2020nc", with: "bt709"),
                        json.replacingOccurrences(of: "bt2020\"", with: "bt709\"")] {
            let raw = try JSONDecoder().decode(PlexRawItem.self, from: Data(invalid.utf8))
            XCTAssertFalse(eligible(PlexAPIService.applyingPlaybackStreamFacts(raw, to: i), originalLocal: true))
        }
    }

    func testAudioOnlyCompatibilityRequiresCopiedVideoAndAC3SixChannels() {
        func data(codec: String = "ac3", channels: Int = 6, audio: String = "transcode", video: String = "copy") -> Data {
            Data("<MediaContainer><Part container=\"mp4\"><Stream streamType=\"1\" codec=\"hevc\" decision=\"\(video)\"/><Stream streamType=\"2\" codec=\"\(codec)\" decision=\"\(audio)\" channels=\"\(channels)\"/></Part></MediaContainer>".utf8)
        }
        XCTAssertTrue(PlexAPIService.decisionPreservesOriginalVideo(data(), requireAC3Conversion: true))
        for rejected in [data(codec: "aac"), data(channels: 2), data(channels: 8), data(audio: "copy"), data(video: "transcode")] {
            XCTAssertFalse(PlexAPIService.decisionPreservesOriginalVideo(rejected, requireAC3Conversion: true))
        }
        XCTAssertFalse(PlexAPIService.decisionPreservesOriginalVideo(data(), requireAudioCopy: true))
    }

    func testAudioOnlyCandidateIsOptInAndKeepsOriginalVideoPolicy() async {
        let decision = PlexAPIService.TranscodeDecision(code: "1001", text: "ok", preservesOriginalVideo: true,
                                                       convertsAudioToAC3Surround: true)
        for allow in [false, true] {
            var stopped: [String] = []
            let result = await PlexAPIService.prepareOriginalVideoCandidate(url: URL(string: "http://example.test/start.m3u8")!,
                sessionID: "audio-only", offsetSeconds: 123, allowAC3Conversion: allow,
                prepare: { _ in decision }, stop: { stopped.append($0) })
            XCTAssertEqual(result != nil, allow)
            XCTAssertEqual(stopped, allow ? [] : ["audio-only"])
            if allow { XCTAssertEqual(result?.resolution.requiresOriginalVideo, true); XCTAssertEqual(result?.startsAtOffset, true) }
        }
    }

    func testSurroundRequestDoesNotRaiseAutomaticCeilingButExplicitRetryDoes() throws {
        let base = URL(string: "http://example.test/start.m3u8?session=fresh&mediaIndex=2&partIndex=1&offset=345&maxVideoBitrate=40000&videoResolution=3840x2160&audioStreamID=11")!
        let automatic = try XCTUnwrap(PlexAPIService.automaticOriginalVideoURL(from: base, audioStreamID: 22, convertSurroundAudio: true))
        let explicit = try XCTUnwrap(PlexAPIService.preservationRetryURL(from: base, audioStreamID: 22, convertSurroundAudio: true))
        for (url, ceiling) in [(automatic, "40000"), (explicit, "100000")] {
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q["maxVideoBitrate"], ceiling); XCTAssertEqual(q["audioStreamID"], "22")
            XCTAssertEqual(q["offset"], "345"); XCTAssertEqual(q["mediaIndex"], "2"); XCTAssertEqual(q["partIndex"], "1")
            XCTAssertTrue(q["X-Plex-Client-Profile-Extra"]!.contains("audioCodec=ac3,eac3)"))
            XCTAssertFalse(q["X-Plex-Client-Profile-Extra"]!.contains("aac"))
            XCTAssertTrue(q["X-Plex-Client-Profile-Extra"]!.contains(PlexAPIService.eac3ChannelCap))
        }
    }

    func testChangedTimestampEnrichesSamePartButNeverAnotherPart() throws {
        let cachedKey = "/library/parts/10/100/file.mkv"
        let currentKey = "/library/parts/10/200/file.mkv"
        var cached = item().withPartKey(cachedKey)
        cached.doviProfile = nil; cached.audioChannelCount = nil
        let json = #"{"ratingKey":"1","type":"movie","title":"Synthetic","Media":[{"Part":[{"key":"/library/parts/10/200/file.mkv","Stream":[{"streamType":1,"codec":"hevc","bitDepth":10,"colorTrc":"smpte2084","colorPrimaries":"bt2020","colorSpace":"bt2020nc"},{"streamType":2,"id":22,"codec":"eac3","channels":8,"selected":true}]}]}]}"#
        let raw = try JSONDecoder().decode(PlexRawItem.self, from: Data(json.utf8))
        let enriched = PlexAPIService.applyingPlaybackStreamFacts(raw, to: cached)
        XCTAssertEqual(enriched.partKey, currentKey); XCTAssertTrue(eligible(enriched, originalLocal: true))
        XCTAssertEqual(enriched.mediaIndex, cached.mediaIndex); XCTAssertEqual(enriched.partIndex, cached.partIndex)
        for other in ["/library/parts/11/200/file.mkv", "/library/parts/10/200/file.mp4", "/library/parts/10/../file.mkv", "https://example.test/library/parts/10/200/file.mkv"] {
            XCTAssertFalse(PlexAPIService.samePlexPart(other, cachedKey))
        }
        let wrong = cached.withPartKey("/library/parts/11/100/file.mkv")
        XCTAssertNil(PlexAPIService.applyingPlaybackStreamFacts(raw, to: wrong).audioChannelCount)
    }

    func testExplicitLocalOriginalPreservesRemoteAndCappedChoices() throws {
        var source = item(); source.doviProfile = nil; source.doviCompatibilityID = nil
        source.hasHDR10ColorMetadata = true; source.audioChannelCount = 8
        let url = URL(string: "http://example.test/start.m3u8?session=owned&mediaIndex=0&partIndex=0&offset=300&maxVideoBitrate=12000&videoResolution=1920x1080&autoAdjustQuality=0")!
        func candidate(local: Bool, enabled: Bool, hevc: Bool = true) -> URL? {
            PlexAPIService.preferredOriginalVideoURL(from: url, item: source, quality: .high,
                isLocal: local, hevcCapable: hevc, originalLocal: enabled)
        }
        XCTAssertNil(candidate(local: false, enabled: true))
        XCTAssertNil(candidate(local: true, enabled: false))
        XCTAssertNil(candidate(local: true, enabled: true, hevc: false))
        let original = try XCTUnwrap(candidate(local: true, enabled: true))
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: original, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["maxVideoBitrate"], "100000"); XCTAssertEqual(q["videoResolution"], "3840x2160")
        XCTAssertEqual(q["offset"], "300"); XCTAssertEqual(q["session"], "owned")
        XCTAssertEqual(q["audioStreamID"], "22"); XCTAssertEqual(q["autoAdjustQuality"], "0")
        XCTAssertEqual(StreamQuality.high.maxBitrateKbps, 12000)
        XCTAssertEqual(StreamQuality.auto.maxBitrateKbps, 40000)
        XCTAssertEqual(StreamQuality.maximum.maxBitrateKbps, 40000)
        XCTAssertNotEqual(LocalPlexOriginalQuality.storageKey, StreamQuality.storageKey)
        XCTAssertTrue(url.absoluteString.contains("maxVideoBitrate=12000"))
        source.hasHDR10ColorMetadata = false
        XCTAssertNil(candidate(local: true, enabled: true))
    }

    func testExplicitOriginalFetchesMissingFactsAtCappedQualityWithoutApplyingRemotely() {
        var source = item(); source.audioChannelCount = nil
        XCTAssertTrue(PlexAPIService.needsOriginalVideoFacts(source, quality: .low, isLocal: true,
                                                            hevcCapable: true, originalLocal: true))
        XCTAssertFalse(PlexAPIService.needsOriginalVideoFacts(source, quality: .low, isLocal: false,
                                                             hevcCapable: true, originalLocal: true))
        XCTAssertFalse(PlexAPIService.needsOriginalVideoFacts(source, quality: .low, isLocal: true,
                                                             hevcCapable: true, originalLocal: false))
    }

    func testAutomaticRejectionAndDecisionFailureFallBackButExplicitOriginalDoesNot() async throws {
        let base = URL(string: "http://example.test/start.m3u8?session=candidate&offset=345&maxVideoBitrate=40000")!
        for quality in [StreamQuality.auto, .maximum] {
            for explicit in [false, true] {
                for decision in [PlexAPIService.TranscodeDecision.unknown,
                                 .init(code: "2000", text: "refused"),
                                 .init(code: "1001", text: "video reencoded"),
                                 .init(code: "1001", text: "audio changed", preservesOriginalVideo: true)] {
                    let url = try XCTUnwrap(PlexAPIService.preferredOriginalVideoURL(from: base, item: item(),
                        quality: quality, isLocal: true, hevcCapable: true, originalLocal: explicit))
                    var events: [String] = []
                    let normal = PlaybackResolution(url: base, playSessionId: "normal-fresh", isDirectPlay: false)
                    let result = await PlexAPIService.resolveOriginalVideoCandidate(url: url, sessionID: "candidate",
                        offsetSeconds: 345, requiresOriginalVideo: explicit,
                        prepare: { _ in decision }, stop: { events.append("stop:" + $0) },
                        fallback: { events.append("normal"); return (normal, true) })
                    XCTAssertEqual(events, explicit ? ["stop:candidate"] : ["stop:candidate", "normal"])
                    XCTAssertEqual(result?.resolution.playSessionId, explicit ? nil : "normal-fresh")
                    if !explicit {
                        XCTAssertEqual(result?.startsAtOffset, true)
                        XCTAssertEqual(result?.resolution.requiresOriginalVideo, false)
                    }
                }
            }
        }
    }

    func testAcceptedAutomaticCandidateKeepsRecoveryWhileExplicitOriginalStaysStrict() async {
        for explicit in [false, true] {
            var events: [String] = []
            let result = await PlexAPIService.resolveOriginalVideoCandidate(
                url: URL(string: "http://example.test/start.m3u8?offset=345")!, sessionID: "candidate",
                offsetSeconds: 345, requiresOriginalVideo: explicit,
                prepare: { _ in .init(code: "1001", text: "ok", preservesOriginalVideo: true, preservesOriginalAudio: true) },
                stop: { events.append($0) }, fallback: { events.append("fallback"); return nil })
            XCTAssertEqual(result?.resolution.requiresOriginalVideo, explicit)
            XCTAssertEqual(result?.resolution.playSessionId, "candidate")
            XCTAssertEqual(result?.startsAtOffset, true)
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testCancelledAutomaticDecisionDoesNotStartNormalPlayback() async {
        let result = await Task { () -> [String] in
            var events: [String] = []
            let result = await PlexAPIService.resolveOriginalVideoCandidate(
                url: URL(string: "http://example.test/start.m3u8")!, sessionID: "cancelled",
                offsetSeconds: 0, requiresOriginalVideo: false,
                prepare: { _ in withUnsafeCurrentTask { $0?.cancel() }; return .unknown },
                stop: { events.append("stop:" + $0) }, fallback: { events.append("fallback"); return nil })
            XCTAssertNil(result)
            return events
        }.value
        XCTAssertEqual(result, ["stop:cancelled"])
    }

    func testManualRetryRequiresLocalSupported4KHEVC() throws {
        let good = item()
        func allowed(_ i: PlexMediaItem, local: Bool = true, hevc: Bool = true) -> Bool {
            PlexAPIService.canRetryOriginalVideo(i, isLocal: local, hevcCapable: hevc)
        }
        XCTAssertTrue(allowed(good))
        XCTAssertFalse(allowed(good, local: false))
        XCTAssertFalse(allowed(good, hevc: false))
        var wide = good; wide.videoHeight = 1608; XCTAssertTrue(allowed(wide))
        for dimensions: (Int?, Int?) in [(1920, 1080), (1280, 720), (nil, 2160), (3840, nil), (7680, 4320)] {
            var i = good; i.videoWidth = dimensions.0; i.videoHeight = dimensions.1
            XCTAssertFalse(allowed(i))
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
        json["videoCodec"] = "h264"
        XCTAssertFalse(allowed(try JSONDecoder().decode(PlexMediaItem.self, from: JSONSerialization.data(withJSONObject: json))))
    }

}
