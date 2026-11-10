' Runs NxMbScanServer (source/mediabrowser/MediaBrowserLibrary.brs) over the
' saved server answers in tests/fixtures/mediabrowser-server.json, served the
' way tests/gen-mediabrowser.mjs serves them to upstream's own
' fetchJellyfinLibraryFromServer, and holds it to that function's requests
' and items (tests/vectors/mediabrowser.json). Plus hand-written cases for
' the date parser and the Emby libraries path. Returns the failure count.
'
' A music-video library is asked for Movie and MusicVideo items (I-067), by
' the web tuner's scan and the port alike, so the vectors hold the MusicVideo
' clips and the loop below holds the port to them like any other item. If the
' web scan ever stops asking for them, "vectors hold the MusicVideo clips"
' fails rather than the port being quietly let off.
'
' The web's audioStreams are held to the port's audioTracks, not to a field of
' the same name: the port keeps those tracks under its own name and shape
' (NxMbAudioTracks). The vectors keep audioStreams for the Android scan test,
' which reads them from the same generator.

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
        mvIds = NxMbMusicVideoIds(fx)
        vectorClips = 0
        for each w in NxList(v.items)
            if mvIds.DoesExist(NxToStr(w.ratingKey)) then vectorClips = vectorClips + 1
        end for
        NxCheck(r, "vectors hold the MusicVideo clips", NxToStr(vectorClips > 0), "true")
        gotRequests = fetcher.requests
        gotItems = got
        NxCheck(r, "requests", gotRequests.Join(" | "), NxList(v.requests).Join(" | "))
        NxCheck(r, "item count", gotItems.Count().ToStr(), NxList(v.items).Count().ToStr())
        ' Port-only fields: none reaches the filter or schedule.
        extras = { serverIndex: true, seasonNumber: true, episodeNumber: true, videoProfile: true, audioChannels: true, bitrate: true, videoWidth: true, videoHeight: true, audioTracks: true, forcedSubs: true, fullSubs: true }
        n = NxMinInt(gotItems.Count(), NxList(v.items).Count())
        several = 0
        for i = 0 to n - 1
            want = v.items[i]
            it = gotItems[i]
            label = "item " + i.ToStr() + " " + NxToStr(want.ratingKey)
            for each k in want
                ' audioStreams is compared as audioTracks, below.
                if LCase(k) <> "audiostreams" then NxCheck(r, label + " " + k, FormatJson(NxMbJsonValue(it[k])), FormatJson(NxMbJsonValue(want[k])))
            end for
            ' The web lists every audio track of the best source (index, lang,
            ' codec, channels, title). The port keeps them as audioTracks only
            ' for a file with two or more (one is no choice) and has no title:
            ' so the same tracks in the same order, or none.
            webTracks = NxList(want.audioStreams)
            if webTracks.Count() >= 2 then
                several = several + 1
                NxCheck(r, label + " audioStreams as audioTracks", NxMbAudioText(it.audioTracks, "language"), NxMbAudioText(webTracks, "lang"))
            else
                NxCheck(r, label + " audioStreams under two: no audioTracks", NxToStr(it.audioTracks = invalid), "true")
            end if
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
        ' Without this, vectors that lost their audioStreams (a generator that
        ' strips them) would pass the comparison above on nothing.
        NxCheck(r, "vectors hold items with two or more audioStreams", NxToStr(several > 0), "true")
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
    NxCheck(r, "kbps: a Double", NxMbBitrateKbps(19269041.9#).ToStr(), "19269")
    NxCheck(r, "kbps: a whole Double", NxMbBitrateKbps(19269499#).ToStr(), "19269")
    boxed = CreateObject("roInt")
    boxed.SetInt(19269499)
    NxCheck(r, "kbps: an roInt", NxMbBitrateKbps(boxed).ToStr(), "19269")
    ' Either side of NxMbVideoQuery's line: over 20,000 kbps is re-encoded.
    NxCheck(r, "kbps: 20000499 is 20000", NxMbBitrateKbps(20000499).ToStr(), "20000")
    NxCheck(r, "kbps: 20000500 is 20001", NxMbBitrateKbps(20000500).ToStr(), "20001")
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
    ' Issue #236, as PR #245 settled it: a track titled a commentary is
    ' dropped from the pool while the file has any other audio track, before
    ' any language or default step. A file of commentaries alone picks among them.
    NxCheck(r, "commentary title: plain", NxToStr(NxIsCommentaryTitle("Commentary")), "true")
    NxCheck(r, "commentary title: any case, anywhere", NxToStr(NxIsCommentaryTitle("Director's COMMENTARY - English - AAC - Stereo")), "true")
    NxCheck(r, "commentary title: a main track", NxToStr(NxIsCommentaryTitle("Surround - English - Dolby Digital - 5.1 - Default")), "false")
    NxCheck(r, "commentary title: none", NxToStr(NxIsCommentaryTitle(invalid)), "false")
    main = NxMbTrack(1, "eng", 2, "aac", false)
    com = NxMbTrack(2, "eng", 6, "ac3", true)
    com.commentary = true
    NxCheck(r, "commentary: an english main track beats an english commentary default with more channels", NxToStr(NxMbChosenAudioIndex([main, com], ["en"])), "1")
    NxCheck(r, "commentary: the same in upstream's order", NxToStr(NxMbPreferredAudioIndex([main, com], ["en"])), "1")
    NxCheck(r, "commentary: the same with the commentary first in the file", NxToStr(NxMbChosenAudioIndex([com, main], ["en"])), "1")
    NxCheck(r, "commentary: the pick carries the main track's codec", NxToStr(NxMbAudioPick({ audioTracks: [com, main] }, ["en"]).airing.audioCodec), "aac")
    ' The only English track is a commentary, beside a Portuguese film track:
    ' the film's track, not the commentary.
    por = NxMbTrack(1, "por", 6, "eac3", true)
    NxCheck(r, "commentary: an english commentary loses to a portuguese film track", NxToStr(NxMbChosenAudioIndex([por, com], ["en"])), "1")
    NxCheck(r, "commentary: the same in upstream's order", NxToStr(NxMbPreferredAudioIndex([por, com], ["en"])), "1")
    com2 = NxMbTrack(3, "eng", 2, "aac", false)
    com2.commentary = true
    NxCheck(r, "commentary: two english commentaries lose to the portuguese film track", NxToStr(NxMbChosenAudioIndex([por, com2, com], ["en"])), "1")
    ' A German viewer with a German commentary and an English film track: the film track.
    deCom = NxMbTrack(4, "ger", 2, "aac", false)
    deCom.commentary = true
    NxCheck(r, "commentary: a german commentary loses to the english film track", NxToStr(NxMbChosenAudioIndex([main, deCom], ["de"])), "1")
    NxCheck(r, "commentary: the same with the commentary first and the default", NxToStr(NxMbChosenAudioIndex([NxMbCommentary(4, "ger", 6, true), main], ["de"])), "1")
    ' One film track beside commentaries is the pick, not left to the server.
    NxCheck(r, "commentary: one film track beside commentaries is picked", NxToStr(NxMbChosenAudioIndex([com, main, com2], ["ja"])), "1")
    ' The Hills Have Eyes (1977), as the lab Jellyfin lists it: English mono, the default, and three English stereo commentaries.
    hills = [NxMbTrack(2, "eng", 1, "aac", true), NxMbCommentary(3, "eng", 2, false), NxMbCommentary(4, "eng", 2, false), NxMbCommentary(5, "eng", 2, false)]
    NxCheck(r, "commentary: english mono beside three english stereo commentaries", NxToStr(NxMbChosenAudioIndex(hills, ["en"])), "2")
    ' Every track a commentary: picked among as any tracks are.
    NxCheck(r, "commentary only: the viewer's language, most channels", NxToStr(NxMbChosenAudioIndex([NxMbCommentary(1, "eng", 2, true), NxMbCommentary(2, "ger", 2, false), NxMbCommentary(3, "ger", 6, false)], ["de"])), "3")
    NxCheck(r, "commentary only: english when the viewer's isn't there", NxToStr(NxMbChosenAudioIndex([NxMbCommentary(1, "jpn", 2, true), NxMbCommentary(2, "eng", 2, false)], ["de"])), "2")
    NxCheck(r, "commentary only: one track is left to the server", NxToStr(NxMbChosenAudioIndex([NxMbCommentary(1, "eng", 2, true)], ["en"]) = invalid), "true")
    NxCheck(r, "skip: the pool is the tracks that aren't a commentary", NxMbTracksText(NxMbSkipCommentary([com, main, com2, por])), NxMbTracksText([main, por]))
    NxCheck(r, "skip: commentaries alone are all kept", NxMbSkipCommentary([com, com2]).Count().ToStr(), "2")
    NxCheck(r, "skip: no commentary keeps every track", NxMbSkipCommentary([main, por]).Count().ToStr(), "2")
    ' No track in a wanted language: the default, unless it is a commentary and another track isn't.
    jpn = NxMbTrack(1, "jpn", 2, "aac", false)
    jpnCom = NxMbTrack(2, "jpn", 2, "aac", true)
    jpnCom.commentary = true
    NxCheck(r, "commentary: a commentary default is passed over for the film's track", NxToStr(NxMbChosenAudioIndex([jpn, jpnCom], ["es"])), "1")
    korCom = NxMbTrack(5, "kor", 2, "aac", false)
    korCom.commentary = true
    NxCheck(r, "commentary: commentaries alone, the default", NxToStr(NxMbPreferredAudioIndex([korCom, jpnCom], ["es"])), "2")
    kor = NxMbTrack(3, "kor", 2, "aac", true)
    NxCheck(r, "commentary: the default among the tracks that aren't one", NxToStr(NxMbChosenAudioIndex([jpnCom, jpn, kor], ["es"])), "3")
    ' The scan marks them from the server's Title or DisplayTitle.
    marked = NxMbAudioTracks({ MediaStreams: [
        { Type: "Audio", Index: 1, Language: "eng", DisplayTitle: "English - AAC - Stereo - Default", IsDefault: true },
        { Type: "Audio", Index: 2, Language: "eng", DisplayTitle: "Commentary 1 - English - HE-AAC - Stereo" },
        { Type: "Audio", Index: 3, Language: "eng", Title: "Director's commentary", DisplayTitle: "English - AAC - Stereo" }
    ] })
    NxCheck(r, "commentary: the scan marks a DisplayTitle and a Title", NxToStr(marked[0].commentary = true) + " " + NxToStr(marked[1].commentary = true) + " " + NxToStr(marked[2].commentary = true), "false true true")
    ' Direct play, a short list: the pick's language, a commentary only when alone in it.
    named = [{ Track: "1", Language: "eng", Name: "Commentary with the director" }, { Track: "2", Language: "eng", Name: "English" }]
    NxCheck(r, "commentary: a short list passes a commentary by", NxToStr(NxAudioTrackToSelect(named, { position: 2, language: "eng", count: 3 })), "2")
    NxCheck(r, "commentary: a short list never takes a commentary beside another track", NxToStr(NxAudioTrackToSelect([named[0], { Track: "3", Language: "por" }], { position: 2, language: "eng", count: 3 }) = invalid), "true")
    NxCheck(r, "commentary: a short list of commentaries alone goes by language", NxToStr(NxAudioTrackToSelect([{ Track: "7", Language: "por", Name: "Commentary (pt)" }, named[0]], { position: 2, language: "eng", count: 3 })), "1")
    NxCheck(r, "commentary: a full list still goes by position", NxToStr(NxAudioTrackToSelect(named, { position: 1, language: "eng", count: 2 })), "2")
    print "audio pick cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

function NxMbTrack(index as Integer, language as Dynamic, channels as Dynamic, codec as Dynamic, isDefault as Boolean) as Object
    return { index: index, language: language, channels: channels, codec: codec, isDefault: isDefault }
end function

' An AAC track the scan marked a commentary (#236).
function NxMbCommentary(index as Integer, language as Dynamic, channels as Dynamic, isDefault as Boolean) as Object
    t = NxMbTrack(index, language, channels, "aac", isDefault)
    t.commentary = true
    return t
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

' "index:language:channels:codec" per track, space-separated; "" for none. For
' the web's audioStreams (langKey "lang") and the port's audioTracks
' ("language") alike, with the web's fill-ins applied to both: no language or
' codec is "", no channel count is 0 (its `s.Channels || 0`). The web's title
' and the port's isDefault have no counterpart, so neither is read.
function NxMbAudioText(tracks as Dynamic, langKey as String) as String
    out = []
    for each t in NxList(tracks)
        channels = "0"
        if NxIsNumber(t.channels) then channels = NxToStr(t.channels)
        out.Push(NxToStr(t.index) + ":" + NxToStr(t[langKey]) + ":" + channels + ":" + NxToStr(t.codec))
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
                ' A view in `hidden` is one the user hides from the home screen:
                ' Jellyfin's /UserViews lists it only with includeHidden=true
                ' (#231). Emby's list has it either way.
                hidden = NxList(m.fx.hidden)
                if hidden.Count() = 0 or base <> "/UserViews" or q.includeHidden = "true" then
                    return { Items: m.fx.views, TotalRecordCount: m.fx.views.Count() }
                end if
                shown = []
                for each v in m.fx.views
                    if not NxHasValue(hidden, v.Id) then shown.Push(v)
                end for
                return { Items: shown, TotalRecordCount: shown.Count() }
            end if
            if base <> "/Items" then return invalid
            if NxHasValue(NxList(m.fx.fail), q.ParentId) then return invalid
            all = []
            ' IncludeItemTypes is a comma list, as the servers read it.
            asked = "," + NxToStr(q.IncludeItemTypes) + ","
            ' A parent in `answersAll` answers with everything it holds,
            ' whatever was asked, as Jellyfin's Playlists library does (#205).
            answersAll = NxHasValue(NxList(m.fx.answersAll), q.ParentId)
            for each it in NxList(m.fx.items[q.ParentId])
                if answersAll or Instr(1, asked, "," + NxToStr(it.Type) + ",") > 0 then all.Push(it)
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

' ── I-067: a Music Videos library is asked for its MusicVideo items ──

' Jellyfin and Emby file the videos in a Music Videos library as MusicVideo.
' The scan asked every flat library for Movie alone, so such a library loaded
' nothing and HIGH ROTATION stayed empty. These cases hold the port to the fix
' by themselves, whether or not the web tuner's scan (the vectors) has it yet:
' what each library is asked for, that the clips arrive stamped as music
' videos and reach HIGH ROTATION through the real filter, that nothing else is
' widened, and the bug as reported (a library of MusicVideo items only).
' Returns the failure count.
function NxRunMusicVideoTypeTests(fixturePath as String, channelsPath as String, manifestPath as String) as Integer
    r = { pass: 0, fail: 0 }
    fx = ParseJson(ReadAsciiFile(fixturePath))
    config = ParseJson(ReadAsciiFile(channelsPath))
    manifest = ParseJson(ReadAsciiFile(manifestPath))
    if fx = invalid or config = invalid or manifest = invalid then
        print "FAIL cannot read "; fixturePath; ", "; channelsPath; " or "; manifestPath
        return 1
    end if

    ' HIGH ROTATION: the channel that takes every music video and nothing else.
    highRotation = invalid
    for each def in config.channels
        if highRotation = invalid and type(def.rules) = "roAssociativeArray" then
            if def.rules.source = "musicVideo" and def.rules.genres = invalid and def.rules.yearRange = invalid then highRotation = def
        end if
    end for
    NxCheck(r, "channels.json has the HIGH ROTATION channel", NxToStr(highRotation <> invalid), "true")
    compiled = invalid
    minItems = 3
    if highRotation <> invalid then
        compiled = NxFilterChannel(highRotation)
        if NxTruthy(highRotation.minItems) then minItems = highRotation.minItems
    end if
    exclusive = NxFilterExclusiveRules(config.exclusiveRules)
    clock = NxFilterClock()

    ' The music video library as a server sends it from 12.4.0: its videos
    ' are all MusicVideo, so a request for Movie finds none.
    musicView = invalid
    for each view in fx.views
        if LCase(NxToStr(view.CollectionType)) = "musicvideos" then musicView = view
    end for
    NxCheck(r, "the fixture has a musicvideos library", NxToStr(musicView <> invalid), "true")
    if musicView = invalid then return r.fail
    clipsOnly = []
    for each it in fx.items[musicView.Id]
        if it.Type = "MusicVideo" then clipsOnly.Push(it)
    end for
    onlyItems = {}
    onlyItems[musicView.Id] = clipsOnly
    onlyServer = { userId: fx.userId, views: [musicView], items: onlyItems, fail: [] }

    ' The same library again, past one page (200 items), to show the second
    ' request asks for the same types as the first.
    bulk = []
    for i = 1 to 201
        bulk.Push({ Id: "bulk-" + i.ToStr(), Name: "Artist - Song " + i.ToStr(), Type: "MusicVideo", RunTimeTicks: clipsOnly[0].RunTimeTicks, Genres: ["Pop"] })
    end for
    bulkItems = {}
    bulkItems[musicView.Id] = bulk
    bulkServer = { userId: fx.userId, views: [musicView], items: bulkItems, fail: [] }

    for each kind in ["jellyfin", "emby"]
        ' The shared fixture: a Movies library with a MusicVideo filed in it, a
        ' show library, the Music Videos library (clips filed as Movie and as
        ' MusicVideo) and a mixed library.
        fetcher = NxMbFixtureFetcher(fx)
        got = NxMbScanServer(fetcher, kind, fx.userId, 1)
        NxCheck(r, kind + ": the scan returns items", NxToStr(got <> invalid), "true")
        if got <> invalid then
            asked = NxMbAskedTypes(fetcher.requests)
            NxCheck(r, kind + ": the Music Videos library is asked for Movie,MusicVideo", NxToStr(asked[musicView.Id]), "Movie,MusicVideo")
            NxCheck(r, kind + ": the Movies library is still asked for Movie", NxToStr(asked["v-movies"]), "Movie")
            NxCheck(r, kind + ": the mixed library is still asked for Movie, on both pages", NxToStr(asked["v-home"]), "Movie")
            NxCheck(r, kind + ": the show library is still asked for Series", NxToStr(asked["v-shows"]), "Series")
            NxCheck(r, kind + ": a show is still asked for Episode", NxToStr(asked["s-sparse"]), "Episode")

            byKey = {}
            for each it in got
                byKey[NxToStr(it.ratingKey)] = it
            end for
            ' Filed as Movie (mv-1, mv-2) or as MusicVideo (mv-3 to mv-6), each
            ' arrives stamped as a music video, which is what HIGH ROTATION reads.
            for each id in ["mv-1", "mv-2", "mv-3", "mv-4", "mv-5", "mv-6"]
                it = byKey[id]
                NxCheck(r, kind + ": " + id + " loads", NxToStr(it <> invalid), "true")
                if it <> invalid then
                    NxCheck(r, kind + ": " + id + " is stamped musicVideo", NxToStr(it.librarySource), "musicVideo")
                    NxCheck(r, kind + ": " + id + " is a movie-type item", NxToStr(it.type), "movie")
                    NxCheck(r, kind + ": " + id + " is on serverIndex 1", NxToStr(it.serverIndex), "1")
                    if compiled <> invalid then NxCheck(r, kind + ": " + id + " passes HIGH ROTATION", NxToStr(NxItemPasses(it, compiled, manifest, exclusive, clock, kind) <> ""), "true")
                end if
            end for
            clip = byKey["mv-3"]
            if clip <> invalid then
                NxCheck(r, kind + ": a MusicVideo's artist", NxToStr(clip.artist), "Band Name")
                NxCheck(r, kind + ": a MusicVideo's title", NxToStr(clip.title), "Hit Single")
            end if
            bare = byKey["mv-4"]
            if bare <> invalid then NxCheck(r, kind + ": a MusicVideo with no genres is given Music Video", NxToStr(NxHasValue(bare.genres, "Music Video")), "true")
            ' A MusicVideo in a Movies library is not asked for, so it does not
            ' become a film (or anything else) on a film channel.
            NxCheck(r, kind + ": a MusicVideo filed in the Movies library stays out", NxToStr(byKey["m-musicvideo"] = invalid), "true")
            ' Nothing else becomes a music video but the short film with a Music
            ' genre (m-musicgenre), which the scan has always stamped by its
            ' genre and length.
            stray = 0
            for each it in got
                if it.librarySource = "musicVideo" and not NxHasValue(["mv-1", "mv-2", "mv-3", "mv-4", "mv-5", "mv-6", "m-musicgenre"], NxToStr(it.ratingKey)) then stray = stray + 1
            end for
            NxCheck(r, kind + ": no other item is stamped musicVideo", stray.ToStr(), "0")
            if compiled <> invalid then
                pool = NxFilterPool(got, compiled, manifest, exclusive, clock, kind)
                NxCheck(r, kind + ": HIGH ROTATION holds the six clips and the short Music-genre film", pool.Count().ToStr(), "7")
            end if
        end if

        ' The bug as reported: Movie finds none, MusicVideo finds four.
        fetcher = NxMbFixtureFetcher(onlyServer)
        got = NxMbScanServer(fetcher, kind, fx.userId, 0)
        NxCheck(r, kind + ": a library of MusicVideo items only: the scan returns items", NxToStr(got <> invalid), "true")
        if got <> invalid then
            NxCheck(r, kind + ": a library of MusicVideo items only loads all of them", got.Count().ToStr(), clipsOnly.Count().ToStr())
            if compiled <> invalid then
                pool = NxFilterPool(got, compiled, manifest, exclusive, clock, kind)
                NxCheck(r, kind + ": HIGH ROTATION fills from it", pool.Count().ToStr(), clipsOnly.Count().ToStr())
                NxCheck(r, kind + ": and reaches minItems", NxToStr(pool.Count() >= minItems), "true")
            end if
        end if

        ' Past one page, the second request asks for the same types.
        fetcher = NxMbFixtureFetcher(bulkServer)
        got = NxMbScanServer(fetcher, kind, fx.userId, 0)
        NxCheck(r, kind + ": 201 MusicVideo items: the scan returns items", NxToStr(got <> invalid), "true")
        if got <> invalid then
            NxCheck(r, kind + ": 201 MusicVideo items all load", got.Count().ToStr(), "201")
            pages = 0
            for each path in fetcher.requests
                if Left(path, 7) = "/Items?" then pages = pages + 1
            end for
            NxCheck(r, kind + ": 201 MusicVideo items took two pages", pages.ToStr(), "2")
            NxCheck(r, kind + ": both pages ask for Movie,MusicVideo", NxToStr(NxMbAskedTypes(fetcher.requests)[musicView.Id]), "Movie,MusicVideo")
        end if
    end for

    ' What each kind of library is asked for. Only a musicvideos library asks
    ' for both; a Movies or mixed (no type) library asks for films. Home
    ' Videos, Collections and Music hold no films and are not asked at all
    ' ("", as upstream's jellyfin-library-golden.json has them since #205).
    libraries = [
        ["musicvideos", "Movie,MusicVideo"],
        ["MusicVideos", "Movie,MusicVideo"],
        ["movies", "Movie"],
        ["homevideos", ""],
        ["boxsets", ""],
        ["music", ""],
        ["", "Movie"],
        [invalid, "Movie"]
    ]
    for each lib in libraries
        NxCheck(r, "item types for library type '" + NxToStr(lib[0]) + "'", NxToStr(NxMbItemTypesFor(lib[0])), lib[1])
    end for

    print "music video item type cases: "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' The ids of the fixture's MusicVideo items, wherever they are filed. The
' vectors hold them once the web tuner's scan asks a music video library for
' them; NxRunMediaBrowserTests then holds the port to the vectors on them too,
' and, until then, on everything else.
function NxMbMusicVideoIds(fx as Object) as Object
    ids = {}
    for each parentId in fx.items
        for each it in NxList(fx.items[parentId])
            if NxToStr(it.Type) = "MusicVideo" then ids[NxToStr(it.Id)] = true
        end for
    end for
    return ids
end function

' What a scan asked each parent for: { <ParentId>: "<IncludeItemTypes>" }, with
' "a|b" when one parent was asked two ways. Views and other paths are skipped.
function NxMbAskedTypes(requests as Object) as Object
    asked = {}
    for each path in requests
        cut = Instr(1, path, "?")
        if cut > 0 and Left(path, cut - 1) = "/Items" then
            q = {}
            for each pair in Mid(path, cut + 1).Split("&")
                eq = Instr(1, pair, "=")
                if eq > 0 then q[Left(pair, eq - 1)] = Mid(pair, eq + 1)
            end for
            parent = NxToStr(q.ParentId)
            types = NxToStr(q.IncludeItemTypes)
            if not asked.DoesExist(parent) then
                asked[parent] = types
            else if Instr(1, "|" + asked[parent] + "|", "|" + types + "|") = 0 then
                asked[parent] = asked[parent] + "|" + types
            end if
        end if
    end for
    return asked
end function

' ── #205: a library with no videos in it is never read as films ──

' Jellyfin's Playlists library answers any request with its playlists,
' whatever IncludeItemTypes says, and the scan called every library that was
' not TV or Music Videos a film library, so an audio playlist aired on VHS
' VAULT as a 33 minute film. Upstream's scripts/jellyfin-library-golden.json
' (copied byte for byte into the vectors) pins which libraries are read and
' which rows are kept; the saved answers below are the regression case from
' the issue. Returns the failure count.
function NxRunPlaylistLeakTests(goldenPath as String, fixturePath as String, channelsPath as String, manifestPath as String) as Integer
    r = { pass: 0, fail: 0 }
    golden = ParseJson(ReadAsciiFile(goldenPath))
    fx = ParseJson(ReadAsciiFile(fixturePath))
    config = ParseJson(ReadAsciiFile(channelsPath))
    manifest = ParseJson(ReadAsciiFile(manifestPath))
    if golden = invalid or fx = invalid or config = invalid or manifest = invalid then
        print "FAIL cannot read "; goldenPath; ", "; fixturePath; ", "; channelsPath; " or "; manifestPath
        return 1
    end if

    ' The golden file's `sections`: a CollectionType gives a section type and
    ' what it is asked for (null: not asked).
    for each c in golden.sections
        label = "section for CollectionType '" + NxToStr(c.collectionType) + "'"
        section = NxMbSectionType(c.collectionType)
        NxCheck(r, label, section, NxToStr(c.sectionType))
        NxCheck(r, label + " asks for", NxToStr(NxMbItemTypes(section)), NxToStr(c.itemTypes))
    end for
    ' Its `views`: the request that lists a user's libraries, by backend, user
    ' id and the INCLUDE LIBRARIES HIDDEN ON JELLYFIN switch (#231).
    for each c in golden.views
        label = "views path, " + c.backend + ", user '" + c.userId + "', includeHidden " + NxToStr(c.includeHidden)
        NxCheck(r, label, NxMbViewsPath(c.backend, c.userId, c.includeHidden = true), c.path)
    end for
    NxCheck(r, "the golden file has its views cases", NxToStr(NxList(golden.views).Count() >= 9), "true")
    ' Its `types`: a row the server sent, what was asked, and whether it is kept.
    for each c in golden.types
        NxCheck(r, "row of Type '" + NxToStr(c.item.Type) + "' asked " + c.asked, NxToStr(NxMbHasAskedType(c.item, c.asked)), NxToStr(c.kept))
    end for

    ' The saved answers: the shared fixture's four libraries, plus a Playlists
    ' library holding an audio playlist of 8 tracks, 33 minutes, no year
    ' (answered with its playlists whatever is asked), a Music library with
    ' Audio and MusicAlbum rows and a Collections library with a BoxSet, both
    ' answering with everything too, for a server that ignores the request.
    ticks33& = 33& * 60& * 10000000&
    playlist = { Id: "pl-workout", Name: "Workout Mix", Type: "Playlist", MediaType: "Audio", ChildCount: 8, RunTimeTicks: ticks33& }
    extraViews = [
        { Id: "v-playlists", Name: "Playlists", CollectionType: "playlists" },
        { Id: "v-music", Name: "Music", CollectionType: "music" },
        { Id: "v-boxsets", Name: "Collections", CollectionType: "boxsets" }
    ]
    extraItems = {
        "v-playlists": [playlist],
        "v-music": [
            { Id: "au-1", Name: "Song One", Type: "Audio", MediaType: "Audio", RunTimeTicks: 2400000000& },
            { Id: "al-1", Name: "An Album", Type: "MusicAlbum", RunTimeTicks: 24000000000& }
        ],
        "v-boxsets": [{ Id: "bx-1", Name: "A Film Collection", Type: "BoxSet", RunTimeTicks: 72000000000& }]
    }
    leakIds = ["pl-workout", "au-1", "al-1", "bx-1"]
    views = []
    views.Append(fx.views)
    views.Append(extraViews)
    items = {}
    items.Append(fx.items)
    items.Append(extraItems)
    server = { userId: fx.userId, views: views, items: items, fail: [], answersAll: ["v-playlists", "v-music", "v-boxsets"] }

    ' The same playlist and a song filed in the Movies library, answered
    ' whatever is asked: the rows are dropped by their Type.
    strictItems = {}
    strictItems.Append(fx.items)
    strictMovies = []
    strictMovies.Append(fx.items["v-movies"])
    strictMovies.Push(playlist)
    strictMovies.Push(extraItems["v-music"][0])
    strictItems["v-movies"] = strictMovies
    strictServer = { userId: fx.userId, views: fx.views, items: strictItems, fail: [], answersAll: ["v-movies"] }

    vhsVault = invalid
    highRotation = invalid
    for each def in config.channels
        if def.name = "VHS VAULT" then vhsVault = def
        if highRotation = invalid and type(def.rules) = "roAssociativeArray" then
            if def.rules.source = "musicVideo" and def.rules.genres = invalid and def.rules.yearRange = invalid then highRotation = def
        end if
    end for
    NxCheck(r, "channels.json has VHS VAULT", NxToStr(vhsVault <> invalid), "true")
    NxCheck(r, "channels.json has HIGH ROTATION", NxToStr(highRotation <> invalid), "true")
    if vhsVault = invalid or highRotation = invalid then return r.fail
    exclusive = NxFilterExclusiveRules(config.exclusiveRules)
    clock = NxFilterClock()

    ' The case is real: read as a film, the playlist passes VHS VAULT's rules.
    asFilm = NxMbMovieItem(playlist, false, CreateObject("roRegex", "music", "i"))
    NxCheck(r, "read as a film, the playlist is an item", NxToStr(asFilm <> invalid), "true")
    if asFilm <> invalid then NxCheck(r, "read as a film, the playlist passes VHS VAULT", NxToStr(NxItemPasses(asFilm, NxFilterChannel(vhsVault), manifest, exclusive, clock, "jellyfin") <> ""), "true")

    for each kind in ["jellyfin", "emby"]
        plain = NxMbScanServer(NxMbFixtureFetcher(fx), kind, fx.userId, 0)
        fetcher = NxMbFixtureFetcher(server)
        got = NxMbScanServer(fetcher, kind, fx.userId, 0)
        NxCheck(r, kind + ": the scan returns items", NxToStr(got <> invalid and plain <> invalid), "true")
        if got <> invalid and plain <> invalid then
            ' Everything the four video libraries gave before loads exactly as
            ' before (compared before the filter, which caches on the items).
            NxCheck(r, kind + ": the four video libraries load as without the extra libraries", NxMbItemsText(got), NxMbItemsText(plain))
            asked = NxMbAskedTypes(fetcher.requests)
            for each v in extraViews
                NxCheck(r, kind + ": the " + v.Name + " library is never asked for items", NxToStr(asked.DoesExist(v.Id)), "false")
            end for
            byKey = {}
            for each it in got
                byKey[NxToStr(it.ratingKey)] = it
            end for
            for each id in leakIds
                NxCheck(r, kind + ": " + id + " is not loaded", NxToStr(byKey.DoesExist(id)), "false")
            end for
            ' Only the leak ids can count, and NxFilterPool decides each item on
            ' its own (NxItemPasses), so filtering just those items gives the
            ' same count as filtering every item and keeping theirs: every
            ' channel in channels.json, in seconds where the whole scan took
            ' about ten minutes in the off-TV interpreter.
            leaked = []
            for each it in got
                if NxHasValue(leakIds, NxToStr(it.ratingKey)) then leaked.Push(it)
            end for
            onChannel = 0
            for each def in config.channels
                for each entry in NxFilterPool(leaked, NxFilterChannel(def), manifest, exclusive, clock, kind)
                    if NxHasValue(leakIds, NxToStr(entry.item.ratingKey)) then onChannel = onChannel + 1
                end for
            end for
            NxCheck(r, kind + ": no channel holds the playlist, a song, an album or a collection", onChannel.ToStr(), "0")
            ' A MusicVideo in the Music Videos library still reaches HIGH ROTATION (I-067).
            clip = byKey["mv-3"]
            NxCheck(r, kind + ": the MusicVideo mv-3 loads", NxToStr(clip <> invalid), "true")
            if clip <> invalid then NxCheck(r, kind + ": mv-3 passes HIGH ROTATION", NxToStr(NxItemPasses(clip, NxFilterChannel(highRotation), manifest, exclusive, clock, kind) <> ""), "true")
        end if

        got = NxMbScanServer(NxMbFixtureFetcher(strictServer), kind, fx.userId, 0)
        NxCheck(r, kind + ": a Movies library answering with everything: the scan returns items", NxToStr(got <> invalid and plain <> invalid), "true")
        if got <> invalid and plain <> invalid then
            stray = 0
            for each it in got
                if NxHasValue(leakIds, NxToStr(it.ratingKey)) then stray = stray + 1
            end for
            NxCheck(r, kind + ": a playlist or song row answered for Movie is dropped", stray.ToStr(), "0")
            NxCheck(r, kind + ": and the films load as before", NxMbItemsText(got), NxMbItemsText(plain))
        end if
    end for

    print "playlist leak cases (upstream jellyfin-library-golden.json):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' A scan's items as text, to compare two scans: each item's fields in key
' order, lists and nested fields spelled out. FormatJson refuses items that
' share a list (the genres), so it can't be used. The filter's own cache
' (nxFilter) is left out.
function NxMbItemsText(items as Object) as String
    lines = []
    for each it in items
        lines.Push(NxMbValueText(it, 0))
    end for
    return lines.Join(Chr(10))
end function

function NxMbValueText(v as Dynamic, depth as Integer) as String
    if depth > 4 then return "…"
    if type(v) = "roAssociativeArray" then
        keys = []
        for each k in v
            if LCase(k) <> "nxfilter" then keys.Push(k)
        end for
        keys.Sort()
        parts = []
        for each k in keys
            parts.Push(k + "=" + NxMbValueText(v[k], depth + 1))
        end for
        return "{" + parts.Join(",") + "}"
    end if
    if type(v) = "roArray" or type(v) = "roList" then
        parts = []
        for each x in v
            parts.Push(NxMbValueText(x, depth + 1))
        end for
        return "[" + parts.Join(",") + "]"
    end if
    if v = invalid then return "invalid"
    return NxToStr(v)
end function
