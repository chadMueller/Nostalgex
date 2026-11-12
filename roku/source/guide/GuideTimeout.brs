' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' GUIDE TIMEOUT (Settings > PLAYBACK & PICTURE, #274): after this long with no
' remote press on the guide, the playing channel goes full screen, so the logo,
' header and grid lines do not sit still on an OLED screen for hours. The
' Apple TV's GuideTimeout.swift and the web tuner's scripts/nostalgex-guide-
' timeout.js: OFF, 5 MIN, 15 MIN, 5 MIN until chosen, kept per TV, sent nowhere.

function NxGuideTimeoutValues() as Object
    return ["off", "5m", "15m"]
end function

function NxGuideTimeoutDefault() as String
    return "5m"
end function

' Anything that is not one of the three stored values is the default.
function NxGuideTimeoutParse(stored as Dynamic) as String
    if NxIsString(stored) and NxHasValue(NxGuideTimeoutValues(), stored) then return stored
    return NxGuideTimeoutDefault()
end function

' What one press on the row moves to: OFF, 5 MIN, 15 MIN, and round again.
function NxGuideTimeoutNext(value as Dynamic) as String
    values = NxGuideTimeoutValues()
    cur = NxGuideTimeoutParse(value)
    for i = 0 to values.Count() - 1
        if values[i] = cur then return values[(i + 1) mod values.Count()]
    end for
    return NxGuideTimeoutDefault()
end function

function NxGuideTimeoutLabel(value as Dynamic) as String
    v = NxGuideTimeoutParse(value)
    if v = "off" then return "OFF"
    if v = "5m" then return "5 MIN"
    return "15 MIN"
end function

' Seconds, 0 for OFF.
function NxGuideTimeoutSeconds(value as Dynamic) as Integer
    v = NxGuideTimeoutParse(value)
    if v = "5m" then return 300
    if v = "15m" then return 900
    return 0
end function

' Whether the guide should hand over to full screen now (GuideTimeout.shouldGoFullscreen):
' a timeout is set (`seconds` over 0), the guide is the screen in front of the
' viewer and a channel is playing, and the last remote press was `seconds` ago
' or longer. Settings, the loading screen, a dialog and an empty guide are left
' alone: the caller passes guideIsFront false for them.
function NxGuideShouldGoFullscreen(seconds as Integer, lastActivitySec as LongInteger, nowSec as LongInteger, guideIsFront as Boolean, isPlaying as Boolean) as Boolean
    if seconds <= 0 or not guideIsFront or not isPlaying then return false
    return nowSec - lastActivitySec >= seconds
end function

' The saved choice, per TV, in the player section; nothing saved is the default.
function NxGuideTimeoutRead() as String
    return NxGuideTimeoutParse(NxRegSection("player").Read("guideTimeout"))
end function

sub NxSaveGuideTimeout(value as String)
    reg = NxRegSection("player")
    reg.Write("guideTimeout", NxGuideTimeoutParse(value))
    reg.Flush()
end sub
