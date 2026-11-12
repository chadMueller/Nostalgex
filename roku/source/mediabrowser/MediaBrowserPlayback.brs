' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Turns a guide airing from a Jellyfin or Emby server into something Roku's
' Video node can play, joined at `offsetSec` as NxPlexStreamContent does for
' Plex, and the stream calls that pick between the two by the airing's server.
'
' Direct play when this TV decodes the file as stored, as
' source/util/DirectPlay.brs asks it (/Videos/{id}/stream.<ext>?Static=true);
' otherwise the server's HLS (/Videos/{id}/master.m3u8), copying the video when the TV decodes it and
' converting only what it doesn't. The HLS address is built here, as the
' Apple TV app's fallback is, rather than asked of PlaybackInfo:
'   - that needs a POST, and network requests can't run on the render thread;
'   - PlaybackInfo had Jellyfin 12.2 burn a file's subtitles into the picture
'     (SubtitleMethod=Encode), a full re-encode, even when asked for none.
' Both server kinds showed a picture for every case this way on a Roku TV,
' joining 20 minutes in (docs/JELLYFIN-EMBY.md, the playback spike); sound
' needed TS segments (below).
'
' Joining part-way: the player starts at PlayStart. Never StartTimeTicks on an
' HLS address: Jellyfin then rejects every segment (HTTP 400), and the
' playlist covers the whole file from 0 anyway.
'
' Security: the token goes in the Authorization header, never in the URL,
' as for Plex. Emby wants it on the playlist, Jellyfin on every segment too,
' and the Video node sends its headers with each request. Nothing here
' reports playback back to the server: that is SHOW NOW PLAYING and MARK
' WATCHED, off unless the viewer turns them on (source/guide/PlaybackReport.brs).

