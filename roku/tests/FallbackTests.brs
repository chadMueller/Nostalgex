' Runs source/guide/Fallback.brs against upstream's ladder: the rung order
' (AppState+Playback.swift's fallbackToTranscode, retryLoad and
' handleWatchdogNoPicture), the deadlines (PlaybackWatchdog), five in a row
' (ChannelFailureRun) and the card (PlaybackFailure). Transcribed from the
' Swift, not generated. Returns the failure count.

function NxRunFallbackTests() as Integer
    r = { pass: 0, fail: 0 }

    ' The rungs.
    direct = NxFirstAttempt("direct")
    server = NxFirstAttempt("server")
    NxCheck(r, "direct play errors: the server stream", NxAttemptText(NxFallbackNext(direct, "error")), "server fellBack")
    NxCheck(r, "direct play, no picture: the server stream", NxAttemptText(NxFallbackNext(direct, "nopicture")), "server fellBack")
    NxCheck(r, "server stream errors: one retry", NxAttemptText(NxFallbackNext(server, "error")), "server retry")
    retried = NxFallbackNext(server, "error")
    NxCheck(r, "the retry errors: give up", NxAttemptText(NxFallbackNext(retried, "error")), "none")
    fellBack = NxFallbackNext(direct, "error")
    NxCheck(r, "server stream after direct play errors: give up", NxAttemptText(NxFallbackNext(fellBack, "error")), "none")
    NxCheck(r, "server stream, no picture: 1080p", NxAttemptText(NxFallbackNext(server, "nopicture")), "capped")
    NxCheck(r, "the retry, no picture: 1080p", NxAttemptText(NxFallbackNext(retried, "nopicture")), "capped")
    NxCheck(r, "after direct play, no picture: 1080p", NxAttemptText(NxFallbackNext(fellBack, "nopicture")), "capped fellBack")
    capped = NxFallbackNext(server, "nopicture")
    NxCheck(r, "1080p errors: give up", NxAttemptText(NxFallbackNext(capped, "error")), "none")
    NxCheck(r, "1080p, no picture: give up", NxAttemptText(NxFallbackNext(capped, "nopicture")), "none")
    ' The longest way down: direct, server, retry is skipped after a
    ' fallback, 1080p, then the card. Three starts.
    a = direct
    starts = 1
    events = ["error", "nopicture", "nopicture"]
    for each ev in events
        a = NxFallbackNext(a, ev)
        if a = invalid then exit for
        starts = starts + 1
    end for
    NxCheck(r, "direct, server, 1080p, card", starts.ToStr(), "3")

    ' The deadlines.
    NxCheck(r, "direct play gets 15 s", NxPictureDeadline("direct", 3840, 2160).ToStr(), "15")
    NxCheck(r, "a 1080p server stream gets 20 s", NxPictureDeadline("server", 1920, 1080).ToStr(), "20")
    NxCheck(r, "a 4K server stream gets 40 s", NxPictureDeadline("server", 3840, 2160).ToStr(), "40")
    NxCheck(r, "2.39:1 UHD counts by its width", NxPictureDeadline("server", 3840, 1606).ToStr(), "40")
    NxCheck(r, "2000 tall counts", NxPictureDeadline("server", invalid, 2000).ToStr(), "40")
    NxCheck(r, "no size: 20 s", NxPictureDeadline("server", invalid, invalid).ToStr(), "20")
    NxCheck(r, "the 1080p stream of a 4K file keeps 40 s", NxPictureDeadline("capped", 3840, 2160).ToStr(), "40")

    ' Five in a row.
    fr = NxFailureRun()
    stops = []
    for i = 1 to 5
        stops.Push(NxFailureRecord(fr, "7").ToStr())
    end for
    NxCheck(r, "the fifth in a row stops the channel", stops.Join(" "), "false false false false true")
    NxFailureReset(fr)
    NxCheck(r, "a picture starts the count again", NxFailureRecord(fr, "7").ToStr() + " " + fr.count.ToStr(), "false 1")
    for i = 1 to 3
        NxFailureRecord(fr, "7")
    end for
    NxCheck(r, "another channel counts from one", NxFailureRecord(fr, "8").ToStr() + " " + fr.count.ToStr(), "false 1")

    ' The card.
    NxCheck(r, "401", NxFailureKind(401, 0, "", "error", "server"), "notAuthorised")
    NxCheck(r, "403", NxFailureKind(403, 0, "", "error", "server"), "notAuthorised")
    NxCheck(r, "404", NxFailureKind(404, 0, "", "error", "server"), "fileMissing")
    NxCheck(r, "500", NxFailureKind(500, 0, "", "error", "server"), "serverRefused")
    NxCheck(r, "the server's answer before a decode error", NxFailureKind(500, -5, "mediaerror", "error", "server"), "serverRefused")
    NxCheck(r, "timed out", NxFailureKind(0, -2, "", "error", "server"), "serverUnreachable")
    NxCheck(r, "media error", NxFailureKind(0, -5, "", "error", "server"), "deviceCannotRender")
    NxCheck(r, "media error by category", NxFailureKind(0, -3, "mediaerror", "error", "server"), "deviceCannotRender")
    NxCheck(r, "1080p never made a picture", NxFailureKind(0, 0, "", "nopicture", "capped"), "serverTooSlow")
    NxCheck(r, "no reason", NxFailureKind(0, -3, "", "error", "server"), "unknown")
    NxCheck(r, "nothing to request", NxFailureKind(0, 0, "", "nostream", ""), "noPlayableSource")

    refused = NxPlaybackFailure({ server: "Emby", event: "error", rung: "server", errorCode: -1, category: "http", probe: 500, codec: "hevc" })
    NxCheck(r, "refused names the status", refused.detail, "Emby answered HTTP 500 before it started sending video. That's the server, not this file and not your network. Other titles on the same server are unaffected.")
    NxCheck(r, "refused is the server's", refused.serverSide.ToStr(), "true")
    render = NxPlaybackFailure({ server: "Plex", event: "error", rung: "server", errorCode: -5, category: "", probe: 206, codec: "hevc" })
    NxCheck(r, "can't render is the TV's", render.serverSide.ToStr(), "false")
    NxCheck(r, "can't render names the codec", render.detail, "This HEVC file arrived, but this Roku couldn't turn it into a picture. The server sent it in a format this TV can't decode.")
    NxCheck(r, "unknown is not the server's", NxPlaybackFailure({ server: "Plex", event: "error", errorCode: -3 }).serverSide.ToStr(), "false")
    NxCheck(r, "the card moves on", refused.nextStep, "Moving on to the next programme.")
    stopped = NxChannelStoppedCard(refused)
    NxCheck(r, "stopped headline", stopped.headline, "Nothing on this channel will play right now")
    NxCheck(r, "stopped gives the last reason", stopped.detail, "5 programmes in a row wouldn't play, so this channel has stopped trying. Last reason: Your server wouldn't start this one.")
    NxCheck(r, "stopped keeps the last one's colour", stopped.serverSide.ToStr() + " " + NxChannelStoppedCard(render).serverSide.ToStr(), "true false")
    NxCheck(r, "stopped says how to retry", stopped.nextStep, "Try another channel, or select this one again to retry.")
    ' No address, token or raw error text on any card.
    leaks = []
    kinds = ["serverRefused", "fileMissing", "notAuthorised", "serverTooSlow", "serverUnreachable", "deviceCannotRender", "noPlayableSource", "unknown"]
    for each k in kinds
        c = NxFailureCard(k, "Jellyfin", 502, "h264")
        text = LCase(c.headline + " " + c.detail + " " + c.nextStep)
        if Instr(1, text, "://") > 0 or Instr(1, text, "token") > 0 or Instr(1, text, "error") > 0 then leaks.Push(k)
    end for
    NxCheck(r, "no card shows an address, token or error text", leaks.Join(" "), "")

    ' The server's answer (StreamFailureProbe).
    NxCheck(r, "probe 500 refused", NxProbeVerdict(500), "refused")
    NxCheck(r, "probe 206 answered", NxProbeVerdict(206), "answered")
    NxCheck(r, "probe couldn't connect", NxProbeVerdict(-7), "unreachable")
    NxCheck(r, "probe timed out", NxProbeVerdict(-28), "unreachable")
    NxCheck(r, "probe not run", NxProbeVerdict(1), "answered")
    NxCheck(r, "stopped server: can't reach", NxPlaybackFailure({ server: "Emby", event: "nopicture", rung: "direct", probe: -7 }).kind, "serverUnreachable")
    NxCheck(r, "stopped server beats the 1080p verdict", NxPlaybackFailure({ server: "Emby", event: "nopicture", rung: "capped", probe: -28 }).kind, "serverUnreachable")
    NxCheck(r, "probe 404: file missing", NxPlaybackFailure({ server: "Emby", event: "error", rung: "server", errorCode: -3, probe: 404 }).kind, "fileMissing")
    NxCheck(r, "probe 500 beats a decode error", NxPlaybackFailure({ server: "Emby", event: "error", rung: "server", errorCode: -5, probe: 500 }).kind, "serverRefused")
    NxCheck(r, "probe answered: the player decides", NxPlaybackFailure({ server: "Emby", event: "nopicture", rung: "capped", probe: 200 }).kind, "serverTooSlow")
    NxCheck(r, "no probe: the player decides", NxPlaybackFailure({ server: "Emby", event: "error", rung: "server", errorCode: -5 }).kind, "deviceCannotRender")
    NxCheck(r, "playlist url", NxIsPlaylistUrl("http://h:8097/Videos/1/master.m3u8?a=b").ToStr(), "true")
    NxCheck(r, "media url", NxIsPlaylistUrl("http://h:8097/Videos/1/stream.mp4?Static=true&x=.m3u8").ToStr(), "false")
    master = "#EXTM3U" + Chr(10) + "#EXT-X-STREAM-INF:BANDWIDTH=1" + Chr(10) + "main.m3u8?PlaySessionId=s" + Chr(10)
    NxCheck(r, "relative variant", NxFirstMediaUrl(master, "http://h:8097/emby/Videos/1/master.m3u8?a=b"), "http://h:8097/emby/Videos/1/main.m3u8?PlaySessionId=s")
    media = "#EXTM3U" + Chr(13) + Chr(10) + "#EXTINF:2," + Chr(13) + Chr(10) + "hls1/main/0.ts?x=1" + Chr(13) + Chr(10)
    NxCheck(r, "relative segment, CRLF", NxFirstMediaUrl(media, "http://h:8097/Videos/1/main.m3u8"), "http://h:8097/Videos/1/hls1/main/0.ts?x=1")
    NxCheck(r, "rooted segment", NxFirstMediaUrl("/video/:/transcode/s/0.ts" + Chr(10), "https://p.example:32400/video/:/transcode/universal/start.m3u8?q"), "https://p.example:32400/video/:/transcode/s/0.ts")
    NxCheck(r, "absolute segment", NxFirstMediaUrl("https://x/0.ts" + Chr(10), "http://h/a.m3u8"), "https://x/0.ts")
    NxCheck(r, "empty playlist", NxFirstMediaUrl("#EXTM3U" + Chr(10), "http://h/a.m3u8"), "")

    ' What each rung asks of the server.
    NxCheck(r, "Plex server stream adds nothing", NxPlexRungQuery("server"), "")
    NxCheck(r, "Plex 1080p", NxPlexRungQuery("capped"), "&maxVideoBitrate=12000&videoQuality=90&videoResolution=1920x1080")
    NxCheck(r, "Jellyfin/Emby 1080p", NxMbVideoQuery(29000000, "capped"), "&VideoBitrate=8000000&MaxWidth=1920")
    NxCheck(r, "Jellyfin/Emby server stream as before", NxMbVideoQuery(29000000, "server"), "&VideoBitrate=40000000&MaxWidth=3840&AllowVideoStreamCopy=false")

    ' Starving: PlaybackStarvationTests, case for case. The measured shape is
    ' the basement Apple TV's Armageddon, 2026-10-06.
    st = NxStarvation()
    NxCheck(r, "starve: healthy never starves", NxStarveText(NxStarveFeed(st, NxPlayingTrace(0, 600))), "none")
    NxCheck(r, "starve: healthy arms", st.armed.ToStr(), "true")
    t = []
    head = 0
    for i = 1 to 3
        t.Append(NxPlayingTrace(head, 25))
        head = head + 25
        t.Append(NxFrozenTrace(head, 10))
    end for
    t.Append(NxPlayingTrace(head, 5))
    v = NxStarveFeed(NxStarvation(), t)
    NxCheck(r, "starve: three stalls in the window", NxStarveText(v), "3")
    if v <> invalid then NxCheck(r, "starve: three stalls, longest at least 9", (v.longest >= 9).ToStr(), "true")
    t = NxPlayingTrace(100, 30)
    t.Append(NxFrozenTrace(130, 25))
    v = NxStarveFeed(NxStarvation(), t)
    NxCheck(r, "starve: one long freeze", NxStarveText(v), "1")
    if v <> invalid then NxCheck(r, "starve: one long freeze, longest at least 20", (v.longest >= 20).ToStr(), "true")
    st = NxStarvation()
    NxCheck(r, "starve: startup is not a stall", NxStarveText(NxStarveFeed(st, NxFrozenTrace(0, 60))), "none")
    NxCheck(r, "starve: startup doesn't arm", st.armed.ToStr(), "false")
    t = []
    head = 0
    for i = 1 to 40
        t.Append(NxPlayingTrace(head, 8))
        head = head + 8
        t.Append(NxFrozenTrace(head, 2))
    end for
    NxCheck(r, "starve: brief segment pauses", NxStarveText(NxStarveFeed(NxStarvation(), t)), "none")
    t = []
    head = 0
    for i = 1 to 3
        t.Append(NxPlayingTrace(head, 90))
        head = head + 90
        t.Append(NxFrozenTrace(head, 5))
    end for
    t.Append(NxPlayingTrace(head, 5))
    NxCheck(r, "starve: stalls wider than the window", NxStarveText(NxStarveFeed(NxStarvation(), t)), "none")
    st = NxStarvation()
    for i = 0 to 9
        NxStarvationObserve(st, i, i, false, 3000)
    end for
    quiet = true
    for i = 10 to 59
        if NxStarvationObserve(st, 10, i, true, 3000) <> invalid then quiet = false
    end for
    NxCheck(r, "starve: paused samples ignored", quiet.ToStr(), "true")
    st = NxStarvation()
    for i = 0 to 9
        NxStarvationObserve(st, i, i, false, 3000)
    end for
    quiet = true
    for i = 10 to 59
        if NxStarvationObserve(st, 10, i, false, 2) <> invalid then quiet = false
    end for
    NxCheck(r, "starve: the tail is the end's", quiet.ToStr(), "true")
    t = NxPlayingTrace(0, 20)
    t.Append(NxFrozenTrace(20, 5))
    t.Append(NxPlayingTrace(20, 20))
    t.Append(NxFrozenTrace(40, 5))
    t.Append(NxPlayingTrace(40, 200))
    NxCheck(r, "starve: two stalls then recovery", NxStarveText(NxStarveFeed(NxStarvation(), t)), "none")

    ' The step after starving (handleStarvation), and its card.
    NxCheck(r, "starved direct", NxAttemptText(NxStarvedNext(direct)), "server fellBack")
    NxCheck(r, "starved server", NxAttemptText(NxStarvedNext(server)), "capped")
    NxCheck(r, "starved server from direct", NxAttemptText(NxStarvedNext({ rung: "server", retry: false, fellBack: true })), "capped fellBack")
    NxCheck(r, "starved retried server", NxAttemptText(NxStarvedNext({ rung: "server", retry: true, fellBack: false })), "capped")
    NxCheck(r, "starved 1080p", NxAttemptText(NxStarvedNext({ rung: "capped", retry: false, fellBack: false })), "none")
    NxCheck(r, "starved card", NxFailureKind(0, 0, "", "starved", "capped"), "serverTooSlow")
    NxCheck(r, "starved outranks a refusal", NxFailureKind(500, -1, "http", "starved", "capped"), "serverTooSlow")

    print "fallback cases (upstream ladder): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

