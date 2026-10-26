' The viewer's franchise switches, shared by the library load and Settings.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: upstream Nostalgex/App/AppState+Franchises.swift
' (recordFranchiseChoice, isStockFranchiseOn) and FranchiseDictionary.isOn.

' The stock FRANCHISES package in channels.json (AppState.franchisesBundleID).
function NxFranchisesBundleID() as String
    return "franchises"
end function

' The viewer's explicit choices: { enabled, disabled }, each a case-sensitive
' set of stable ids. Kept as two lists, as upstream keeps
' nostalgex_enabled_franchises and nostalgex_disabled_franchises, so a
' default-on franchise switched off stays off.
function NxFranchiseChoices(enabledList as Dynamic, disabledList as Dynamic) as Object
    en = {}
    en.SetModeCaseSensitive()
    for each id in NxList(enabledList)
        if NxIsString(id) then en[id] = true
    end for
    dis = {}
    dis.SetModeCaseSensitive()
    for each id in NxList(disabledList)
        if NxIsString(id) then dis[id] = true
    end for
    return { enabled: en, disabled: dis }
end function

' recordFranchiseChoice: an explicit on or off.
sub NxFranchiseRecordChoice(choices as Object, id as String, isOn as Boolean)
    if isOn then
        choices.enabled[id] = true
        choices.disabled.Delete(id)
    else
        choices.enabled.Delete(id)
        choices.disabled[id] = true
    end if
end sub

' Sorted id lists, the form they're saved in.
function NxFranchiseChoiceLists(choices as Object) as Object
    en = []
    for each k in choices.enabled
        en.Push(k)
    end for
    en.Sort()
    dis = []
    for each k in choices.disabled
        dis.Push(k)
    end for
    dis.Sort()
    return { enabled: en, disabled: dis }
end function

' isStockFranchiseOn: a stock classic is on unless the viewer switched it off.
function NxStockFranchiseOn(id as String, choices as Object) as Boolean
    if choices.enabled.DoesExist(id) then return true
    if choices.disabled.DoesExist(id) then return false
    return true
end function

' The switches saved on the TV (Settings writes them, the library load reads
' them). Nothing saved is no choices; ParseJson("") logs an error, so it is
' skipped.
function NxSavedFranchiseChoices() as Object
    reg = NxRegSection("guide")
    lists = []
    for each key in ["franchisesOn", "franchisesOff"]
        raw = reg.Read(key)
        parsed = invalid
        if raw <> "" then parsed = ParseJson(raw)
        lists.Push(parsed)
    end for
    return NxFranchiseChoices(lists[0], lists[1])
end function