' Returns { content, stopUrl, route, rung, audioTrack, forcedSub, forcedUrl }
' (stopUrl "" for direct play; audioTrack the pick for the player to select on
' a direct play, as NxAudioTrackToSelect takes it, else invalid; forcedSub
' true when the airing has a forced track in SUBTITLE LANGUAGE, and forcedUrl
' its SRT for the app to fetch and draw, #237), or invalid.
' A server stream may carry a full track as a sidecar too (NxMbFullSub).
' rung as for NxPlexStreamContent.
function NxMbStreamContent(b as Object, offsetSec as LongInteger, s as Object, rung = "auto" as String) as Dynamic
    base = NxToStr(s.uri)
    lower = LCase(base)
    onLan = Left(lower, 7) = "http://" and NxIsPrivateHost(NxUrlHost(base))
    if Left(lower, 8) <> "https://" and not onLan then return invalid
    route = "HTTPS"
    if onLan then route = "home network"
    if offsetSec < 0 then offsetSec = 0
    itemId = NxToStr(b.ratingKey)
    msid = NxToStr(NxOr(b.partKey, itemId))

    content = CreateObject("roSGNode", "ContentNode")
    content.title = b.line
    content.HttpCertificatesFile = "common:/certs/ca-bundle.crt"
    content.HttpHeaders = ["Authorization:" + NxMbAuthHeader(NxToStr(s.accessToken))]
    content.PlayStart = offsetSec
    ' A forced track in SUBTITLE LANGUAGE, as the server's SRT, set before
    ' play: the Apple TV burns it in (forcedSubtitleToBurn), which Emby
    ' refuses (docs/JELLYFIN-EMBY.md). The server needs no token for it.
    subLang = NxSubPreferredLanguage()
    subsAlways = NxSubtitleSettings().always
    forced = NxMbForcedSub(b, subLang)

    ' The audio track a viewer here wants, when the file has a choice: the
    ' server hands over the file's default, which can be a dub.
    pick = NxMbAudioPick(b, NxMbViewerLanguages())
    b = pick.airing
    pickIndex = pick.index
    audioTrack = invalid
    if pickIndex <> invalid then audioTrack = { position: pick.position, language: pick.language, count: pick.count }

    container = LCase(NxToStr(b.container))
    hevc = NxCanDecodeHevc()
    quality = NxSqCurrent()
    direct = NxMbDirectPlays(b, base, quality)
    if rung <> "auto" then direct = false

    if direct then
        ' .mp4 on the MP4 family: Jellyfin labels a static stream by the
        ' file's name otherwise (scripts/nostalgex-jellyfin-urls.js).
        ext = "mkv"
        format = "mkv"
        if container <> "mkv" then
            ext = "mp4"
            format = "mp4"
        end if
        content.url = base + "/Videos/" + NxUrlEncode(itemId) + "/stream." + ext + "?Static=true&MediaSourceId=" + NxUrlEncode(msid)
        content.streamFormat = format
        sidecars = NxMbSubtitleSidecars(b, base, subLang, subsAlways, true, true)
        if sidecars.Count() > 0 then content.SubtitleTracks = sidecars
        return { content: content, stopUrl: "", route: route, rung: "direct", audioTrack: audioTrack, forcedSub: forced <> invalid, forcedUrl: NxMbForcedSubUrl(b, base, subLang) }
    end if

    ' Emby needs a PlaySessionId on a hand-built address or every segment
    ' fails (EmbyAPIService.buildTranscodeURL); Jellyfin takes one as well.
    session = LCase(CreateObject("roDeviceInfo").GetRandomUUID().Replace("-", ""))
    videoCodecs = "h264"
    if hevc then videoCodecs = "h264,hevc"
    q = "MediaSourceId=" + NxUrlEncode(msid)
    q = q + "&DeviceId=" + NxUrlEncode(NxPlexClientId())
    q = q + "&PlaySessionId=" + session
    q = q + "&VideoCodec=" + videoCodecs
    info = CreateObject("roDeviceInfo")
    ac3 = NxDecodeAnswer(info.CanDecodeAudio({ Codec: "ac3" }))
    eac3 = NxDecodeAnswer(info.CanDecodeAudio({ Codec: "eac3" }))
    aac51 = NxDecodeAnswer(info.CanDecodeAudio({ Codec: "aac", ChCnt: 6 }))
    q = q + NxMbAudioQuery(ac3, eac3, aac51)
    if rung <> "capped" then rung = "server"
    q = q + NxMbVideoQuery(b.bitrate, rung, NxMaxWidthFor(info.GetVideoMode()), quality)
    if pickIndex <> invalid then q = q + "&AudioStreamIndex=" + pickIndex.ToStr()
    ' TS segments on both servers, HEVC included. A Roku played no sound
    ' from fMP4, even stereo AAC, on Emby and on Jellyfin (Discussion #8,
    ' 2026-10-22), and TS carries the source timestamps, so a join stays in
    ' sync where fMP4's ran up to a GOP early (docs/JELLYFIN-EMBY.md).
    q = q + "&SegmentContainer=ts"
    ' 2-second segments, not the servers' 6, so a piece of a 4K remux fits
    ' the player's buffer: one stopped with error -3, "Requested reservation
    ' (11065599+56589021) is larger than the entire buffer" (issue #58).
    ' Plex sends 1 s. With the video copied the server cuts only at
    ' keyframes, so a file whose keyframes are further apart still gets
    ' longer pieces; NxMbVideoQuery re-encodes the heavy ones
    ' (docs/JELLYFIN-EMBY.md).
    q = q + "&SegmentLength=2"
    content.url = base + "/Videos/" + NxUrlEncode(itemId) + "/master.m3u8?" + q
    content.streamFormat = "hls"
    sidecars = NxMbSubtitleSidecars(b, base, subLang, subsAlways, false, true)
    if sidecars.Count() > 0 then content.SubtitleTracks = sidecars
    stopUrl = base + "/Videos/ActiveEncodings?deviceId=" + NxUrlEncode(NxPlexClientId()) + "&playSessionId=" + session
    return { content: content, stopUrl: stopUrl, route: route, rung: rung, audioTrack: invalid, forcedSub: forced <> invalid, forcedUrl: NxMbForcedSubUrl(b, base, subLang) }
end function

