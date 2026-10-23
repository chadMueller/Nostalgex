' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' What a start that fails does next, after upstream's ladder
' (App/AppState+Playback.swift, Services/PlaybackWatchdog.swift,
' Services/PlaybackFailure.swift, Services/ChannelFailureRun.swift). Pure,
' so tests/FallbackTests.brs checks it; the player is in
' components/GuideView.brs.
'
' An attempt is { rung, retry, fellBack }: rung "direct" (the file as
' stored), "server" (the server's stream) or "capped" (upstream's 1080p
' compatibility stream); retry, whether it repeats the same request; fellBack,
' whether direct play came first. The two events are "error" (the player
' gave up) and "nopicture" (no picture by NxPictureDeadline).

' The first attempt, for the rung NxStreamContent chose.
function NxFirstAttempt(rung as String) as Object
    return { rung: rung, retry: false, fellBack: false }
end function

' The next attempt after `event`, or invalid for none: the card, then the next
' programme. Upstream's order:
'   - direct play, either way: the server's stream (fallbackToTranscode,
'     beginServerFallback).
'   - a server stream that errors: one retry of the same request, but only
'     when it was the first thing tried (retryLoad). One reached from direct
'     play, or already retried, gives up (autoSkipOnError).
'   - a server stream with no picture, retried or not: the 1080p stream
'     (handleWatchdogNoPicture, allowCappedRetry).
'   - the 1080p stream: gives up.
function NxFallbackNext(attempt as Object, event as String) as Dynamic
    if attempt.rung = "direct" then return { rung: "server", retry: false, fellBack: true }
    if attempt.rung <> "server" then return invalid
    if event = "nopicture" then return { rung: "capped", retry: false, fellBack: attempt.fellBack }
    if attempt.retry or attempt.fellBack then return invalid
    return { rung: "server", retry: true, fellBack: false }
end function

' Seconds a start has to show a picture (PlaybackWatchdog.deadlineSeconds).
' A 4K source the server re-encodes needs its transcoder spun up, a seek and a
' first segment. Width as well as height: a 2.39:1 UHD frame is 3840 by 1606.
function NxPictureDeadline(rung as String, width as Dynamic, height as Dynamic) as Integer
    if rung = "direct" then return 15
    uhd = (NxIsNumber(height) and height >= 2000) or (NxIsNumber(width) and width >= 3000)
    if uhd then return 40
    return 20
end function

' ── Five in a row (ChannelFailureRun) ───────────────────────────────────────

' Programmes on one channel that failed in a row with no picture in between.
' After five the channel stops, so a channel where nothing plays doesn't ask
' the server again every few seconds for as long as the TV stays on. Five
' because one bad file, or a few next to each other, still skip and carry on:
' with half a channel playing, five in a row comes up about one time in 32.
function NxFailureRunLimit() as Integer
    return 5
end function

function NxFailureRun() as Object
    return { channelId: invalid, count: 0 }
end function

' One more programme on channelId failed. Returns true when the channel
' should stop.
function NxFailureRecord(fr as Object, channelId as String) as Boolean
    if fr.channelId = invalid or fr.channelId <> channelId then
        fr.channelId = channelId
        fr.count = 0
    end if
    fr.count = fr.count + 1
    return fr.count >= NxFailureRunLimit()
end function

' A picture reached the screen, or the viewer chose a channel.
sub NxFailureReset(fr as Object)
    fr.channelId = invalid
    fr.count = 0
end sub

' ── The card (PlaybackFailure, PlaybackFailureCard) ─────────────────────────

' Why a programme couldn't play, from what the player said when it gave up:
' { kind, serverSide, headline, detail, nextStep }. No URL, token or raw
' error text. e is { server, event, rung, errorCode, category, probe,
' codec }: server "Plex", "Jellyfin" or "Emby"; event "error", "nopicture" or
' "nostream" (nothing to request); errorCode and category the Video node's;
' probe what NxProbeStream got back, 1 when it didn't run. The HTTP status
' comes from the probe: the player's errorInfo had none (an HTTP error
' read errcode 2 on a 43S45). Upstream's order: what the server answered
' first, as the more specific fact, then nothing answering, then a decode
' failure.
function NxPlaybackFailure(e as Object) as Object
    server = NxToStr(e.server)
    probe = 1
    if NxIsNumber(e.probe) then probe = e.probe
    status = 0
    if NxProbeVerdict(probe) = "refused" then status = probe
    kind = "unknown"
    ' Starving outranks the rest: the server answered and still couldn't be
    ' watched (PlaybackFailure.classify, starvedAfterCappedRetry).
    if e.event = "starved" then
        kind = "serverTooSlow"
    else if e.event = "nostream" then
        kind = "noPlayableSource"
    else if status = 401 or status = 403 then
        kind = "notAuthorised"
    else if status = 404 then
        kind = "fileMissing"
    else if status >= 400 then
        kind = "serverRefused"
    else if e.errorCode = -2 or NxProbeVerdict(probe) = "unreachable" then
        kind = "serverUnreachable"
    else if e.errorCode = -5 or LCase(NxToStr(e.category)) = "mediaerror" then
        kind = "deviceCannotRender"
    else if e.event = "nopicture" and e.rung = "capped" then
        ' The server answered, and even its 1080p stream never made a picture.
        kind = "serverTooSlow"
    end if
    return NxFailureCard(kind, server, status, e.codec)
end function

function NxFailureCard(kind as String, server as String, status as Integer, codec as Dynamic) as Object
    c = { kind: kind, serverSide: true, nextStep: "Moving on to the next programme." }
    if kind = "serverRefused" then
        c.headline = "Your server wouldn't start this one"
        c.detail = server + " answered HTTP " + status.ToStr() + " before it started sending video. That's the server, not this file and not your network. Other titles on the same server are unaffected."
    else if kind = "fileMissing" then
        c.headline = "Your server can't find this file"
        c.detail = server + " listed this title but couldn't open the file. It was probably moved or deleted since the last library scan."
    else if kind = "notAuthorised" then
        c.headline = "Your server refused the request"
        c.detail = server + " rejected the sign-in saved on this TV. Open Settings, sign out and sign in again."
    else if kind = "serverTooSlow" then
        c.headline = "Your server couldn't keep up"
        c.detail = server + " couldn't produce video fast enough to watch, even after dropping to 1080p. The file is probably too heavy for it to convert."
    else if kind = "serverUnreachable" then
        c.headline = "Can't reach your server"
        c.detail = "Nothing answered at the address saved for your " + server + " server. Check it's awake and on the same network."
    else if kind = "deviceCannotRender" then
        c.serverSide = false
        c.headline = "This Roku couldn't play this file"
        what = "This file"
        if NxToStr(codec) <> "" then what = "This " + UCase(NxToStr(codec)) + " file"
        c.detail = what + " arrived, but this Roku couldn't turn it into a picture. The server sent it in a format this TV can't decode."
    else if kind = "noPlayableSource" then
        c.headline = "Nothing to play for this title"
        c.detail = "Its server isn't set up on this TV."
    else
        c.serverSide = false
        c.headline = "This one wouldn't play"
        c.detail = "No reason came back from " + server + " or from the player."
    end if
    return c
end function

' The card once NxFailureRecord says stop: it stays until the viewer tunes.
function NxChannelStoppedCard(last as Object) as Object
    return {
        kind: "channelStopped", serverSide: last.serverSide,
        headline: "Nothing on this channel will play right now",
        detail: NxFailureRunLimit().ToStr() + " programmes in a row wouldn't play, so this channel has stopped trying. Last reason: " + last.headline + ".",
        nextStep: "Try another channel, or select this one again to retry."
    }
end function

' The display name for a server kind ("plex", "jellyfin", "emby").
function NxServerDisplayName(kind as String) as String
    if kind = "plex" then return "Plex"
    if kind = "jellyfin" then return "Jellyfin"
    if kind = "emby" then return "Emby"
    return "Your server"
end function

' ── Asking the server (StreamFailureProbe) ──────────────────────────────────

' What a probe's answer says. Roku's player gives no HTTP status for most
' failures, and with the server stopped it gave nothing at all: it buffered
' until each deadline (docs/PORTING.md). "refused" for a 4xx or 5xx;
' "unreachable" when nothing answered (roUrlTransfer's negative codes, -7
' couldn't connect and -28 timed out among them, or 0); "answered" otherwise,
' when the player's own signals decide. code 1 means the probe didn't run.
function NxProbeVerdict(code as Integer) as String
    if code >= 400 then return "refused"
    if code <= 0 then return "unreachable"
    return "answered"
end function

' Whether a URL is an HLS playlist, by its path.
function NxIsPlaylistUrl(url as String) as Boolean
    path = url
    q = Instr(1, path, "?")
    if q > 0 then path = Left(path, q - 1)
    return LCase(Right(path, 5)) = ".m3u8"
end function

' The first URI in a playlist, resolved against the playlist's own address:
' the variant for a master playlist, the first segment for a media one.
' Emby and Jellyfin write them relative. "" when there is none.
function NxFirstMediaUrl(text as String, base as String) as String
    lines = text.Tokenize(Chr(10) + Chr(13))
    for each raw in lines
        line = raw.Trim()
        if line <> "" and Left(line, 1) <> "#" then
            if CreateObject("roRegex", "^https?://", "i").IsMatch(line) then return line
            path = base
            q = Instr(1, path, "?")
            if q > 0 then path = Left(path, q - 1)
            if Left(line, 1) = "/" then
                hit = CreateObject("roRegex", "^(https?://[^/]+)", "i").Match(path)
                if hit.Count() < 2 then return ""
                return hit[1] + line
            end if
            slash = 0
            for i = Len(path) to 1 step -1
                if Mid(path, i, 1) = "/" then
                    slash = i
                    exit for
                end if
            end for
            return Left(path, slash) + line
        end if
    end for
    return ""
end function

' ── Starving (PlaybackStarvation) ───────────────────────────────────────────

' A stream that was playing and can't be fed: three stalls in 120 s, or one
' of 20 s. A stall is under 0.25 s of playhead progress for 3 s or more,
' judged by the playhead, not the player's buffering flags. It arms after
' 1 s of progress, so a start is the deadline's call, and the last 5 s of an
' item are the end, not a stall. Fed one sample a second.
function NxStarvation() as Object
    return { armed: false, first: invalid, last: invalid, stallStart: invalid, stallsEnded: [], longest: 0# }
end function

' One sample. playhead and wall in seconds (only differences matter);
' remaining, seconds to the end of the item, or invalid. Returns
' { stalls, longest } once it is starving, else invalid.
function NxStarvationObserve(s as Object, playhead as Double, wall as Double, paused as Boolean, remaining as Dynamic) as Dynamic
    if paused then return invalid
    if remaining <> invalid and remaining <= 5 then return invalid
    if s.first = invalid then s.first = playhead
    last = s.last
    s.last = playhead
    if not s.armed then
        if playhead - s.first >= 1 then s.armed = true
        return invalid
    end if
    if last = invalid then return invalid
    if playhead - last >= 0.25 then
        if s.stallStart <> invalid and wall - s.stallStart >= 3 then
            s.stallsEnded.Push(wall)
            if wall - s.stallStart > s.longest then s.longest = wall - s.stallStart
        end if
        s.stallStart = invalid
    else
        if s.stallStart = invalid then s.stallStart = wall
        length = wall - s.stallStart
        if length > s.longest then s.longest = length
        if length >= 20 then return { stalls: s.stallsEnded.Count() + 1, longest: s.longest }
    end if
    kept = []
    for each t in s.stallsEnded
        if wall - t <= 120 then kept.Push(t)
    end for
    s.stallsEnded = kept
    if kept.Count() >= 3 then return { stalls: kept.Count(), longest: s.longest }
    return invalid
end function

' The step after a starving stream (handleStarvation): direct play to the
' server's stream, a server stream to the 1080p one, both from where it got
' to; the 1080p stream starving too, invalid: "couldn't keep up".
function NxStarvedNext(attempt as Object) as Dynamic
    if attempt.rung = "direct" then return { rung: "server", retry: false, fellBack: true }
    if attempt.rung = "server" then return { rung: "capped", retry: false, fellBack: attempt.fellBack }
    return invalid
end function
