' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Which of the account's servers the guide reads, as the Apple TV app's
' ServerPickerView defaults them (Plex90App.swift): owned servers, or all of
' them when none is owned. The web tuner takes every server. Settings lists
' each one to switch, and those choices win.
'
' Sign-in keeps every reachable server in the registry's "servers" list, so a
' guide item's serverIndex stays valid whichever are on. Choices are a
' { machineIdentifier: Boolean } map in "serverChoices", gone at sign-out.

' One Boolean per server: the viewer's choice, else owned. When no server is
' owned (an account that only has shared ones), all are on by default.
function NxServersOn(servers as Object, choices as Dynamic) as Object
    if type(choices) <> "roAssociativeArray" then choices = {}
    anyOwned = false
    for each s in servers
        if NxTruthy(s.owned) then anyOwned = true
    end for
    on = []
    for each s in servers
        id = NxToStr(s.machineIdentifier)
        if id <> "" and choices.DoesExist(id) then
            on.Push(choices[id] = true)
        else
            on.Push(NxTruthy(s.owned) or not anyOwned)
        end if
    end for
    ' A choice that turned every server off is not one: fall back to all.
    if not NxHasValue(on, true) then
        for i = 0 to on.Count() - 1
            on[i] = true
        end for
    end if
    return on
end function

' The saved choices, or invalid when there are none. An empty read isn't
' handed to ParseJson, which logs an error for it.
function NxSavedServerChoices() as Dynamic
    raw = NxRegSection("plex").Read("serverChoices")
    if raw = "" then return invalid
    return ParseJson(raw)
end function

' What the saved guide and pools are keyed on: the servers that are on.
function NxServersOnKey(servers as Object, choices as Dynamic) as String
    on = NxServersOn(servers, choices)
    ids = []
    for i = 0 to servers.Count() - 1
        if on[i] then ids.Push(NxToStr(servers[i].machineIdentifier))
    end for
    return ids.Join(",")
end function