' Whether this TV plays the airing as stored, `b` with its audio pick
' (NxMbAudioPick), from the server at `base` under STREAM QUALITY's level
' `quality`.
function NxMbDirectPlays(b as Object, base as String, quality = "auto" as String) as Boolean
    onLan = Left(LCase(base), 7) = "http://" and NxIsPrivateHost(NxUrlHost(base))
    container = LCase(NxToStr(b.container))
    vcodec = LCase(NxToStr(b.videoCodec))
    acodec = LCase(NxToStr(b.audioCodec))
    videoOk = vcodec = "h264" or (vcodec = "hevc" and NxCanDecodeHevc())
    audioOk = NxHasValue(["aac", "ac3", "eac3", "mp3"], acodec)
    ' MKV only on the home network: joined part-way it played at once over
    ' plain HTTP on the LAN, while through Plex over HTTPS it crawled.
    containers = ["mp4", "mov", "m4v"]
    if onLan then containers.Push("mkv")
    if not (NxHasValue(containers, container) and videoOk and audioOk) then return false
    ' And only what this TV decodes, profile and channels included.
    if not NxDeviceDecodes(b) then return false
    ' And under the level's ceiling (NxSqDirectPlayAllowed), which holds
    ' Jellyfin and Emby alike.
    return NxSqDirectPlayAllowed("jellyfin", quality, b.bitrate, NxSqIsLocalHost(NxUrlHost(base)))
end function

' Which audio track to ask for, when the file offers more than one: the
' Apple TV's JellyfinPlaybackResolver.preferredAudioIndex. Jellyfin and Emby
' hand back the track the file marks default, and plenty of files mark a dub
' (issue #78: O Brother, Where Art Thou? in Portuguese). A retro TV guide
' has no audio picker, so it picks the sensible track itself.
'
' A track in one of `languages`, most channels first (the first of equals);
' then the file's default; then the first track. A track's language is
' read as NxSubComparableTag reads it, where upstream compares its first
' two letters, so "est" is not Spanish (issue #119). invalid when there is
' nothing to choose between, which leaves the server's own choice.
' `tracks` as NxMbAudioTracks keeps them.
'
' A commentary (a track's `commentary`, #236) is never in the pool while the
' file has another audio track: NxMbSkipCommentary drops them before any
' language or default step, as the Apple TV's
' AudioTrackCommentary.skippingCommentary. So an English viewer's film with an
' English commentary and a Portuguese film track plays the Portuguese track.
' A file whose every track is a commentary picks among them as before.
function NxMbPreferredAudioIndex(tracks as Object, languages as Object) as Dynamic
    if tracks.Count() < 2 then return invalid
    pool = NxMbSkipCommentary(tracks)
    wanted = { en: true }
    for each l in languages
        if NxIsString(l) and l <> "" then wanted[LCase(l)] = true
    end for
    best = NxMbBestInLanguages(pool, wanted)
    if best <> invalid then return best.index
    for each t in pool
        if t.isDefault = true then return t.index
    end for
    return pool[0].index
end function

' `tracks` less those marked a commentary, when at least one other track is
' left; all of them when every track is a commentary (or none is).
function NxMbSkipCommentary(tracks as Object) as Object
    pool = []
    for each t in tracks
        if t.commentary <> true then pool.Push(t)
    end for
    if pool.Count() = 0 then return tracks
    return pool
end function

' The track in one of `wanted` (comparable tags) with the most channels, the
' first of equals, or invalid when no track is in a wanted language.
function NxMbBestInLanguages(tracks as Object, wanted as Object) as Dynamic
    best = invalid
    for each t in tracks
        tag = NxSubComparableTag(t.language)
        if tag <> invalid and wanted.DoesExist(tag) then
            if best = invalid then
                best = t
            else if NxNumberOr0(t.channels) > NxNumberOr0(best.channels) then
                best = t
            end if
        end if
    end for
    return best
end function

' AUDIO LANGUAGE first (issue #62): a track in one of `languages`, most
' channels first, before NxMbPreferredAudioIndex, whose English is always
' wanted too. Otherwise a German viewer would get an English 5.1 mix over
' the German stereo one. With nothing in `languages`, upstream's order. A
' track's code is read as the subtitle code reads it (NxSubComparableTag),
' since "ger" is "de".
function NxMbChosenAudioIndex(tracks as Object, languages as Object) as Dynamic
    if tracks.Count() < 2 then return invalid
    wanted = {}
    for each l in languages
        if NxIsString(l) and l <> "" then wanted[LCase(l)] = true
    end for
    best = NxMbBestInLanguages(NxMbSkipCommentary(tracks), wanted)
    if best <> invalid then return best.index
    return NxMbPreferredAudioIndex(tracks, languages)
