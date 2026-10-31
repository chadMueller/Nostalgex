' Runs NxMbScanServer (source/mediabrowser/MediaBrowserLibrary.brs) over the
' saved server answers in tests/fixtures/mediabrowser-server.json, served the
' way tests/gen-mediabrowser.mjs serves them to upstream's own
' fetchJellyfinLibraryFromServer, and holds it to that function's requests
' and items (tests/vectors/mediabrowser.json). Plus hand-written cases for
' the date parser and the Emby libraries path. Returns the failure count.

function NxRunMediaBrowserTests(vectorsPath as String, fixturePath as String) as Integer
    r = { pass: 0, fail: 0 }
    v = ParseJson(ReadAsciiFile(vectorsPath))
    fx = ParseJson(ReadAsciiFile(fixturePath))
    if v = invalid or fx = invalid then
        print "FAIL cannot read "; vectorsPath; " or "; fixturePath
        return 1
    end if

    fetcher = NxMbFixtureFetcher(fx)
    got = NxMbScanServer(fetcher, "jellyfin", fx.userId, 2)
    NxCheck(r, "scan returns items", NxToStr(got <> invalid), "true")
    if got <> invalid then
        NxCheck(r, "requests", fetcher.requests.Join(" | "), NxList(v.requests).Join(" | "))
        NxCheck(r, "item count", got.Count().ToStr(), NxList(v.items).Count().ToStr())
        ' Port-only fields: none reaches the filter or schedule.
        extras = { serverIndex: true, seasonNumber: true, episodeNumber: true, videoProfile: true, audioChannels: true, bitrate: true, videoWidth: true, videoHeight: true, audioTracks: true, forcedSubs: true, fullSubs: true }
        n = NxMinInt(got.Count(), NxList(v.items).Count())
        for i = 0 to n - 1
            want = v.items[i]
            it = got[i]
            label = "item " + i.ToStr() + " " + NxToStr(want.ratingKey)
            for each k in want
                NxCheck(r, label + " " + k, FormatJson(NxMbJsonValue(it[k])), FormatJson(NxMbJsonValue(want[k])))
            end for
            ' By lowercased name: on a TV an AA literal's keys iterate
            ' lowercased, while ParseJson's keep their case.
            wantKeys = {}
            for each k in want
                wantKeys[LCase(k)] = true
            end for
            for each k in it
                if not wantKeys.DoesExist(LCase(k)) and not extras.DoesExist(k) then NxCheck(r, label + " has no field " + k, "present", "absent")
            end for
            NxCheck(r, label + " serverIndex", NxToStr(it.serverIndex), "2")
        end for
        ' The best source's bitrate reaches the airing the player tunes
        ' (NxMbVideoQuery).
        byKey = {}
        for each it in got
            byKey[NxToStr(it.ratingKey)] = it
        end for
        bitrates = [["27ef0d2ba6cf3fe966bfc892bb26ac05", "19269"], ["m-two", "9000"], ["m-nobr", "0"]]
        for each pair in bitrates
            it = byKey[pair[0]]
            NxCheck(r, "bitrate " + pair[0] + " scanned", NxToStr(it <> invalid), "true")
            if it <> invalid then
                NxCheck(r, "bitrate " + pair[0], NxToStr(it.bitrate), pair[1])
                NxCheck(r, "bitrate " + pair[0] + " on the airing", NxToStr(NxGuideBlock({ item: it, startSec: 0, endSec: 60 }).bitrate), pair[1])
            end if
        end for
        ' A file with several audio tracks keeps them, in order, through to the
        ' airing; a file with one keeps nothing extra (NxMbAudioTracks).
        tracks = [["dad9edfd832172710274f226f2f48832", "1:eng:6:ac3:false 2:eng:2:aac:false 3:eng:2:aac:false 4:eng:2:aac:false 5:eng:2:aac:false"], ["27ef0d2ba6cf3fe966bfc892bb26ac05", "1:eng:2:aac:false 2:eng:2:aac:false 3:eng:2:aac:false"], ["38ef1ddba3d3b5306c330a51f6548870", ""], ["m-two", ""]]
        for each pair in tracks
            it = byKey[pair[0]]
            if it <> invalid then
                NxCheck(r, "audio tracks " + pair[0], NxMbTracksText(it.audioTracks), pair[1])
                NxCheck(r, "audio tracks " + pair[0] + " on the airing", NxMbTracksText(NxGuideBlock({ item: it, startSec: 0, endSec: 60 }).audioTracks), pair[1])
            end if
        end for
        ' And the chosen source's picture size, for the no-picture deadline
        ' (NxPictureDeadline). The fixture gives heights only.
        sizes = [["27ef0d2ba6cf3fe966bfc892bb26ac05", "2076"], ["m-tie", "2160"], ["m-two", "720"]]
        for each pair in sizes
            it = byKey[pair[0]]
            if it <> invalid then
                b = NxGuideBlock({ item: it, startSec: 0, endSec: 60 })
                NxCheck(r, "size " + pair[0] + " on the airing", NxToStr(b.videoHeight) + "x" + NxToStr(b.videoWidth), pair[1] + "x")
            end if
        end for
    end if

    ' A rejected token fails the scan.
    denied = NxMbFixtureFetcher(fx)
    denied.deny = true
    NxCheck(r, "rejected token: invalid", NxToStr(NxMbScanServer(denied, "jellyfin", fx.userId, 0) = invalid), "true")

    ' Emby lists libraries under the user.
    NxCheck(r, "views path, jellyfin", NxMbViewsPath("jellyfin", "u 1"), "/UserViews?userId=u%201")
    NxCheck(r, "views path, emby", NxMbViewsPath("emby", "u1"), "/Users/u1/Views")

    ' DateCreated as Date.parse reads it, floored to seconds. LongInteger
    ' literals: on Roku OS 16 these (all past 2^30) came out as Floats and
    ' printed as 1.69208e+09, while 951868799 stayed an Integer.
    dates = [
        ["2023-08-15T07:19:45.0000000Z", 1692083985&],
        ["1970-01-01T00:00:00Z", 0],
        ["2000-02-29T23:59:59.999Z", 951868799],
        ["2024-12-31T12:00:00+02:00", 1735639200&],
        ["2024-12-31T12:00:00-05:30", 1735666200&],
        ["2021-06-01", 1622505600&],
        ["2021-06-01T08:30Z", 1622536200&],
        ["not a date", 0],
        ["", 0],
        [invalid, 0]
    ]
    for each d in dates
        NxCheck(r, "date " + NxToStr(d[0]), NxMbUnixSeconds(d[0]).ToStr(), d[1].ToStr())
    end for


    ' What someone types as a server address.
    addrs = [
        ["172.16.0.5", "http://172.16.0.5:8096 http://172.16.0.5"],
        [" http://10.0.0.2:8920/web/index.html#!/home ", "http://10.0.0.2:8920"],
        ["https://media.example.org/jellyfin/", "https://media.example.org/jellyfin"],
        ["http://nas.local/emby", "http://nas.local:8096/emby http://nas.local/emby"],
        ["HTTPS://Box:443", "https://Box:443"],
        ["", ""],
        ["http://", ""]
    ]
    for each a in addrs
        NxCheck(r, "address " + a[0], NxMbAddressCandidates(a[0]).Join(" "), a[1])
    end for

    ' /System/Info/Public as each server answers it (trimmed).
    jf = { code: 200, json: { LocalAddress: "http://10.0.0.2:8096", ServerName: "den", Version: "12.2.0", ProductName: "Jellyfin Server", Id: "9a88", StartupWizardCompleted: true } }
    em = { code: 200, json: { LocalAddresses: [], RemoteAddresses: [], ServerName: "", Version: "4.10.1.0", Id: "1cc8" } }
    NxCheck(r, "public info, jellyfin", FormatJson(NxMbReadPublicInfo(jf)), FormatJson({ name: "den", id: "9a88", kind: "jellyfin", version: "12.2.0" }))
    NxCheck(r, "public info, emby", FormatJson(NxMbReadPublicInfo(em)), FormatJson({ name: "Emby Server", id: "1cc8", kind: "emby", version: "4.10.1.0" }))
    NxCheck(r, "public info, a web page", NxToStr(NxMbReadPublicInfo({ code: 200, json: invalid }) = invalid), "true")
    NxCheck(r, "public info, something else", NxToStr(NxMbReadPublicInfo({ code: 200, json: { ServerName: "x" } }) = invalid), "true")

    ' AuthenticateByName's answer.
    ok = { code: 200, json: { User: { Name: "n", Id: "u1" }, AccessToken: "t1", ServerId: "s1" } }
    NxCheck(r, "auth, accepted", FormatJson(NxMbReadAuth(ok)), FormatJson({ token: "t1", userId: "u1", serverId: "s1" }))
    NxCheck(r, "auth, refused", FormatJson(NxMbReadAuth({ code: 401, json: invalid })), """""")
    NxCheck(r, "auth, no token", FormatJson(NxMbReadAuth({ code: 200, json: { User: { Id: "u1" } } })), """""")
    NxCheck(r, "auth, unreachable", NxToStr(NxMbReadAuth({ code: -28, json: invalid }) = invalid), "true")

    ' The server stream's audio: Dolby only when the TV decodes it, 5.1 only
    ' when it decodes 5.1 AAC.
    NxCheck(r, "audio, no dolby, stereo", NxMbAudioQuery(false, false, false), "&AudioCodec=aac&TranscodingMaxAudioChannels=2")
    NxCheck(r, "audio, all of it", NxMbAudioQuery(true, true, true), "&AudioCodec=aac,ac3,eac3&TranscodingMaxAudioChannels=6")
    NxCheck(r, "audio, ac3 only", NxMbAudioQuery(true, false, false), "&AudioCodec=aac,ac3&TranscodingMaxAudioChannels=2")
    ' A source's Bitrate in kbps, rounded half up as the web's Math.round(Bitrate / 1000);
    ' 0 when it has none. 19,269,499 would round up through a Float (24 bits).
    NxCheck(r, "kbps: 19269041", NxMbBitrateKbps(19269041).ToStr(), "19269")
    NxCheck(r, "kbps: 19269499 rounds down", NxMbBitrateKbps(19269499).ToStr(), "19269")
    ' On a TV, Int(19269499) is 19269500. These two reach the same value the
    ' way a test table and a server's JSON would.
    for each v in [19269499]
        NxCheck(r, "kbps: 19269499 from an array literal", NxMbBitrateKbps(v).ToStr(), "19269")
    end for
    NxCheck(r, "kbps: 19269499 from ParseJson", NxMbBitrateKbps(ParseJson("{""b"": 19269499}").b).ToStr(), "19269")
    NxCheck(r, "kbps: 19269500 rounds up", NxMbBitrateKbps(19269500).ToStr(), "19270")
    NxCheck(r, "kbps: 500 rounds up", NxMbBitrateKbps(500).ToStr(), "1")
    NxCheck(r, "kbps: 499 rounds down", NxMbBitrateKbps(499).ToStr(), "0")
    NxCheck(r, "kbps: a Float", NxMbBitrateKbps(19269041.9).ToStr(), "19269")
    NxCheck(r, "kbps: over 2 Gb/s", NxMbBitrateKbps(2500000000#).ToStr(), "2500000")
    NxCheck(r, "kbps: zero", NxMbBitrateKbps(0).ToStr(), "0")
    NxCheck(r, "kbps: negative", NxMbBitrateKbps(-5).ToStr(), "0")
    NxCheck(r, "kbps: missing", NxMbBitrateKbps(invalid).ToStr(), "0")
    NxCheck(r, "video, no bitrate copies", NxMbVideoQuery(invalid), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, 19 Mb/s copies", NxMbVideoQuery(19269), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, 20 Mb/s copies", NxMbVideoQuery(20000), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, just over 20 Mb/s re-encodes", NxMbVideoQuery(20001), "&VideoBitrate=40000000&MaxWidth=3840&AllowVideoStreamCopy=false")
    NxCheck(r, "video, 29 Mb/s re-encodes", NxMbVideoQuery(29000), "&VideoBitrate=40000000&MaxWidth=3840&AllowVideoStreamCopy=false")
    NxCheck(r, "video, re-encode on a 1080p TV is 1080p", NxMbVideoQuery(29000, "server", 1920), "&VideoBitrate=40000000&MaxWidth=1920&AllowVideoStreamCopy=false")
    NxCheck(r, "video, a copy on a 1080p TV stays 3840", NxMbVideoQuery(19269, "server", 1920), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, no bitrate on a 1080p TV copies", NxMbVideoQuery(invalid, "server", 1920), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, 1080p rung whatever the TV", NxMbVideoQuery(29000, "capped", 1280), "&VideoBitrate=8000000&MaxWidth=1920&AllowVideoStreamCopy=false")
    NxCheck(r, "width, 2160p60", NxMaxWidthFor("2160p60").ToStr(), "3840")
    NxCheck(r, "width, 2160p60b10", NxMaxWidthFor("2160p60b10").ToStr(), "3840")
    NxCheck(r, "width, 1080p", NxMaxWidthFor("1080p").ToStr(), "1920")
    NxCheck(r, "width, 1080i", NxMaxWidthFor("1080i").ToStr(), "1920")
    NxCheck(r, "width, 720p", NxMaxWidthFor("720p").ToStr(), "1280")
    NxCheck(r, "width, unreadable keeps 3840", NxMaxWidthFor("").ToStr(), "3840")
    NxCheck(r, "audio, eac3 only, 5.1", NxMbAudioQuery(false, true, true), "&AudioCodec=aac,eac3&TranscodingMaxAudioChannels=6")

    ' The loading screen names the kind it scans (#95).
    NxCheck(r, "scan headline, jellyfin", NxScanHeadline("jellyfin"), "SCANNING JELLYFIN LIBRARY")
    NxCheck(r, "scan headline, emby", NxScanHeadline("emby"), "SCANNING EMBY LIBRARY")
    NxCheck(r, "scan headline, plex as before", NxScanHeadline("plex"), "SCANNING PLEX LIBRARY")

    ' The note under the logo while a library is read for the first time on this
    ' TV (source/util/LoadingNote.brs): a first-ever setup keeps its line; a
    ' library saved before and cleared by the TV (savedBefore, from the
    ' registry's librarySaved) says so, with no time; a library still saved
    ' shows none.
    NxCheck(r, "note: first setup, as before", NxLoadingNote(true, false), "First setup can take a few minutes to scan and build channels.")
    NxCheck(r, "note: cleared by the TV", NxLoadingNote(true, true), "The TV cleared the saved library, so it's being read again.")
    NxCheck(r, "note: cleared, no time estimate", NxToStr(Instr(1, LCase(NxLoadingNote(true, true)), "minute") > 0), "false")
    NxCheck(r, "note: cleared, fits the line", NxToStr(Len(NxLoadingNote(true, true)) <= 70), "true")
    NxCheck(r, "note: library still saved", NxLoadingNote(false, false), "")
    NxCheck(r, "note: not a first run, whatever the flag", NxLoadingNote(false, true), "")
    ' The loading screen uses it, and holds no copy of the old lines.
    view = ReadAsciiFile("pkg:/components/LoadingView.brs")
    NxCheck(r, "note: LoadingView calls NxLoadingNote", NxToStr(Instr(1, view, "NxLoadingNote(t.firstRun, t.savedBefore)") > 0), "true")
    NxCheck(r, "note: LoadingView has no copy of the old line", NxToStr(Instr(1, view, "cleared the saved library") > 0), "false")

    print "mediabrowser cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail + NxRunDirectPlayTests() + NxRunAudioPickTests() + NxRunForcedSubTests() + NxRunFullSubTests()
end function

' Forced subtitles (#63): which tracks the scan keeps (NxMbForcedSubs),
' which one an airing shows (NxMbForcedSub, upstream's forcedSubtitleToBurn
' cases), its address, and the airings whose file is asked for ahead of time
' (NxSubtitleWarmList).
function NxRunForcedSubTests() as Integer
    r = { pass: 0, fail: 0 }
    src = { MediaStreams: [
        { Type: "Video", Index: 0, Codec: "h264" }
        { Type: "Subtitle", Index: 2, Language: "eng", Codec: "subrip", IsForced: true }
        { Type: "Subtitle", Index: 3, Language: "eng", Codec: "PGSSUB", IsForced: true }
        { Type: "Subtitle", Index: 4, Language: "eng", Codec: "subrip", IsForced: false, IsDefault: true }
        { Type: "Subtitle", Index: 5, Language: "ger", Codec: "ass", IsForced: true }
        { Type: "Subtitle", Index: 6, Codec: "srt", IsForced: true }
    ] }
    kept = []
    for each t in NxList(NxMbForcedSubs(src))
        kept.Push(NxToStr(t.index) + ":" + NxToStr(t.language))
    end for
    NxCheck(r, "forced text tracks, in order", kept.Join(" "), "2:eng 5:ger 6:")
    NxCheck(r, "no forced track keeps nothing", NxToStr(NxMbForcedSubs({ MediaStreams: [src.MediaStreams[3]] }) = invalid), "true")
    NxCheck(r, "an image forced track alone keeps nothing", NxToStr(NxMbForcedSubs({ MediaStreams: [src.MediaStreams[2]] }) = invalid), "true")
    NxCheck(r, "no streams keeps nothing", NxToStr(NxMbForcedSubs({}) = invalid), "true")
    it = { forcedSubs: NxMbForcedSubs(src) }
    NxCheck(r, "english viewer: the english forced track", NxToStr(NxMbForcedSub(it, "en").index), "2")
    NxCheck(r, "german viewer: ger matches de", NxToStr(NxMbForcedSub(it, "de").index), "5")
    NxCheck(r, "french viewer: none", NxToStr(NxMbForcedSub(it, "fr") = invalid), "true")
    NxCheck(r, "an airing with no forced track", NxToStr(NxMbForcedSub({}, "en") = invalid), "true")
    NxCheck(r, "deu matches de too", NxToStr(NxMbForcedSub({ forcedSubs: [{ index: 7, language: "deu" }] }, "de").index), "7")
    NxCheck(r, "forced: spanish skips estonian", NxToStr(NxMbForcedSub({ forcedSubs: [{ index: 3, language: "est" }, { index: 4, language: "spa" }] }, "es").index), "4")
    NxCheck(r, "forced: japanese skips javanese", NxToStr(NxMbForcedSub({ forcedSubs: [{ index: 3, language: "jav" }] }, "ja") = invalid), "true")
    NxCheck(r, "forced: czech takes cze", NxToStr(NxMbForcedSub({ forcedSubs: [{ index: 3, language: "cze" }] }, "cs") <> invalid), "true")
    NxCheck(r, "the address", NxMbSubtitlePath("1650", "mediasource_1650", 4), "/Videos/1650/mediasource_1650/Subtitles/4/0/Stream.srt")
    on = { startSec: 1000, endSec: 2800, ratingKey: "a", partKey: "pa", serverIndex: 0, forcedSubs: [{ index: 2, language: "eng" }] }
    soon = { startSec: 4000, endSec: 5000, ratingKey: "b", partKey: "pb", serverIndex: 0, forcedSubs: [{ index: 3, language: "eng" }] }
    later = { startSec: 6000, endSec: 7000, ratingKey: "c", partKey: "pc", serverIndex: 0, forcedSubs: [{ index: 2, language: "eng" }] }
    gone = { startSec: 0, endSec: 900, ratingKey: "d", partKey: "pd", serverIndex: 0, forcedSubs: [{ index: 2, language: "eng" }] }
    plex = { startSec: 1000, endSec: 2800, ratingKey: "e", partKey: "pe", serverIndex: 1, forcedSubs: [{ index: 2, language: "eng" }] }
    french = { startSec: 1000, endSec: 2800, ratingKey: "f", partKey: "pf", serverIndex: 0, forcedSubs: [{ index: 2, language: "fre" }] }
    plain = { startSec: 1000, endSec: 2800, ratingKey: "g", partKey: "pg", serverIndex: 0 }
    channels = [{ blocks: [gone, on, soon, later] }, { blocks: [on, plex, french, plain] }]
    servers = { "0": "http://emby:8096" }
    urls = NxSubtitleWarmList(channels, 1200, 3600, "en", false, ["en"], servers, {})
    NxCheck(r, "warm: on now and within the hour, once each", urls.Join(" "), "http://emby:8096/Videos/a/pa/Subtitles/2/0/Stream.srt http://emby:8096/Videos/b/pb/Subtitles/3/0/Stream.srt")
    done = {}
    done[urls[0]] = true
    NxCheck(r, "warm: asked before, not again", NxSubtitleWarmList(channels, 1200, 3600, "en", false, ["en"], servers, done).Join(" "), urls[1])
    NxCheck(r, "warm: another language", NxSubtitleWarmList(channels, 1200, 3600, "fr", false, ["en"], servers, {}).Join(" "), "http://emby:8096/Videos/f/pf/Subtitles/2/0/Stream.srt")
    NxCheck(r, "warm: no channels", NxSubtitleWarmList(invalid, 1200, 3600, "en", false, ["en"], servers, {}).Count().ToStr(), "0")
    print "forced subtitle cases: "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' Full subtitles on a server stream (#120): which tracks the scan keeps
' (NxMbFullSubs), which one an airing shows (NxMbFullSub: in the language
' or none, no fallback to the first), the sidecars a stream carries
' (NxMbSubtitleSidecars: the full one on a server stream with ALWAYS only),
' and the warm-up with ALWAYS for airings that won't play as stored.
function NxRunFullSubTests() as Integer
    r = { pass: 0, fail: 0 }
    src = { MediaStreams: [
        { Type: "Video", Index: 0, Codec: "h264" }
        { Type: "Subtitle", Index: 2, Language: "eng", Codec: "subrip", IsForced: true }
        { Type: "Subtitle", Index: 3, Language: "fre", Codec: "PGSSUB" }
        { Type: "Subtitle", Index: 4, Language: "eng", Codec: "subrip", IsDefault: true }
        { Type: "Subtitle", Index: 5, Language: "eng", Codec: "subrip", Title: "SDH" }
        { Type: "Subtitle", Index: 6, Codec: "srt" }
        { Type: "Subtitle", Index: 7, Language: "est", Codec: "ass" }
        { Type: "Subtitle", Index: 8, Language: "spa", Codec: "subrip" }
        { Type: "Subtitle", Index: 9, Language: "FRE", Codec: "srt" }
    ] }
    kept = []
    for each t in NxList(NxMbFullSubs(src))
        kept.Push(NxToStr(t.index) + ":" + NxToStr(t.language))
    end for
    NxCheck(r, "full: text, not forced, first per language", kept.Join(" "), "4:eng 7:est 8:spa 9:fre")
    NxCheck(r, "full: forced only keeps nothing", NxToStr(NxMbFullSubs({ MediaStreams: [src.MediaStreams[1]] }) = invalid), "true")
    NxCheck(r, "full: no language keeps nothing", NxToStr(NxMbFullSubs({ MediaStreams: [src.MediaStreams[5]] }) = invalid), "true")
    NxCheck(r, "full: no streams keeps nothing", NxToStr(NxMbFullSubs({}) = invalid), "true")
    it = { fullSubs: NxMbFullSubs(src) }
    NxCheck(r, "full: english viewer, the first english", NxToStr(NxMbFullSub(it, "en").index), "4")
    NxCheck(r, "full: spanish skips estonian", NxToStr(NxMbFullSub(it, "es").index), "8")
    NxCheck(r, "full: french takes FRE", NxToStr(NxMbFullSub(it, "fr").index), "9")
    NxCheck(r, "full: german, none, not the first track", NxToStr(NxMbFullSub(it, "de") = invalid), "true")
    NxCheck(r, "full: an airing with none", NxToStr(NxMbFullSub({}, "en") = invalid), "true")

    b = { ratingKey: "51239", partKey: "ms51239", forcedSubs: [{ index: 3, language: "eng" }], fullSubs: [{ index: 4, language: "eng" }] }
    base = "http://emby:8096"
    NxCheck(r, "sidecars: always, server stream, forced then full", NxFullSubTrackList(NxMbSubtitleSidecars(b, base, "en", true, false)), "Forced:http://emby:8096/Videos/51239/ms51239/Subtitles/3/0/Stream.srt eng:http://emby:8096/Videos/51239/ms51239/Subtitles/4/0/Stream.srt")
    NxCheck(r, "sidecars: always, direct play, forced only", NxFullSubTrackList(NxMbSubtitleSidecars(b, base, "en", true, true)), "Forced:http://emby:8096/Videos/51239/ms51239/Subtitles/3/0/Stream.srt")
    NxCheck(r, "sidecars: not always, forced only", NxFullSubTrackList(NxMbSubtitleSidecars(b, base, "en", false, false)), "Forced:http://emby:8096/Videos/51239/ms51239/Subtitles/3/0/Stream.srt")
    noForced = { ratingKey: "51239", partKey: "ms51239", fullSubs: [{ index: 4, language: "eng" }] }
    NxCheck(r, "sidecars: always, no forced track, full alone", NxFullSubTrackList(NxMbSubtitleSidecars(noForced, base, "en", true, false)), "eng:http://emby:8096/Videos/51239/ms51239/Subtitles/4/0/Stream.srt")
    NxCheck(r, "sidecars: always, none in the language, none", NxFullSubTrackList(NxMbSubtitleSidecars(b, base, "de", true, false)), "")
    NxCheck(r, "sidecars: not always, no forced, none", NxFullSubTrackList(NxMbSubtitleSidecars(noForced, base, "en", false, false)), "")

    on = { startSec: 1000, endSec: 2800, ratingKey: "a", partKey: "pa", serverIndex: 0, container: "mkv", videoCodec: "h264", audioCodec: "opus", fullSubs: [{ index: 4, language: "eng" }] }
    both = { startSec: 1000, endSec: 2800, ratingKey: "b", partKey: "pb", serverIndex: 0, container: "mkv", videoCodec: "h264", audioCodec: "opus", forcedSubs: [{ index: 2, language: "eng" }], fullSubs: [{ index: 4, language: "eng" }] }
    stored = { startSec: 1000, endSec: 2800, ratingKey: "c", partKey: "pc", serverIndex: 0, container: "mp4", videoCodec: "h264", audioCodec: "aac", audioChannels: 2, videoProfile: "high", fullSubs: [{ index: 4, language: "eng" }] }
    later = { startSec: 6000, endSec: 7000, ratingKey: "d", partKey: "pd", serverIndex: 0, container: "mkv", videoCodec: "h264", audioCodec: "opus", fullSubs: [{ index: 4, language: "eng" }] }
    french = { startSec: 1000, endSec: 2800, ratingKey: "e", partKey: "pe", serverIndex: 0, container: "mkv", videoCodec: "h264", audioCodec: "opus", fullSubs: [{ index: 4, language: "fre" }] }
    channels = [{ blocks: [on, both, stored, later, french] }]
    servers = { "0": "http://emby:8096" }
    ' The stored one is asked for only where this TV wouldn't play it as
    ' stored: the answer is the device's, off the TV too.
    want = "http://emby:8096/Videos/a/pa/Subtitles/4/0/Stream.srt http://emby:8096/Videos/b/pb/Subtitles/2/0/Stream.srt http://emby:8096/Videos/b/pb/Subtitles/4/0/Stream.srt"
    if not NxMbDirectPlays(stored, servers["0"]) then want = want + " http://emby:8096/Videos/c/pc/Subtitles/4/0/Stream.srt"
    print "full subtitle cases: an AAC MP4 plays as stored here: "; NxMbDirectPlays(stored, servers["0"])
    NxCheck(r, "warm: always, server streams, forced then full", NxSubtitleWarmList(channels, 1200, 3600, "en", true, ["en"], servers, {}).Join(" "), want)
    ' STREAM QUALITY's ceiling sends a file over it to the server, so its
    ' full track is asked for wherever this TV would play it as stored.
    stored.bitrate = 3000
    cWant = "http://emby:8096/Videos/a/pa/Subtitles/4/0/Stream.srt http://emby:8096/Videos/b/pb/Subtitles/2/0/Stream.srt http://emby:8096/Videos/b/pb/Subtitles/4/0/Stream.srt http://emby:8096/Videos/c/pc/Subtitles/4/0/Stream.srt"
    NxCheck(r, "warm: always, LOW sends a 3 Mb/s file to the server", NxSubtitleWarmList(channels, 1200, 3600, "en", true, ["en"], servers, {}, "low").Join(" "), cWant)
    NxCheck(r, "direct: LOW holds a 3 Mb/s file off direct play", FormatJson(NxMbDirectPlays(stored, servers["0"], "low")), "false")
    NxCheck(r, "warm: always, HIGH leaves a 3 Mb/s file as at Auto", NxSubtitleWarmList(channels, 1200, 3600, "en", true, ["en"], servers, {}, "high").Join(" "), want)
    stored.Delete("bitrate")
    NxCheck(r, "warm: not always, forced only", NxSubtitleWarmList(channels, 1200, 3600, "en", false, ["en"], servers, {}).Join(" "), "http://emby:8096/Videos/b/pb/Subtitles/2/0/Stream.srt")
    NxCheck(r, "warm: always, no track in the language", NxSubtitleWarmList(channels, 1200, 3600, "de", true, ["en"], servers, {}).Count().ToStr(), "0")
    print "full subtitle cases: "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' Sidecars as "<Description or Language>:<TrackName>", space-separated.
function NxFullSubTrackList(tracks as Object) as String
    out = []
    for each t in tracks
        label = NxToStr(t.Description)
        if label = "" then label = NxToStr(t.Language)
        out.Push(label + ":" + NxToStr(t.TrackName))
    end for
    return out.Join(" ")
end function

' NxMbPreferredAudioIndex, the cases of upstream's
' Nostalgex/NostalgexTests/AudioTrackSelectionTests.swift transcribed (a
' track list holds only audio tracks here, as NxMbAudioTracks keeps them),
' and NxMbAudioPick, which decides direct play on the picked track.
function NxRunAudioPickTests() as Integer
    r = { pass: 0, fail: 0 }
    ' testEnglishBeatsADefaultFlaggedSpanishTrack: the exact Joe Dirt layout.
    joeDirt = [NxMbTrack(1, "spa", 2, "aac", true), NxMbTrack(2, "eng", 6, "aac", false)]
    NxCheck(r, "english beats a default spanish track", NxToStr(NxMbPreferredAudioIndex(joeDirt, ["en"])), "2")
    ' testMoreChannelsWinsAmongTracksInTheViewersLanguage
    NxCheck(r, "a 5.1 english mix beats a stereo english default", NxToStr(NxMbPreferredAudioIndex([NxMbTrack(1, "eng", 2, invalid, true), NxMbTrack(2, "eng", 6, invalid, false)], ["en"])), "2")
    ' testLocaleIdentifiersMatchThreeLetterTags
    fr = [NxMbTrack(1, "fre", invalid, invalid, true), NxMbTrack(2, "eng", invalid, invalid, false)]
    NxCheck(r, "an english viewer gets eng", NxToStr(NxMbPreferredAudioIndex(fr, ["en"])), "2")
    NxCheck(r, "a french viewer keeps the french track", NxToStr(NxMbPreferredAudioIndex(fr, ["fr"])), "1")
    ' testFallsBackToTheFilesDefaultWhenNoTrackIsInTheViewersLanguage
    NxCheck(r, "the file's default when none matches", NxToStr(NxMbPreferredAudioIndex([NxMbTrack(1, "jpn", invalid, invalid, false), NxMbTrack(2, "kor", invalid, invalid, true)], ["de"])), "2")
    ' testASingleAudioTrackIsLeftToTheServer
    NxCheck(r, "one track is left to the server", NxToStr(NxMbPreferredAudioIndex([NxMbTrack(1, "eng", invalid, invalid, false)], ["en"]) = invalid), "true")
    NxCheck(r, "no tracks are left to the server", NxToStr(NxMbPreferredAudioIndex([], ["en"]) = invalid), "true")
    ' Port-only: the first track when nothing matches and none is default;
    ' English with no TV language; the first of equal channel counts.
    NxCheck(r, "the first track at last", NxToStr(NxMbPreferredAudioIndex([NxMbTrack(3, "jpn", 2, invalid, false), NxMbTrack(4, "kor", 2, invalid, false)], ["de"])), "3")
    NxCheck(r, "english with no tv language", NxToStr(NxMbPreferredAudioIndex(joeDirt, [])), "2")
    NxCheck(r, "the first of equals", NxToStr(NxMbPreferredAudioIndex([NxMbTrack(1, "por", 6, invalid, true), NxMbTrack(2, "eng", 6, invalid, false), NxMbTrack(3, "en", 6, invalid, false)], ["en"])), "2")
    NxCheck(r, "an untagged track never matches", NxToStr(NxMbPreferredAudioIndex([NxMbTrack(1, invalid, 6, invalid, false), NxMbTrack(2, "", 6, invalid, true)], ["en"])), "2")

    ' AUDIO LANGUAGE first (#62), then upstream's order with English.
    deStereo = [NxMbTrack(1, "eng", 6, invalid, true), NxMbTrack(2, "ger", 2, invalid, false)]
    NxCheck(r, "language: german stereo beats an english 5.1 default", NxToStr(NxMbChosenAudioIndex(deStereo, ["de"])), "2")
    NxCheck(r, "language: upstream's order would take the 5.1", NxToStr(NxMbPreferredAudioIndex(deStereo, ["de"])), "1")
    NxCheck(r, "language: most channels within it", NxToStr(NxMbChosenAudioIndex([NxMbTrack(1, "fre", 2, invalid, true), NxMbTrack(2, "eng", 6, invalid, false), NxMbTrack(3, "fra", 6, invalid, false)], ["fr"])), "3")
    NxCheck(r, "language: none in it falls back to english", NxToStr(NxMbChosenAudioIndex(joeDirt, ["ja"])), "2")
    NxCheck(r, "language: none in it and no english, the default", NxToStr(NxMbChosenAudioIndex([NxMbTrack(1, "jpn", 2, invalid, false), NxMbTrack(2, "kor", 2, invalid, true)], ["de"])), "2")
    NxCheck(r, "language: english is upstream's order", NxToStr(NxMbChosenAudioIndex(joeDirt, ["en"])), NxToStr(NxMbPreferredAudioIndex(joeDirt, ["en"])))
    NxCheck(r, "language: one track is left to the server", NxToStr(NxMbChosenAudioIndex([NxMbTrack(1, "ger", 2, invalid, false)], ["de"]) = invalid), "true")
    NxCheck(r, "language: the pick follows it", NxToStr(NxMbAudioPick({ audioTracks: deStereo }, ["de"]).index), "2")
    ' One code per language (#119): an Estonian 5.1 is not Spanish.
    estSpa = [NxMbTrack(1, "est", 6, invalid, false), NxMbTrack(2, "spa", 2, invalid, false), NxMbTrack(3, "eng", 2, invalid, true)]
    NxCheck(r, "language: spanish skips an estonian 5.1", NxToStr(NxMbChosenAudioIndex(estSpa, ["es"])), "2")
    NxCheck(r, "language: czech takes cze", NxToStr(NxMbChosenAudioIndex([NxMbTrack(1, "eng", 2, invalid, true), NxMbTrack(2, "cze", 2, invalid, false)], ["cs"])), "2")
    NxCheck(r, "language: arabic skips armenian", NxToStr(NxMbChosenAudioIndex([NxMbTrack(1, "arm", 6, invalid, false), NxMbTrack(2, "ara", 2, invalid, false)], ["ar"])), "2")
    NxCheck(r, "upstream's order: estonian is not spanish", NxToStr(NxMbPreferredAudioIndex([NxMbTrack(1, "est", 6, invalid, false), NxMbTrack(2, "kor", 2, invalid, true)], ["es"])), "2")

    ' Issue #78: O Brother, Where Art Thou?, Portuguese E-AC-3 5.1 the
    ' default ahead of English E-AC-3 5.1.
    oBrother = { audioCodec: "eac3", audioChannels: 6, container: "mkv", audioTracks: [NxMbTrack(1, "por", 6, "eac3", true), NxMbTrack(2, "eng", 6, "eac3", false)] }
    pick = NxMbAudioPick(oBrother, ["en"])
    NxCheck(r, "o brother: english", NxToStr(pick.index) + "@" + NxToStr(pick.position), "2@1")
    NxCheck(r, "o brother: language and count", NxToStr(pick.language) + "/" + NxToStr(pick.count), "eng/2")
    ' Direct play is decided on the picked track: a dub in AAC ahead of an
    ' Opus original is not a direct play because the first track decodes.
    dub = { audioCodec: "aac", audioChannels: 2, container: "mkv", audioTracks: [NxMbTrack(1, "por", 2, "aac", true), NxMbTrack(2, "eng", 6, "opus", false)] }
    pick = NxMbAudioPick(dub, ["en"])
    NxCheck(r, "decided on the picked track", NxToStr(pick.airing.audioCodec) + "/" + NxToStr(pick.airing.audioChannels), "opus/6")
    NxCheck(r, "the airing itself is unchanged", dub.audioCodec, "aac")
    NxCheck(r, "the rest of the airing comes along", NxToStr(pick.airing.container), "mkv")
    pick = NxMbAudioPick({ audioCodec: "aac", audioChannels: 2 }, ["en"])
    NxCheck(r, "no tracks, no pick", NxToStr(pick.index = invalid and pick.position = invalid), "true")
    NxCheck(r, "no tracks, the airing as it is", NxToStr(pick.airing.audioCodec), "aac")

    ' NxAudioTrackToSelect: the player's list as a Roku TV gave it for the
    ' lab's dubbed clip (2026-10-23, TCL 55R617), "2=por 3=eng".
    roku = [{ Track: "2", Language: "por" }, { Track: "3", Language: "eng" }]
    NxCheck(r, "select by position", NxToStr(NxAudioTrackToSelect(roku, { position: 1, language: "eng", count: 2 })), "3")
    NxCheck(r, "select the first by position", NxToStr(NxAudioTrackToSelect(roku, { position: 0, language: "por", count: 2 })), "2")
    ' A list shorter than the file's: by language, as a position could name
    ' another track ([DTS fre, AAC eng, AAC por] listed as eng, por).
    short = [{ Track: "3", Language: "eng" }, { Track: "4", Language: "por" }]
    NxCheck(r, "a short list goes by language", NxToStr(NxAudioTrackToSelect(short, { position: 1, language: "eng", count: 3 })), "3")
    NxCheck(r, "two- and three-letter tags match", NxToStr(NxAudioTrackToSelect([{ Track: "7", Language: "en" }], { position: 2, language: "eng", count: 3 })), "7")
    NxCheck(r, "the language not listed: the player's choice", NxToStr(NxAudioTrackToSelect(short, { position: 0, language: "fre", count: 3 }) = invalid), "true")
    NxCheck(r, "no language on a short list: the player's choice", NxToStr(NxAudioTrackToSelect(short, { position: 0, language: invalid, count: 3 }) = invalid), "true")
    NxCheck(r, "no pick", NxToStr(NxAudioTrackToSelect(roku, invalid) = invalid), "true")
    print "audio pick cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

function NxMbTrack(index as Integer, language as Dynamic, channels as Dynamic, codec as Dynamic, isDefault as Boolean) as Object
    return { index: index, language: language, channels: channels, codec: codec, isDefault: isDefault }
end function

' "index:language:channels:codec:isDefault" per track, space-separated; ""
' for none.
function NxMbTracksText(tracks as Dynamic) as String
    out = []
    for each t in NxList(tracks)
        out.Push(NxToStr(t.index) + ":" + NxToStr(t.language) + ":" + NxToStr(t.channels) + ":" + NxToStr(t.codec) + ":" + NxToStr(t.isDefault))
    end for
    return out.Join(" ")
end function

' source/util/DirectPlay.brs: the questions put to the TV before direct
' play, for Plex's and Jellyfin/Emby's field values, and how its answers read.
function NxRunDirectPlayTests() as Integer
    r = { pass: 0, fail: 0 }
    q = NxDecodeQueries({ videoCodec: "h264", videoProfile: "high", audioCodec: "aac", audioChannels: 2, container: "mp4" })
    NxCheck(r, "plex h264 codec", q.video.Codec, "mpeg4 avc")
    NxCheck(r, "plex h264 profile", NxToStr(q.video.Profile), "high")
    NxCheck(r, "no container asked", NxToStr(q.video.DoesExist("Container")), "false")
    NxCheck(r, "plex aac codec", q.audio.Codec, "aac")
    NxCheck(r, "audio decides on the codec", NxToStr(q.audio.DoesExist("ChCnt")), "false")
    NxCheck(r, "plex aac channels asked apart", q.channels.Codec + "/" + NxToStr(q.channels.ChCnt), "aac/2")
    q = NxDecodeQueries({ videoCodec: "hevc", videoProfile: "main 10", audioCodec: "eac3", audioChannels: 6 })
    NxCheck(r, "hevc main 10", q.video.Codec + "/" + q.video.Profile, "hevc/main 10")
    NxCheck(r, "eac3 5.1", q.audio.Codec + "/" + NxToStr(q.channels.ChCnt), "eac3/6")
    q = NxDecodeQueries({ videoCodec: "H264", videoProfile: " High 10 ", audioCodec: "AC3", audioChannels: 6 })
    NxCheck(r, "jellyfin 10-bit h264", q.video.Codec + "/" + q.video.Profile, "mpeg4 avc/high 10")
    NxCheck(r, "jellyfin ac3", q.audio.Codec, "ac3")
    q = NxDecodeQueries({ videoCodec: "hevc", audioCodec: "aac", audioChannels: 0 })
    NxCheck(r, "no profile asked", NxToStr(q.video.DoesExist("Profile")), "false")
    NxCheck(r, "no channels asked", NxToStr(q.channels = invalid), "true")
    q = NxDecodeQueries({ videoCodec: "h264", videoProfile: "Constrained Baseline", audioCodec: "aac" })
    NxCheck(r, "constrained baseline", q.video.Profile, "main")
    q = NxDecodeQueries({ videoCodec: "h264", videoProfile: "baseline", audioCodec: "aac" })
    NxCheck(r, "baseline", q.video.Profile, "main")
    q = NxDecodeQueries({})
    NxCheck(r, "nothing known", q.video.Codec + "|" + q.audio.Codec, "|")

    NxCheck(r, "answer yes", NxToStr(NxDecodeAnswer({ Result: true })), "true")
    NxCheck(r, "answer no", NxToStr(NxDecodeAnswer({ Result: false, Codec: "hevc" })), "false")
    NxCheck(r, "no answer", NxToStr(NxDecodeAnswer(invalid)), "false")
    NxCheck(r, "answer without Result", NxToStr(NxDecodeAnswer({})), "false")
    NxCheck(r, "answer not a boolean", NxToStr(NxDecodeAnswer({ Result: "true" })), "false")

    yes = { Result: true }
    no = { Result: false }
    q = NxDecodeQueries({ videoCodec: "hevc", audioCodec: "aac", audioChannels: 6 })
    NxCheck(r, "all yes plays as stored", NxDecodeNos(q, { video: yes, audio: yes, channels: yes }).Count().ToStr(), "0")
    nos = NxDecodeNos(q, { video: yes, audio: yes, channels: no })
    NxCheck(r, "5.1 aac no goes to the server", nos.Count().ToStr() + " " + nos[0].Codec + "/" + NxToStr(nos[0].ChCnt), "1 aac/6")
    nos = NxDecodeNos(q, { video: yes, audio: no, channels: no })
    NxCheck(r, "codec no names the codec only", nos.Count().ToStr() + " " + NxToStr(nos[0].DoesExist("ChCnt")), "1 false")
    nos = NxDecodeNos(q, { video: no, audio: yes, channels: yes })
    NxCheck(r, "video no", nos.Count().ToStr() + " " + nos[0].Codec, "1 hevc")
    q = NxDecodeQueries({ videoCodec: "hevc", audioCodec: "aac" })
    NxCheck(r, "channels unknown plays as stored", NxDecodeNos(q, { video: yes, audio: yes }).Count().ToStr(), "0")
    print "direct play cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' JSON null and a missing field read alike, as the vectors drop neither.
function NxMbJsonValue(x as Dynamic) as Dynamic
    if x = invalid then return invalid
    return x
end function

' A fetcher over the fixture, as gen-mediabrowser.mjs's serveFixture: the
' libraries list, then /Items by ParentId and IncludeItemTypes, paged by
' StartIndex and Limit. A parent in `fail` answers as a failed request.
function NxMbFixtureFetcher(fx as Object) as Object
    return {
        fx: fx,
        requests: [],
        auth: false,
        deny: false,
        getJSON: function(path as String) as Dynamic
            m.requests.Push(path)
            if m.deny then
                m.auth = true
                return invalid
            end if
            q = {}
            cut = Instr(1, path, "?")
            base = path
            if cut > 0 then
                base = Left(path, cut - 1)
                for each pair in Mid(path, cut + 1).Split("&")
                    eq = Instr(1, pair, "=")
                    if eq > 0 then q[Left(pair, eq - 1)] = Mid(pair, eq + 1)
                end for
            end if
            if base = "/UserViews" or CreateObject("roRegex", "^/Users/[^/]+/Views$", "").IsMatch(base) then
                return { Items: m.fx.views, TotalRecordCount: m.fx.views.Count() }
            end if
            if base <> "/Items" then return invalid
            if NxHasValue(NxList(m.fx.fail), q.ParentId) then return invalid
            all = []
            for each it in NxList(m.fx.items[q.ParentId])
                if it.Type = q.IncludeItemTypes then all.Push(it)
            end for
            start = q.StartIndex.ToInt()
            limit = q.Limit.ToInt()
            page = []
            for i = start to NxMinInt(start + limit, all.Count()) - 1
                page.Push(all[i])
            end for
            return { Items: page, TotalRecordCount: all.Count() }
        end function,
        getMany: function(paths as Object) as Object
            out = []
            for each p in paths
                out.Push(m.getJSON(p))
            end for
            return out
        end function
    }
end function
