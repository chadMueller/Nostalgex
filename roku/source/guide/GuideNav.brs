' Vertical moves in the guide grid, after upstream's ChannelGuideView.swift
' (66033f6, "Up out of channel one belongs to SETTINGS, so only the downward
' wrap gets a sentinel"): Down from the last channel wraps to channel one, Up
' from channel one does not wrap. On the Roku, SETTINGS is the sidebar's first
' row, one Left press away. With fewer than two channels there is nothing to
' wrap to. Returns the new focus index, or -1 when the press isn't handled.
function NxGuideStep(focus as Integer, count as Integer, key as String) as Integer
    if key = "down" then
        if focus < count - 1 then return focus + 1
        if count > 1 then return 0
    else if key = "up" then
        if focus > 0 then return focus - 1
    end if
    return -1
end function

' Back on the guide grid. Away from the live channel it returns there, as
' Menu does on Apple TV (GuideExitAction). On the live channel it leaves the
' app, but a stream the server is encoding is stopped first: Roku doesn't
' pass Home to the app, so this is the one exit that can end the encode
' (#81). Returns "live", "stop" (send the stop, then leave) or "leave"
' (let Roku close the app).
function NxGuideBack(focus as Integer, tuned as Integer, slotOffset as Integer, encoding as Boolean) as String
    if focus <> tuned or slotOffset <> 0 then return "live"
    if encoding then return "stop"
    return "leave"
end function