end function

' The airing's audio pick: { index, position, language, count, airing }.
' index is the track's stream index for AudioStreamIndex, position its place
' among the file's `count` audio tracks and language its tag, all invalid
' with no choice to make. airing is `b`, or a copy
' carrying the picked track's codec and channels, so direct play is decided
' on that track and not the first.
function NxMbAudioPick(b as Object, languages as Object) as Object
    tracks = NxList(b.audioTracks)
    out = { index: NxMbChosenAudioIndex(tracks, languages), position: invalid, language: invalid, count: invalid, airing: b }
    if out.index = invalid then return out
    for i = 0 to tracks.Count() - 1
        if tracks[i].index = out.index then out.position = i
    end for
    picked = tracks[out.position]
    out.language = picked.language
    out.count = tracks.Count()
    out.airing = {}
    out.airing.Append(b)
    out.airing.audioCodec = picked.codec
    out.airing.audioChannels = picked.channels
    return out
end function

' Which of the player's availableAudioTracks plays the pick (NxMbAudioPick)
' on a direct play: its Track, or invalid to leave the player's own choice.
' By position when the player lists as many tracks as the file has, as a
' Roku TV did, in the file's order. Once one listed fewer (a file the scan
' said had more; why wasn't found), and then a position may name another
' track: the first listed in the pick's language instead, compared as the
' subtitle code compares.
function NxAudioTrackToSelect(listed as Object, want as Dynamic) as Dynamic
    if want = invalid or not NxIsNumber(want.position) then return invalid
    if listed.Count() = want.count then return listed[want.position].Track
    tag = NxSubComparableTag(want.language)
    if tag = invalid then return invalid
    ' Never a track named a commentary while another track is listed (#236).
    for each t in NxListedSkipCommentary(listed)
        if NxSubComparableTag(t.Language) = tag then return t.Track
    end for
    return invalid
end function

' The airing's first forced subtitle track in `lang` (NxMbForcedSubs), or
' invalid: forcedSubtitleToBurn's rule, its languages compared as the
' subtitle code compares them, so "eng" and "ger" match "en" and "de".
function NxMbForcedSub(b as Object, lang as String) as Dynamic
    for each t in NxList(b.forcedSubs)
        tag = NxSubComparableTag(t.language)
        if tag <> invalid and NxSubMatches(tag, lang) then return t
    end for
    return invalid
end function

' The airing's full text track in `lang` (NxMbFullSubs), or invalid. The
' Apple TV falls back to a file's first track when none is in the
' language (preferredTrackIndex); not here, as the first can be a
' commentary or a language nobody picked (issue #120).
function NxMbFullSub(b as Object, lang as String) as Dynamic
    for each t in NxList(b.fullSubs)
        tag = NxSubComparableTag(t.language)
        if tag <> invalid and NxSubMatches(tag, lang) then return t
    end for
    return invalid
end function

' The subtitle tracks a stream carries as the server's SRT, for
' content.SubtitleTracks: the forced track in `lang` (NxMbForcedSub) unless
' `drawForced`, which both callers pass since #237, the app drawing it
' instead (NxMbForcedSubUrl); and on a server stream (`direct` false)
' with `always` (SUBTITLES on ALWAYS), the full track in `lang`
' (NxMbFullSub), as the playlist lists none (Emby 4.10, even asked with
' SubtitleMethod=Hls), and applySubtitles picks it. A direct play lists the
' file's own. Only on ALWAYS, so a server makes the file only for a viewer
' who reads it (issue #120). The server needs no token for either.
function NxMbSubtitleSidecars(b as Object, base as String, lang as String, always as Boolean, direct as Boolean, drawForced = false as Boolean) as Object
    itemId = NxToStr(b.ratingKey)
    msid = NxToStr(NxOr(b.partKey, itemId))
    out = []
    forced = NxMbForcedSub(b, lang)
    ' drawForced: the app draws the forced track itself (#237, NxMbForcedSubUrl),
    ' so the player is given no forced sidecar and the TV's captions aren't needed.
    if drawForced then forced = invalid
    if forced <> invalid then out.Push({ Language: NxToStr(forced.language), TrackName: base + NxMbSubtitlePath(itemId, msid, forced.index), Description: "Forced" })
    full = invalid
    if always and not direct then full = NxMbFullSub(b, lang)
    if full <> invalid then out.Push({ Language: NxToStr(full.language), TrackName: base + NxMbSubtitlePath(itemId, msid, full.index) })
    return out
