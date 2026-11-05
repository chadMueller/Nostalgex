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
