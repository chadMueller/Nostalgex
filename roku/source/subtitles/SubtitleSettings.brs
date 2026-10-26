' The subtitle settings, kept on the TV, and the Roku side of matching
' languages.
'
' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

' { always, foreign }: upstream's subtitlesInFullscreenEnabled, off until
' chosen, and autoSubtitlesForForeignAudioEnabled, on until chosen
' (AppState.swift: `?? true`), so a fresh install reads FOREIGN AUDIO.
function NxSubtitleSettings() as Object
    reg = NxRegSection("player")
    return NxSubtitleSettingsFrom(reg.Read("subsAlways"), reg.Read("subsForeign"))
end function

' From the saved values, "" when never saved.
function NxSubtitleSettingsFrom(always as String, foreign as String) as Object
    return { always: always = "1", foreign: foreign <> "0" }
end function

' Only a flag that changed is written, as upstream writes one key per
' setting: the CC toggle saves ALWAYS and leaves FOREIGN AUDIO unchosen, so
' its default still applies.
sub NxSaveSubtitleSettings(s as Object)
    reg = NxRegSection("player")
    was = NxSubtitleSettings()
    if s.always <> was.always then reg.Write("subsAlways", NxFlag(s.always))
    if s.foreign <> was.foreign then reg.Write("subsForeign", NxFlag(s.foreign))
    reg.Flush()
end sub

function NxFlag(on as Boolean) as String
    if on then return "1"
    return "0"
end function

' The TV's language, as upstream's "__system__" setting resolves it. There is
' no language picker here: Plex sends one subtitle track, the one this Plex
' account has selected, so a preference has nothing to choose between.
function NxSubPreferredLanguage() as String
    return NxSubResolvedLanguage("__system__", CreateObject("roDeviceInfo").GetCurrentLocale())
end function

' Roku reports a track's language as the stream gives it: Plex's HLS says
' "eng", where AVFoundation hands upstream "en". Two-letter codes for the
' three-letter ones of upstream's language list; others pass through.
function NxSubComparableTag(lang as Dynamic) as Dynamic
    if lang = invalid then return invalid
    t = LCase(NxToStr(lang)).Trim()
    if t = "" then return invalid
    iso2 = { eng: "en", spa: "es", fre: "fr", fra: "fr", ger: "de", deu: "de", ita: "it", por: "pt", jpn: "ja", kor: "ko", chi: "zh", zho: "zh", rus: "ru", ara: "ar", dut: "nl", nld: "nl", pol: "pl", swe: "sv" }
    if iso2.DoesExist(t) then return iso2[t]
    return t
end function