end function

' The forced track in `lang` as an address the app fetches and draws itself
' (#237, ForcedSubTask), or "" when the airing has none.
function NxMbForcedSubUrl(b as Object, base as String, lang as String) as String
    forced = NxMbForcedSub(b, lang)
    if forced = invalid then return ""
    itemId = NxToStr(b.ratingKey)
    return base + NxMbSubtitlePath(itemId, NxToStr(NxOr(b.partKey, itemId)), forced.index)
end function

' A subtitle track as SRT, from the server's root. Jellyfin and Emby both
' answer this form, with no token.
function NxMbSubtitlePath(itemId as String, msid as String, index as Integer) as String
    return "/Videos/" + NxUrlEncode(itemId) + "/" + NxUrlEncode(msid) + "/Subtitles/" + index.ToStr() + "/0/Stream.srt"
end function

' The subtitle SRTs to ask the server for ahead of time: for each airing
' that is on or starts within `windowSec` of `nowSec`, its forced track in
' `lang`, and with `always` (SUBTITLES on ALWAYS) its full track in `lang`
' too (NxMbFullSub), as addresses, less those in `done`. `audioLanguages`
' as NxMbViewerLanguages gives them, for the audio pick a direct play rests on,
' and `quality` STREAM QUALITY's level, whose ceiling can send it to the
' server instead. A server makes
' the file from the whole video, a minute or more for a large one the first
' time, and a Roku waits 30 s for it, twice, then shows the film without it;
' asked before the airing, the file is ready. `servers` maps an airing's
' serverIndex to its root, Jellyfin and Emby only. No full track for an
' airing this TV plays as stored (NxMbDirectPlays): a direct play lists the
' file's own, and the server would read the whole file for nothing.
function NxSubtitleWarmList(channels as Object, nowSec as LongInteger, windowSec as Integer, lang as String, always as Boolean, audioLanguages as Object, servers as Object, done as Object, quality = "auto" as String) as Object
    out = []
    seen = {}
    for each ch in NxList(channels)
        for each b in NxList(ch.blocks)
            if b.endSec > nowSec and b.startSec < nowSec + windowSec then
                base = servers[NxToStr(b.serverIndex)]
                picks = [NxMbForcedSub(b, lang)]
                if always and base <> invalid and b.fullSubs <> invalid then
                    if not NxMbDirectPlays(NxMbAudioPick(b, audioLanguages).airing, base, quality) then picks.Push(NxMbFullSub(b, lang))
                end if
                for each t in picks
                    if base <> invalid and t <> invalid then
                        key = base + NxMbSubtitlePath(NxToStr(b.ratingKey), NxToStr(NxOr(b.partKey, b.ratingKey)), t.index)
                        if not done.DoesExist(key) and not seen.DoesExist(key) then
                            seen[key] = true
                            out.Push(key)
                        end if
                    end if
                end for
            end if
        end for
    end for
    return out
end function

' The viewer's languages for NxMbAudioPick: AUDIO LANGUAGE, the TV's own
' until chosen (upstream reads the device's here). English is always added
' after it (NxMbPreferredAudioIndex).
function NxMbViewerLanguages() as Object
    return [NxAudioPreferredLanguage()]
end function

