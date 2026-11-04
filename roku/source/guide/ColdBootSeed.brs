' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The cold-boot seed (#155): the next hours of the channel a launch opens on,
' kept in the registry so a launch after the TV lost power has something to
' play while the library is read again. The saved guide and pools live in
' cachefs:, which is RAM, so a power loss takes them and the app used to
' show the loading screen for the whole scan.
'
' The seed holds as many of the channel's airings as fit in a fixed budget,
' from the one on now, with the fields the play path and the guide row read
' (NxGuideBlock less the summary). Nothing secret: titles, schedules and
' part keys, as the saved guide holds. A launch with no saved guide and no
' saved pools plays from it (LibraryTask), the scan runs as a launch's does,
' and the real guide takes over: GuideView.onGuide keeps the tuned airing when
' the new guide has the same one on now, and retunes otherwise. When the seed's last
' airing ends before the scan does, the loading screen comes back
' (MainScene.onSeedEnded).

' The registry bytes the seed may take (#155: "same 10 KB budget").
function NxSeedBudget() as Integer
    return 10240
end function

' The channel the seed holds: the one a launch tunes (GuideView.onGuide
' presses channel one when no deep link or rebuild names another).
function NxSeedChannel(channels as Dynamic) as Dynamic
    if type(channels) <> "roArray" or channels.Count() = 0 then return invalid
    return channels[0]
end function

' The seed's text for a channel at atSec: its airings from the one on now,
' as many as fit in budget bytes, or "" when not even the first fits or none
' is left. The key is the build's (NxBuildKey): another build's blocks may
' not carry what this one's play path reads.
function NxSeedFrom(ch as Dynamic, atSec as LongInteger, key as String, budget as Integer) as String
    if type(ch) <> "roAssociativeArray" or type(ch.blocks) <> "roArray" then return ""
    seed = { key: key, channel: { id: ch.id, number: ch.number, name: ch.name, color: ch.color }, blocks: [] }
    text = ""
    for each b in ch.blocks
        if NxIsNumber(b.endSec) and b.endSec > atSec then
            seed.blocks.Push(NxSeedBlock(b))
            candidate = FormatJson(seed)
            if NxUtf8Bytes(candidate) > budget then exit for
            text = candidate
        end if
    end for
    return text
end function

' An airing as the seed keeps it: everything the guide block has but the
' summary, the longest field and one only the info panel reads.
function NxSeedBlock(b as Object) as Object
    out = {}
    for each k in b
        if k <> "summary" then out[k] = b[k]
    end for
    out.summary = ""
    return out
end function

function NxUtf8Bytes(s as String) as Integer
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(s)
    return bytes.Count()
end function

' The guide a launch shows from the seed text at atSec: the one channel,
' its airings that haven't ended, marked seed. invalid when there is no
' seed, it is another build's, or nothing in it is on now (the TV was off
' past its last airing). bundles is the packages on, so Settings and the
' 30 s re-check read what they always do.
function NxSeedGuide(text as String, atSec as LongInteger, key as String, bundles as Dynamic) as Dynamic
    if text = "" then return invalid
    s = ParseJson(text)
    if type(s) <> "roAssociativeArray" or NxToStr(s.key) <> key then return invalid
    if type(s.channel) <> "roAssociativeArray" or type(s.blocks) <> "roArray" then return invalid
    kept = []
    for each b in s.blocks
        if type(b) = "roAssociativeArray" and NxIsNumber(b.startSec) and NxIsNumber(b.endSec) and b.endSec > atSec then kept.Push(b)
    end for
    if kept.Count() = 0 or kept[0].startSec > atSec then return invalid
    ch = s.channel
    ch.blocks = kept
    if bundles = invalid then bundles = []
    return {
        channels: [ch], seed: true, builtAt: atSec, poolsFingerprint: "", items: 0,
        bundles: [], enabledBundles: bundles, jumps: []
    }
end function

' The registry side, in this build's data space. The off-TV interpreter has
' no registry: reads give "" and writes do nothing.
function NxSeedRead() as String
    reg = NxRegSection("seed")
    if reg = invalid then return ""
    if not reg.Exists("seed") then return ""
    return reg.Read("seed")
end function

function NxSeedWrite(text as String) as Boolean
    reg = NxRegSection("seed")
    if reg = invalid then return false
    if not reg.Write("seed", text) then return false
    return reg.Flush()
end function

' What SETTINGS and the sidebar say on a guide from the seed.
function NxSeedWaitNote() as String
    return "STILL LOADING YOUR LIBRARY" + Chr(10) + "Settings opens when it finishes."
end function
