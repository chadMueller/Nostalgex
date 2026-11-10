' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' OPEN ON LAST CHANNEL (#230), as the Apple TV app's LaunchChannelMemory and
' the web tuner's scripts/nostalgex-last-channel.js: a launch opens on the
' channel the viewer last tuned, instead of the first one in the guide.
'
' On unless someone turns it off. Per TV, in the registry, sent nowhere. The
' channel is saved whether the switch is on or off, so turning it on opens
' on what was last watched. Only a tune the viewer makes is saved
' (GuideView.viewerTune): the first channel after a load, a rebuild's resume
' and a deep link are not.
'
' What is saved is the channel's id AND its name. A collection or franchise
' channel can be renumbered when the lineup is rebuilt, so an id alone could
' open a different channel. A saved channel that is gone, or whose name no
' longer matches, opens the first channel, as before this setting.
'
' Every function takes the registry section, so the tests run on a stand-in
' (the off-TV interpreter has no registry).

function NxLastChannelRegistry() as Object
    return NxRegSection("player")
end function

' The one line the default lives on (LaunchChannelMemory.enabledByDefault,
' OPEN_DEFAULT on the web). A switch the viewer pressed is stored and wins.
function NxLastChannelOnByDefault() as Boolean
    return true
end function

' Nothing stored: the default. A stored "1" is on, anything else stored is off.
function NxLastChannelOn(reg as Dynamic) as Boolean
    if reg = invalid then return NxLastChannelOnByDefault()
    stored = reg.Read("openLastChannel")
    if stored = "" then return NxLastChannelOnByDefault()
    return stored = "1"
end function

sub NxSaveLastChannelOn(reg as Dynamic, on as Boolean)
    if reg = invalid then return
    if on then reg.Write("openLastChannel", "1") else reg.Write("openLastChannel", "0")
    reg.Flush()
end sub

' What is stored for a channel, or "" when it has no id or no name: nothing
' to match later.
function NxLastChannelText(ch as Dynamic) as String
    if type(ch) <> "roAssociativeArray" then return ""
    id = NxToStr(ch.id)
    if id = "" then return ""
    if type(ch.name) <> "roString" and type(ch.name) <> "String" then return ""
    if ch.name = "" then return ""
    return FormatJson({ id: id, name: ch.name })
end function

' The stored text back as { id, name }, or invalid for anything that is not
' what NxLastChannelText wrote.
function NxLastChannelParse(text as Dynamic) as Dynamic
    if type(text) <> "roString" and type(text) <> "String" then return invalid
    ' ParseJson prints a line for text that isn't JSON; an object is all this reads.
    if Left(text.Trim(), 1) <> "{" then return invalid
    v = ParseJson(text)
    if type(v) <> "roAssociativeArray" then return invalid
    id = NxToStr(v.id)
    if id = "" then return invalid
    if type(v.name) <> "roString" and type(v.name) <> "String" then return invalid
    if v.name = "" then return invalid
    return { id: id, name: v.name }
end function

' Records a channel the viewer tuned. True when the stored channel changed:
' the registry is flash, so the same channel again writes nothing.
function NxRememberChannel(reg as Dynamic, ch as Dynamic) as Boolean
    if reg = invalid then return false
    text = NxLastChannelText(ch)
    if text = "" or text = reg.Read("lastChannel") then return false
    if not reg.Write("lastChannel", text) then return false
    reg.Flush()
    return true
end function

function NxLastChannelSaved(reg as Dynamic) as Dynamic
    if reg = invalid then return invalid
    return NxLastChannelParse(reg.Read("lastChannel"))
end function

' Sign-out, and a fresh sign-in over another account's saved library
' (NxClearAccountCaches): the channel belongs to the
' lineup that was just left. The switch stays as it is.
sub NxForgetLastChannel(reg as Dynamic)
    if reg = invalid then return
    reg.Delete("lastChannel")
    reg.Flush()
end sub

' Where `saved` (NxLastChannelParse's answer) sits in the guide's channels:
' the one with the same id and the same name, or -1.
function NxLastChannelIndex(saved as Dynamic, channels as Dynamic) as Integer
    if type(saved) <> "roAssociativeArray" or type(channels) <> "roArray" then return -1
    for i = 0 to channels.Count() - 1
        ch = channels[i]
        if type(ch) = "roAssociativeArray" then
            if NxToStr(ch.id) = saved.id and NxToStr(ch.name) = saved.name then return i
        end if
    end for
    return -1
end function

' The channel a launch opens on, as an index into the guide's channels: the
' saved one when the switch is on and it is still there under the same name.
' -1 otherwise, and the caller opens where it did before.
function NxChannelToOpen(reg as Dynamic, channels as Dynamic) as Integer
    if not NxLastChannelOn(reg) then return -1
    return NxLastChannelIndex(NxLastChannelSaved(reg), channels)
end function
