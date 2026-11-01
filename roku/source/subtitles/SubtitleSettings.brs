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

' Upstream's SubtitleLanguagePreset.all (Models/SubtitleLanguagePreset.swift),
' the list both language settings offer, with the Roku's name for "follow the
' device".
function NxLanguagePresets() as Object
    return [
        { code: "__system__", label: "MATCH ROKU LANGUAGE" }
        { code: "en", label: "ENGLISH" }
        { code: "es", label: "SPANISH" }
        { code: "fr", label: "FRENCH" }
        { code: "de", label: "GERMAN" }
        { code: "it", label: "ITALIAN" }
        { code: "pt-BR", label: "PORTUGUESE (BRAZIL)" }
        { code: "ja", label: "JAPANESE" }
        { code: "ko", label: "KOREAN" }
        { code: "zh-Hans", label: "CHINESE (SIMPLIFIED)" }
        { code: "zh-Hant", label: "CHINESE (TRADITIONAL)" }
        { code: "ru", label: "RUSSIAN" }
        { code: "ar", label: "ARABIC" }
        { code: "nl", label: "DUTCH" }
        { code: "pl", label: "POLISH" }
        { code: "sv", label: "SWEDISH" }
    ]
end function

' displayLabel(for:): the preset's label, else the code in capitals.
function NxLanguageLabel(code as String) as String
    for each p in NxLanguagePresets()
        if p.code = code then return p.label
    end for
    return UCase(code)
end function

' shortLabel(for:), the Now Playing panel's value for a language row:
' SYSTEM for the device's language, else the code in capitals.
function NxLanguageShortLabel(code as String) as String
    if code = "__system__" then return "SYSTEM"
    return UCase(code)
end function

' SUBTITLE LANGUAGE ("subsLanguage") or AUDIO LANGUAGE ("audioLanguage") as
' saved, "__system__" until chosen, as upstream's
' loadPreferredSubtitleLanguageInitial and loadPreferredAudioLanguageInitial.
function NxSavedLanguage(key as String) as String
    v = NxRegSection("player").Read(key)
    if v = "" then return "__system__"
    return v
end function

sub NxSaveLanguage(key as String, code as String)
    reg = NxRegSection("player")
    reg.Write(key, code)
    reg.Flush()
end sub

' The language a setting asks for, as tracks here are compared: Roku hands a
' track's language over without a region (NxSubComparableTag), so the
' setting is reduced to its language too, and PORTUGUESE (BRAZIL) matches a
' Portuguese track. "__system__" is the TV's locale.
function NxPreferredLanguageFrom(code as String, localeId as String) as String
    primary = NxSubPrimary(NxSubResolvedLanguage(code, localeId))
    if primary = invalid then return "en"
    return NxLanguageKey(primary)
end function

' Norwegian in every spelling: "no", "nb" (Bokmal) and "nn" (Nynorsk), and
' "nor", "nob" and "nno". Servers tag the same Norwegian track with any of
' them, so they are one language here: the one exception to the exact
' compare. Folded to "no" wherever two codes are compared (the setting in
' NxPreferredLanguageFrom, a track in NxSubComparableTag, both in
' NxSubMatches); NxIso639Table itself is unchanged. The same set and fold as
' the Apple TV's SubtitleSelectionLogic.languageKey and the web tuner's
' scripts/nostalgex-language.js.
function NxNorwegianCodes() as Object
    return { no: true, nb: true, nn: true, nor: true, nob: true, nno: true }
end function

' A comparable code with every Norwegian spelling folded to "no".
function NxLanguageKey(code as Dynamic) as Dynamic
    if code = invalid then return invalid
    if NxNorwegianCodes().DoesExist(code) then return "no"
    return code
end function

' upstream's resolvedPreferredSubtitleLanguageCode. Plex still sends the
' subtitle track the Plex account has selected: this picks among the tracks
' the player lists, and asks nothing of Plex.
function NxSubPreferredLanguage() as String
    return NxPreferredLanguageFrom(NxSavedLanguage("subsLanguage"), CreateObject("roDeviceInfo").GetCurrentLocale())
end function

' upstream's resolvedPreferredAudioLanguageCode.
function NxAudioPreferredLanguage() as String
    return NxPreferredLanguageFrom(NxSavedLanguage("audioLanguage"), CreateObject("roDeviceInfo").GetCurrentLocale())
end function

' The player's track for `lang` among `listed` (availableAudioTracks), as
' upstream's applyAudioTrackSelection picks with preferredTrackIndex: the
' first in that language. invalid when none is, which leaves the player's
' own choice where upstream takes the first track.
function NxAudioTrackForLanguage(listed as Object, lang as String) as Dynamic
    for each t in listed
        tag = NxSubComparableTag(t.Language)
        if tag <> invalid and NxSubMatches(tag, lang) then return t.Track
    end for
    return invalid
end function

