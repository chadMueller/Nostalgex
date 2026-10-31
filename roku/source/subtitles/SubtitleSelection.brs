' Subtitle preference logic, ported from upstream's SubtitleSelectionLogic.swift
' (Nostalgex/Nostalgex/Services). A missing tag is `invalid`, as Swift's nil.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.

' Stored setting to a language code; "__system__" follows the TV's locale.
function NxSubResolvedLanguage(storedCode as String, localeId as String) as String
    if storedCode = "__system__" then
        primary = NxSubPrimary(localeId)
        if primary = invalid then return "en"
        return primary
    end if
    return storedCode
end function

' "pt_BR" or "pt-BR" to "pt"; invalid when empty.
function NxSubPrimary(id as String) as Dynamic
    raw = LCase(id.Replace("_", "-"))
    dash = Instr(1, raw, "-")
    if dash > 0 then return Left(raw, dash - 1)
    if raw = "" then return invalid
    return raw
end function

' A comparable tag: the extended tag lowercased, else the locale's primary
' language.
function NxSubLanguageTag(extendedTag as Dynamic, localeId as Dynamic) as Dynamic
    if extendedTag <> invalid and extendedTag.Trim() <> "" then return LCase(extendedTag)
    if localeId = invalid then return invalid
    return NxSubPrimary(localeId)
end function

' True when every audio track's language is known and none is the preferred
' one. Any unknown, empty or "und" tag rules it out: never guess.
function NxSubShouldAutoEnable(audioTags as Object, preferredAudio as String) as Boolean
    if audioTags.Count() = 0 then return false
    for each tag in audioTags
        if tag = invalid then return false
        t = LCase(tag)
        if t = "" or t = "und" then return false
        if NxSubMatches(t, preferredAudio) then return false
    end for
    return true
end function

' Index of the first tag for `preferred` (primary or full tag), else 0.
function NxSubPreferredTrackIndex(tags as Object, preferred as String) as Integer
    for i = 0 to tags.Count() - 1
        if tags[i] <> invalid and NxSubMatches(LCase(tags[i]), preferred) then return i
    end for
    return 0
end function

' pickLegibleOption: the first track in `preferred` that isn't forced
' (`forced[i]` true), else NxSubPreferredTrackIndex over them all, which
' may land on a forced one when that is all there is.
function NxSubPickIndex(tags as Object, forced as Object, preferred as String) as Integer
    for i = 0 to tags.Count() - 1
        if forced[i] <> true and tags[i] <> invalid and NxSubMatches(LCase(tags[i]), preferred) then return i
    end for
    return NxSubPreferredTrackIndex(tags, preferred)
end function

function NxSubMatches(tag as String, want as String) as Boolean
    if tag = want or Left(tag, Len(want) + 1) = want + "-" then return true
    ' Norwegian in any spelling (NxLanguageKey): "nb-no" for "no", "nn" for "nb".
    n = NxNorwegianCodes()
    return n.DoesExist(NxSubPrimaryOf(tag)) and n.DoesExist(NxSubPrimaryOf(want))
end function

' The language part of a tag, before any "-": "nb-no" to "nb".
function NxSubPrimaryOf(tag as String) as String
    dash = Instr(1, tag, "-")
    if dash > 0 then return Left(tag, dash - 1)
    return tag
end function