' The video part of the server stream's request. The Apple TV's Auto
' ceiling (StreamQuality), 40 Mb/s at up to 4K; without MaxWidth Emby
' re-encoded to 1080p, soft and blocky on a TV. Over 20 Mb/s the video is
' re-encoded, never copied: a copied piece runs from keyframe to keyframe,
' and with them far apart it can outgrow the player's buffer, error -3
' (issue #58: a 4K remux, keyframes up to 10 s apart, 53 MB pieces).
' The server decides by the file's average bitrate, so the ceiling alone
' copied a 26.5 Mb/s clip that then stopped with that error. A 19 Mb/s 4K
' file played copied, pieces up to 32 MB included (docs/JELLYFIN-EMBY.md).
' bitrate invalid (none reported) copies. The "capped" rung is upstream's
' cappedTranscodeURL (JellyfinPlaybackResolver.swift), 1080p at 8 Mb/s,
' and here never copied (AllowVideoStreamCopy=false): it is the rung a
' failed copied stream steps down to (NxFallbackNext), and a file at or
' under 8 Mb/s and 1080p would otherwise be copied again.
' A file re-encoded anyway comes no wider than this TV shows (width, from
' NxMaxWidthFor): a 4K re-encode costs about four times a 1080p one, for a
' 1080p TV that shows no more (PR #77). One that may be copied keeps 3840,
' since a narrower MaxWidth makes Emby re-encode what it would copy: a
' 46 Mb/s 4K HEVC clip came back copied at 3840 and as 1080p H.264 at 1920.
' `bitrate` is the file's, in kbps (an item's bitrate, as the web tuner and the
' Apple TV hold it); over 20,000 kbps (20 Mb/s) it is re-encoded. Before the
' unit change this compared bits per second with 20,000,000, so a file within
' half a kbps of 20 Mb/s can now land on the other side.
' STREAM QUALITY's High, Medium and Low (`quality`) ask for their own bitrate
' and width, the width no more than this TV shows, as the Apple TV's
' buildTranscodeURL asks for the level's VideoBitrate and MaxWidth. A file
' already under both may still be copied. Auto and Maximum ask as above,
' which is the Apple TV's Auto; the "capped" rung asks the same whatever the
' level (source/util/StreamQuality.brs).
function NxMbVideoQuery(bitrate as Dynamic, rung = "server" as String, width = 3840 as Integer, quality = "auto" as String) as String
    if rung = "capped" then return "&VideoBitrate=8000000&MaxWidth=1920&AllowVideoStreamCopy=false"
    noCopy = ""
    if NxIsNumber(bitrate) and bitrate > 20000 then noCopy = "&AllowVideoStreamCopy=false"
    if NxSqIsCapped(quality) then
        l = NxSqLevel(quality)
        w = l.width
        if width < w then w = width
        return "&VideoBitrate=" + (l.maxBitrateKbps * 1000).ToStr() + "&MaxWidth=" + w.ToStr() + noCopy
    end if
    if noCopy <> "" then return "&VideoBitrate=40000000&MaxWidth=" + width.ToStr() + noCopy
    return "&VideoBitrate=40000000&MaxWidth=3840"
end function

' The width to ask the server for, from roDeviceInfo's GetVideoMode: the
' TV's output ("1080p", "2160p60"), not the UI's resolution, which is 1080p
' on a 4K TCL. 1280 below 1080 lines. A mode it can't read keeps 3840, as
' before.
function NxMaxWidthFor(videoMode as String) as Integer
    ' The leading digits, read by hand: Val("1080p") is 0 off the TV.
    lines = 0
    for i = 1 to Len(videoMode)
        c = Asc(Mid(videoMode, i, 1))
        if c < 48 or c > 57 then exit for
        lines = lines * 10 + (c - 48)
    end for
    if lines <= 0 or lines >= 2160 then return 3840
    if lines >= 1080 then return 1920
    return 1280
end function

' The audio the server stream may carry: AAC, and AC3 or E-AC-3 only when
' this TV decodes them, at most 5.1 only when it decodes 5.1 AAC. A codec in
' the list is copied as stored, so offering Dolby to a TV that says no to it
' played silent (Discussion #8: E-AC-3 on a Streaming Stick Plus set to
' Stereo). Without the cap a 5.1 film came back as 5.1 AAC, which that stick
' doesn't decode either; with it, stereo AAC, as Plex sends.
function NxMbAudioQuery(ac3 as Boolean, eac3 as Boolean, aac51 as Boolean) as String
    codecs = "aac"
    if ac3 then codecs = codecs + ",ac3"
    if eac3 then codecs = codecs + ",eac3"
    channels = "2"
    if aac51 then channels = "6"
    return "&AudioCodec=" + codecs + "&TranscodingMaxAudioChannels=" + channels
end function

' The saved server an airing comes from, or invalid.
function NxStreamServer(b as Object) as Dynamic
    ' Signing out empties the list while a stream may still be stopping.
    raw = NxPlexRegistry().Read("servers")
    if raw = "" then return invalid
    servers = ParseJson(raw)
    if type(servers) <> "roArray" or b.serverIndex = invalid then return invalid
    if b.serverIndex >= servers.Count() then return invalid
    return servers[b.serverIndex]
end function

' The airing as something to play, from whichever kind of server it is on:
' { content, stopUrl, route, rung }, or invalid.
function NxStreamContent(b as Object, offsetSec as LongInteger, rung = "auto" as String) as Dynamic
    s = NxStreamServer(b)
    if s = invalid then return invalid
    if NxServerKind(s) = "plex" then return NxPlexStreamContent(b, offsetSec, rung)
    return NxMbStreamContent(b, offsetSec, s, rung)
end function

' Video nodes take headers through their own ifHttpAgent; a ContentNode's
' HttpHeaders field alone left a TV buffering with no request reaching Plex.
sub NxApplyStreamAuth(video as Object, b as Object)
    s = NxStreamServer(b)
    if s = invalid then return
    if NxServerKind(s) = "plex" then
        NxPlexApplyAuth(video, NxToStr(s.accessToken))
        return
    end if
    video.SetCertificatesFile("common:/certs/ca-bundle.crt")
    video.SetHeaders({ "Authorization": NxMbAuthHeader(NxToStr(s.accessToken)) })
end sub

' Asks the server about a stream that didn't play, as upstream's
' StreamFailureProbe.refusalStatus: a playlist is followed down to its first
' segment, at most three hops, since a server that can't build a transcode
' still serves the playlists and refuses only the segment. Media is asked for
' two bytes. Returns the first refusal, else the last status, or
' roUrlTransfer's code when nothing answered (NxProbeVerdict). Runs in
' StreamProbeTask; the token comes from the registry.
function NxProbeStream(url as String, serverIndex as Integer) as Integer
    s = NxStreamServer({ serverIndex: serverIndex })
    if s = invalid then return 1
    headers = NxMbHeaders(NxToStr(s.accessToken))
    if NxServerKind(s) = "plex" then headers = NxPlexHeaders(NxToStr(s.accessToken))
    current = url
    last = 1
    for hop = 0 to 2
        playlist = NxIsPlaylistUrl(current)
        h = {}
        h.Append(headers)
        if not playlist then h["Range"] = "bytes=0-1"
        got = NxProbeFetch(current, h)
        print "player: probe hop "; hop; ": "; got.code
        last = got.code
        if NxProbeVerdict(last) <> "answered" or not playlist then return last
        current = NxFirstMediaUrl(got.body, current)
        if current = "" then return last
    end for
    return last
end function

' One GET for NxProbeStream: { code, body }, five seconds at most.
function NxProbeFetch(url as String, headers as Object) as Object
    xfer = NxServerTransfer(url, headers)
    if xfer = invalid then return { code: 0, body: "" }
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    if not xfer.AsyncGetToString() then return { code: -1, body: "" }
    msg = Wait(5000, port)
    if type(msg) <> "roUrlEvent" then
        xfer.AsyncCancel()
        return { code: -28, body: "" }
    end if
    return { code: msg.GetResponseCode(), body: msg.GetString() }
end function

' Ends the server's work on a stream the guide has left (PlexStopTask).
' Jellyfin and Emby: DELETE /Videos/ActiveEncodings, which ends an encode
' within about a second (the web tuner sends only this). Returns the HTTP code.
function NxStopStream(stopUrl as String, serverIndex as Integer) as Integer
    s = NxStreamServer({ serverIndex: serverIndex })
    if s = invalid then return 0
    if NxServerKind(s) = "plex" then return NxPlexVideoRequest(stopUrl, NxToStr(s.accessToken))
    return NxServerRequest("DELETE", stopUrl, NxMbHeaders(NxToStr(s.accessToken)), "", 5000).code
end function
