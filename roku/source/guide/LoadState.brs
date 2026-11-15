' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The loading pattern (Chad 2026-11-15, the same on every platform): while the
' library loads or is rebuilt with no rows to show, the guide's empty area says so
' in one centred block, and a finished load says so in the guide's header. Chad:
' "when switching servers ... show some sort of loader ... in the guide area", "why
' there? just put it in the empty guide state", "i have no way of finding out if the
' library is finished loading or not".
'
'  - The block: a yellow title (CHANNEL GUIDE IS CHANGING after a server or library
'    switch, LOADING YOUR LIBRARY on a first load or a rescan), a progress line in
'    text2 (READ 4,210 TITLES, then the library being read; OF n only when the
'    server gave a total) and a cyan indicator that moves.
'  - Every "still loading" notice (Settings blocked) goes in the same block.
'  - A rebuild behind a guide that has rows: UPDATING LIBRARY, with a count, in the
'    header until it is done.
'  - When it is done, GUIDE READY: n TITLES in the header for about 4 s.

function NxLoadTitle(kind as String) as String
    if kind = "changing" then return "CHANNEL GUIDE IS CHANGING"
    if kind = "error" then return "COULD NOT READ YOUR LIBRARY"
    return "LOADING YOUR LIBRARY"
end function

' The block's progress line: "READ 4,210 TITLES", everything read so far across
' the libraries and servers. Nothing before the first answer.
function NxLoadProgressLine(titles as Integer) as String
    if titles <= 0 then return ""
    if titles = 1 then return "READ 1 TITLE"
    return "READ " + NxGroupedInt(titles) + " TITLES"
end function

' The library being read, under it: "MOVIES: 40 OF 40" with how far through it
' when the server gave a total (a movie library's, or a TV library's shows),
' otherwise the name alone. `done` < 0 or `total` <= 0: no total.
function NxLoadLibraryLine(name as String, done as Integer, total as Integer) as String
    label = UCase(name.Trim())
    if total > 0 and done >= 0 and done <= total then return label + ": " + NxGroupedInt(done) + " OF " + NxGroupedInt(total)
    return label
end function

function NxLoadNote() as String
    return "SETTINGS OPENS WHEN IT FINISHES"
end function

' The header's line for a rebuild behind a guide that has rows.
function NxUpdatingLine(titles as Integer) as String
    if titles <= 0 then return "UPDATING LIBRARY"
    if titles = 1 then return "UPDATING LIBRARY: 1 TITLE READ"
    return "UPDATING LIBRARY: " + NxGroupedInt(titles) + " TITLES READ"
end function

' The confirmation when the load is done: GUIDE READY: 11,813 TITLES.
function NxReadyLine(titles as Integer) as String
    if titles = 1 then return "GUIDE READY: 1 TITLE"
    return "GUIDE READY: " + NxGroupedInt(titles) + " TITLES"
end function

function NxReadyShowSec() as Integer
    return 4
end function

' Which of the guide's loading states is showing: "" none, "changing" (a server or
' library switch cleared the rows), "error" (the load failed with nothing to show),
' "load" (a first load or a rescan with no rows, or the cold-boot seed's lone
' channel while the library loads). `rows` is how many channels the guide has.
function NxLoadKind(changing as Boolean, hasError as Boolean, seeded as Boolean, busy as Boolean, rows as Integer) as String
    if hasError then return "error"
    if changing then return "changing"
    if busy and (seeded or rows = 0) then return "load"
    return ""
end function

' What the header says: GUIDE READY while its seconds last, UPDATING LIBRARY while a
' rebuild runs behind rows, otherwise nothing. `readyUntil` and `now` are seconds.
function NxHeaderNote(kind as String, busy as Boolean, rows as Integer, titles as Integer, readyTitles as Integer, readyUntil as LongInteger, nowSec as LongInteger) as String
    if readyUntil > nowSec and readyTitles > 0 then return NxReadyLine(readyTitles)
    if busy and kind = "" and rows > 0 then return NxUpdatingLine(titles)
    return ""
end function

' A load's error as the block shows it: the sentence about pressing OK to try
' again belongs to the full-screen error, and OK opens Settings here.
function NxLoadErrorText(message as String) as String
    out = message
    for each tail in [" Press OK to try again.", " Press OK to try again", "Press OK to try again."]
        at = Instr(1, out, tail)
        if at > 0 then out = Left(out, at - 1)
    end for
    return out.Trim()
end function

' The block's library line once the read is over: the step the load is on.
function NxLoadStepName(phase as String) as String
    if phase = "collections" then return "collections"
    if phase = "metadata" then return "metadata"
    if phase = "channels" then return "building channels"
    if phase = "finishing" then return "finishing"
    return ""
end function
