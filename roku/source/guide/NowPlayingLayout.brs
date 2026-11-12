' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Upstream's NowPlayingPanelLayout (Services/NowPlayingPanelLogic.swift):
' which rows the panel's program column shows, in order. A language
' preference is offered only when there is something to pick between:
' SUBTITLE LANGUAGE with a subtitle track the player lists (a forced track,
' which the app draws itself since #237, isn't one), AUDIO LANGUAGE with
' more than one audio track. OPEN IN PLEX is left out, as the Roku can't
' open another app on an item.

' captionsHeader, captions, subtitleLanguage, autoSubtitles, audioHeader,
' audioTracks, audioLanguage.
function NxPanelProgramRows(hasSubtitleTracks as Boolean, audioTrackCount as Integer) as Object
    rows = ["captionsHeader", "captions"]
    if hasSubtitleTracks then
        rows.Push("subtitleLanguage")
        rows.Push("autoSubtitles")
    end if
    rows.Push("audioHeader")
    rows.Push("audioTracks")
    if audioTrackCount > 1 then rows.Push("audioLanguage")
    return rows
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

