' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' WATERSHED, as the Apple TV app's (AppState.watershedEnabled, off unless
' switched on, per TV and never synced): R, NC-17 and TV-MA titles wait for
' 9 PM on every channel without its own blockRatings. The rule itself is
' NxTimeFilteredPool and NxIsWatershedHold (Lineup.brs); the words are the
' Apple TV's (SettingsChannelsView, ChannelGuideView, WatershedCard).

function NxWatershedOn() as Boolean
    return NxRegSection("player").Read("watershed") = "1"
end function

sub NxSaveWatershed(on as Boolean)
    reg = NxRegSection("player")
    if on then reg.Write("watershed", "1") else reg.Write("watershed", "0")
    reg.Flush()
end sub

' What a held channel's guide row shows in place of its airings.
function NxWatershedRowLabel() as String
    return "BROADCASTS RESUME AT 9 PM"
end function

' The card for a tuned channel the gate has emptied, in showCard's shape:
' not a failure, so the Apple TV's cyan, and nothing counts towards a stop.
function NxWatershedCard() as Object
    return {
        kind: "watershed", serverSide: true, accent: "0x00D4FF",
        headline: "BROADCASTS WILL RESUME AT 9 PM",
        detail: "This channel's 18 and R-rated titles wait for 9 PM, like broadcast TV. Everything in its pool right now falls in that window.",
        nextStep: "Turn off Watershed in Settings to watch now."
    }
end function

' What the hold clip's Video does on a state change while it keeps the app awake
' (#190): "play" restarts it (a finished clip loops, a failed one is tried again),
' "giveup" stops it for good after the third failure, and "" does nothing. A clip
' that cannot play must not be restarted forever: `errors` counts this one.
function NxKeepAliveAction(state as String, errors as Integer) as String
    if state = "finished" then return "play"
    if state = "error" then
        if errors >= 3 then return "giveup"
        return "play"
    end if
    return ""
end function

function NxKeepAliveTries() as Integer
    return 3
end function

' How long the hold clip may sit in buffering before it counts as a failed try
' (#334). Buffering alone does nothing (NxKeepAliveAction), but a clip once stayed
' in it for about 40 minutes, and nothing looked at it again.
function NxKeepAliveStallSecs() as Integer
    return 10
end function

' What the stall timer does when it fires: a clip still buffering is a failure,
' restarted through the same three tries as an error ("play", then "giveup"
' once `errors`, counting this one, reaches three). Any other state: "".
function NxKeepAliveStallAction(state as String, errors as Integer) as String
    if state <> "buffering" then return ""
    return NxKeepAliveAction("error", errors)
end function
