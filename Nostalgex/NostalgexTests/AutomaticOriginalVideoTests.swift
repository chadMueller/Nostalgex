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
    private func eligible(_ i: PlexMediaItem, quality: StreamQuality = .auto, local: Bool = true, hevc: Bool = true) -> Bool {
        PlexAPIService.shouldPreferOriginalVideo(i, quality: quality, isLocal: local, hevcCapable: hevc)
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

}
