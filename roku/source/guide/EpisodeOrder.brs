' EPISODE ORDER (I-103): how a channel picks the episodes of a show. One setting for the whole app, in CHANNELS &
' BUNDLES (the Apple TV's EpisodeOrder, `episodeOrder` in the engine, SettingsChannelsView). Movies are never
' affected: a film is its own group in the day's ordering.
'
' CLASSIC RERUNS (the default): two consecutive episodes of a show back to back, from a random spot in the series.
' SHUFFLE: one episode at a time, picked at random. The saved choice is the player section's "episodeOrder"
' ("shuffle", or nothing for classic). The engine that reads it is source/schedule/DailyManifest.brs.

' The saved choice in `reg` (the player section by default): "shuffle", or "classic" where nothing is saved.
function NxEpisodeOrderSaved(reg = invalid as Dynamic) as String
    if reg = invalid then reg = NxRegSection("player")
    if reg.Read("episodeOrder") = "shuffle" then return "shuffle"
    return "classic"
end function

' The order a day is packed under. A thread that has taken one for its run (NxSetEpisodeOrder: the library task, which
' reads the registry before it schedules, and the tests) uses that; any other reads the saved choice each time, so a
' change in Settings reaches a component that did not make it (a global belongs to one component's thread).
function NxEpisodeOrder() as String
    taken = GetGlobalAA().nxEpisodeOrder
    if taken <> invalid then return taken
    return NxEpisodeOrderSaved()
end function

' Takes the order for this thread's run.
sub NxSetEpisodeOrder(order as String)
    if order = "shuffle" then GetGlobalAA().nxEpisodeOrder = "shuffle" else GetGlobalAA().nxEpisodeOrder = "classic"
end sub

' Reads the saved choice and takes it, and returns it: the library task does this before it schedules, as it reads
' WATERSHED (NxSetWatershed(NxWatershedOn())).
function NxSyncEpisodeOrder(reg = invalid as Dynamic) as String
    NxSetEpisodeOrder(NxEpisodeOrderSaved(reg))
    return NxEpisodeOrder()
end function

' The order a guide's schedules were packed under; a guide saved before the setting was packed under classic.
function NxGuideEpisodeOrder(guide as Object) as String
    if guide.episodeOrder = "shuffle" then return "shuffle"
    return "classic"
end function

' Saves the choice (classic is the default, so it saves nothing) and takes it for this thread.
sub NxSaveEpisodeOrder(order as String, reg = invalid as Dynamic)
    NxSetEpisodeOrder(order)
    if reg = invalid then reg = NxRegSection("player")
    if order = "shuffle" then reg.Write("episodeOrder", "shuffle") else reg.Delete("episodeOrder")
    reg.Flush()
end sub

' The words of the setting, the Apple TV's (EpisodeOrder.title, .explanation) and its next choice when the row is pressed.
function NxEpisodeOrderTitle(order as String) as String
    if order = "shuffle" then return "SHUFFLE"
    return "CLASSIC RERUNS"
end function

function NxEpisodeOrderExplanation(order as String) as String
    if order = "shuffle" then return "One episode at a time, picked at random. Movie channels are not affected."
    return "Two episodes of a show back to back, in order. Movie channels are not affected."
end function

function NxEpisodeOrderNext(order as String) as String
    if order = "shuffle" then return "classic"
    return "shuffle"
end function

' Added to a day's pool fingerprint, so a day packed under another order is packed again; nothing for classic.
function NxEpisodeOrderSuffix() as String
    if NxEpisodeOrder() = "classic" then return ""
    return "|order=" + NxEpisodeOrder()
end function

