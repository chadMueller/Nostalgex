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
        extras = { serverIndex: true, seasonNumber: true, episodeNumber: true, videoProfile: true, audioChannels: true, bitrate: true, videoWidth: true, videoHeight: true, audioTracks: true }
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
        bitrates = [["27ef0d2ba6cf3fe966bfc892bb26ac05", "19269041"], ["m-two", "9000000"], ["m-nobr", ""]]
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
    NxCheck(r, "video, no bitrate copies", NxMbVideoQuery(invalid), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, 19 Mb/s copies", NxMbVideoQuery(19269041), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, 20 Mb/s copies", NxMbVideoQuery(20000000), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, 29 Mb/s re-encodes", NxMbVideoQuery(29000000), "&VideoBitrate=40000000&MaxWidth=3840&AllowVideoStreamCopy=false")
    NxCheck(r, "video, re-encode on a 1080p TV is 1080p", NxMbVideoQuery(29000000, "server", 1920), "&VideoBitrate=40000000&MaxWidth=1920&AllowVideoStreamCopy=false")
    NxCheck(r, "video, a copy on a 1080p TV stays 3840", NxMbVideoQuery(19269041, "server", 1920), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, no bitrate on a 1080p TV copies", NxMbVideoQuery(invalid, "server", 1920), "&VideoBitrate=40000000&MaxWidth=3840")
    NxCheck(r, "video, 1080p rung whatever the TV", NxMbVideoQuery(29000000, "capped", 1280), "&VideoBitrate=8000000&MaxWidth=1920")
    NxCheck(r, "width, 2160p60", NxMaxWidthFor("2160p60").ToStr(), "3840")
    NxCheck(r, "width, 2160p60b10", NxMaxWidthFor("2160p60b10").ToStr(), "3840")
    NxCheck(r, "width, 1080p", NxMaxWidthFor("1080p").ToStr(), "1920")
    NxCheck(r, "width, 1080i", NxMaxWidthFor("1080i").ToStr(), "1920")
    NxCheck(r, "width, 720p", NxMaxWidthFor("720p").ToStr(), "1280")
    NxCheck(r, "width, unreadable keeps 3840", NxMaxWidthFor("").ToStr(), "3840")
    NxCheck(r, "audio, eac3 only, 5.1", NxMbAudioQuery(false, true, true), "&AudioCodec=aac,eac3&TranscodingMaxAudioChannels=6")

    print "mediabrowser cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail + NxRunDirectPlayTests() + NxRunAudioPickTests()
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