' The name the Now Playing panel lists an audio track under. Roku lists
' some tracks with "#uniq:" in front of the name ("#uniq:Italiano ..."), seen
' on an Emby film's audio tracks (2026-10-28): that marker isn't for the
' viewer, so it is dropped. A track with no name is its language in capitals,
' else "Track" and its place in the list, as before.
function NxAudioTrackLabel(name as Dynamic, language as Dynamic, position as Integer) as String
    label = NxToStr(name).Trim()
    if LCase(Left(label, 6)) = "#uniq:" then label = Mid(label, 7).Trim()
    if label = "" then label = UCase(NxToStr(language).Trim())
    if label = "" then label = "Track " + (position + 1).ToStr()
    return label
end function

' Roku reports a track's language as the stream gives it: Plex's HLS says
' "eng", where AVFoundation hands upstream "en". A track's language as one
' code, so two are the same language only when their codes are equal
' (issue #119): the language without a region, and a three-letter code as
' its two-letter one from ISO 639-2, both forms ("ger" and "deu" are "de").
' Comparing first letters made "est" (Estonian) Spanish and "cze" not "cs".
' A three-letter code with no two-letter form ("yue", Cantonese) stays as
' it is, so it still counts as a language for FOREIGN AUDIO. invalid for
' none, and for "und", "mul", "zxx" and "mis", which match nothing.
' Every Norwegian spelling comes back as "no" (NxLanguageKey).
function NxSubComparableTag(lang as Dynamic) as Dynamic
    if lang = invalid then return invalid
    t = LCase(NxToStr(lang)).Trim().Replace("_", "-")
    dash = Instr(1, t, "-")
    if dash > 0 then t = Left(t, dash - 1)
    if t = "" or t = "und" or t = "mul" or t = "zxx" or t = "mis" then return invalid
    if Len(t) <> 3 then return NxLanguageKey(t)
    g = GetGlobalAA()
    if g.nxIso639 = invalid then g.nxIso639 = NxIso639Table()
    if g.nxIso639.DoesExist(t) then return NxLanguageKey(g.nxIso639[t])
    return NxLanguageKey(t)
end function

' ISO 639-2 to 639-1, the terminology and bibliographic forms: the
' maintainer's table from issue #119.
function NxIso639Table() as Object
    pairs = "aar:aa abk:ab afr:af aka:ak alb:sq sqi:sq amh:am ara:ar arg:an arm:hy hye:hy asm:as ava:av ave:ae aym:ay aze:az bak:ba bam:bm baq:eu eus:eu bel:be ben:bn bis:bi bod:bo tib:bo bos:bs bre:br bul:bg bur:my mya:my cat:ca ces:cs cze:cs cha:ch che:ce chi:zh zho:zh chu:cu chv:cv cor:kw cos:co cre:cr cym:cy wel:cy dan:da deu:de ger:de div:dv dut:nl nld:nl dzo:dz ell:el gre:el eng:en epo:eo est:et ewe:ee fao:fo fas:fa per:fa fij:fj fin:fi fra:fr fre:fr fry:fy ful:ff geo:ka kat:ka gla:gd gle:ga glg:gl glv:gv grn:gn guj:gu hat:ht hau:ha heb:he her:hz hin:hi hmo:ho hrv:hr hun:hu ibo:ig ice:is isl:is ido:io iii:ii iku:iu ile:ie ina:ia ind:id ipk:ik ita:it jav:jv jpn:ja kal:kl kan:kn kas:ks kau:kr kaz:kk khm:km kik:ki kin:rw kir:ky kom:kv kon:kg kor:ko kua:kj kur:ku lao:lo lat:la lav:lv lim:li lin:ln lit:lt ltz:lb lub:lu lug:lg mac:mk mkd:mk mah:mh mal:ml mao:mi mri:mi mar:mr may:ms msa:ms mlg:mg mlt:mt mon:mn nau:na nav:nv nbl:nr nde:nd ndo:ng nep:ne nno:nn nob:nb nor:no nya:ny oci:oc oji:oj ori:or orm:om oss:os pan:pa pli:pi pol:pl por:pt pus:ps que:qu roh:rm ron:ro rum:ro run:rn rus:ru sag:sg san:sa sin:si slk:sk slo:sk slv:sl sme:se smo:sm sna:sn snd:sd som:so sot:st spa:es srd:sc srp:sr ssw:ss sun:su swa:sw swe:sv tah:ty tam:ta tat:tt tel:te tgk:tg tgl:tl tha:th tir:ti ton:to tsn:tn tso:ts tuk:tk tur:tr twi:tw uig:ug ukr:uk urd:ur uzb:uz ven:ve vie:vi vol:vo wln:wa wol:wo xho:xh yid:yi yor:yo zha:za zul:zu"
    t = {}
    for each p in pairs.Split(" ")
        kv = p.Split(":")
        t[kv[0]] = kv[1]
    end for
    return t
end function