function NxAttemptText(a as Dynamic) as String
    if a = invalid then return "none"
    out = a.rung
    if a.retry then out = out + " retry"
    if a.fellBack then out = out + " fellBack"
    return out
end function

function NxFailureKind(status as Integer, errorCode as Integer, category as String, event as String, rung as String) as String
    probe = 206
    if status > 0 then probe = status
    return NxPlaybackFailure({ server: "Plex", event: event, rung: rung, errorCode: errorCode, category: category, probe: probe, codec: invalid }).kind
end function

' Feeds playheads one a second from wall 0, remaining 3000 s, until a verdict.
function NxStarveFeed(st as Object, playheads as Object) as Dynamic
    for i = 0 to playheads.Count() - 1
        v = NxStarvationObserve(st, playheads[i], i, false, 3000)
        if v <> invalid then return v
    end for
    return invalid
end function

function NxStarveText(v as Dynamic) as String
    if v = invalid then return "none"
    return v.stalls.ToStr()
end function

' 1 s of playhead a second, from `from`.
function NxPlayingTrace(from as Double, seconds as Integer) as Object
    out = []
    for i = 0 to seconds - 1
        out.Push(from + i)
    end for
    return out
end function

function NxFrozenTrace(at as Double, seconds as Integer) as Object
    out = []
    for i = 1 to seconds
        out.Push(at)
    end for
    return out
end function
