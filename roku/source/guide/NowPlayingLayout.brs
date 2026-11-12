' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Upstream's NowPlayingPanelLayout (Services/NowPlayingPanelLogic.swift):
' which rows the panel's program column shows, in order. A language
' preference is offered only when there is something to pick between:
' SUBTITLE LANGUAGE with a subtitle track the player lists (a forced track,
' which the app draws itself since #237, isn't one), AUDIO LANGUAGE with
' more than one audio track. OPEN IN PLEX is left out, as the Roku can't
' open another app on an item.

' header (AUDIO & CAPTIONS), captions, subtitleLanguage, autoSubtitles, audio
' (one row: the current track, opening the track list; a plain row with one
' track or none), audioLanguage.
function NxPanelProgramRows(hasSubtitleTracks as Boolean, audioTrackCount as Integer) as Object
    rows = ["header", "captions"]
    if hasSubtitleTracks then
        rows.Push("subtitleLanguage")
        rows.Push("autoSubtitles")
    end if
    rows.Push("audio")
    if audioTrackCount > 1 then rows.Push("audioLanguage")
    return rows
end function

' The audio row opens a track list only when there is a choice to make
' (upstream's audioRowOpensList).
function NxAudioRowOpensList(trackCount as Integer) as Boolean
    return trackCount > 1
end function

' The badge after the next programme's title on the Now Playing panel (#266,
' Variant A): "UP NEXT IN 84 MIN". Minutes only, never hours (120 MIN), whole
' minutes rounded down so it never promises sooner than it is; under a minute
' (or already due) it reads LESS THAN 1 MIN. `secondsAway` is the next
' programme's start less now.
function NxUpNextBadge(secondsAway as Dynamic) as String
    n = 0
    if NxIsNumber(secondsAway) then n = Int(secondsAway / 60)
    if n < 1 then return "UP NEXT IN LESS THAN 1 MIN"
    return "UP NEXT IN " + n.ToStr() + " MIN"
end function


' The panel's measures, the Apple TV 1.0.32's NowPlayingMetrics.swift and
' NowPlayingPanel.swift in px on the 1920 by 1080 canvas (#266): text 22, the
' item title 29, the CH tag 28; a row 64 tall with 18 each side and 8 between
' rows; two columns 440 wide, 28 apart; the poster 120 by 180 with 18 to the
' text beside it; 36 between the info zone and the controls; 90 and 60 from
' the sides and the top, 44 under the content.
function NxPanelMetrics() as Object
    return {
        text: 22, title: 29, tag: 28
        rowH: 64, padX: 18, rowGap: 8
        colW: 440, colGap: 28
        posterW: 120, posterH: 180, posterGap: 18
        zoneGap: 36, safeX: 90, safeY: 60, padBottom: 44
        hintH: 48
    }
end function

' The one line under the controls that says what the selected row does
' (NowPlayingPanelHints), by the row's id; "" for an option inside a list,
' which supplies its own.
function NxPanelHint(id as Dynamic) as String
    if not NxIsString(id) then return ""
    if id = "cc" then return "Subtitles on or off for every program."
    if id = "pick:subsLanguage" then return "Choose which subtitle track to prefer when multiple are available."
    if id = "auto" then return "Turns subtitles on when the audio is in another language."
    if id = "pick:audioTracks" then return "Pick the audio track for this program."
    if id = "pick:audioLanguage" then return "Choose which audio track to prefer when multiple are available."
    if id = "retro" then return "CRT scanlines, vignette, flicker, 4:3 aspect ratio."
    if id = "pick:streamQuality" then return "Takes effect on the next program."
    if id = "info" then return "Source codecs and how this program reaches the screen: direct play, remux or transcode."
    if id = "pick:sleep" then return "Stops playback after the time you pick. A still-watching prompt comes first."
    return ""
end function

' What a remote key does while the Now Playing panel (the top overlay) or the
' mini channel strip (the bottom one) is up, or with neither, in full screen;
' PlayerView's rules. With neither: Down pulls the panel down from the top, Up
' pushes the strip up from the bottom, Left and Right change channel. Each
' overlay is closed by the reverse of what opened it: the panel by Up, but only
' when Up had nowhere to go (the first row of a column; never from inside a
' list, which Back closes first), the strip by Down. Anything else is the
' overlay's own: "" .
function NxOverlayKey(overlay as String, key as String, firstRow as Boolean, listOpen as Boolean) as String
    if overlay = "panel" then
        if key = "up" and firstRow and not listOpen then return "close"
        return ""
    else if overlay = "strip" then
        if key = "down" then return "close"
        return ""
    end if
    if key = "down" then return "panel"
    if key = "up" then return "strip"
    if key = "left" then return "previous"
    if key = "right" then return "next"
    return ""
end function
