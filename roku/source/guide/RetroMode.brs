' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' RETRO MODE, as the Apple TV app's (AppState.retroMode, on unless switched
' off; BundleManagerView): the guide's video cropped to 4:3 under a CRT
' overlay, and full screen under the same overlay (RetroLook, upstream
' e48cdc1).

function NxRetroMode() as Boolean
    return NxRegSection("player").Read("retro") <> "0"
end function

sub NxSaveRetroMode(on as Boolean)
    reg = NxRegSection("player")
    if on then reg.Write("retro", "1") else reg.Write("retro", "0")
    reg.Flush()
end sub
