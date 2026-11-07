' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The keys of the saved guide and pools (components/LibraryTask.brs): the
' build (NxBuildKey), the saved format, then what the guide is built from
' (the day or season, packages, choices, servers on).
'
' A launch shows a saved file whose key matches apart from the build, and the
' full build runs behind it as on any launch. Roku certification times the
' first launch after an update to AppLaunchComplete (15 s, #115), and a key
' that had to match the build too rebuilt everything there first: 34 s on a
' 43" TCL with 5,382 Emby items, where the rebuilt pools came out the same.
' Reusing the saved filter results (NxSavedFiltered) still needs the same
' build, since the filter may have changed.

' Bump the g number when a saved guide or pools file would read differently
' in this build: a change to their shape, or to what an item field means (as
' NxSnapshotFormat's 8, a bitrate in kilobits per second, not bits). A new
' item field needs no bump, though the library's format goes up for it: a
' file saved before simply lacks it, every reader treats a missing one as a
' file without it, and the guide built behind replaces the saved one.
function NxSavedFormat() as String
    return "g1"
end function

' The saved guide's key after the build: the local day, the packages on, the
' choices, and WATERSHED when it is on. The guide's schedules hold the
' switch's R, NC-17 and TV-MA titles (or don't), so a guide saved with the
' switch the other way is not shown at launch: on, it would air them before
' 9 PM until the full build replaced it (#211). Off adds nothing, so a guide
' saved before the switch existed, which is off, still shows.
function NxGuideKeyRest(dayKey as String, bundles as Object, choices as String, watershed as Boolean) as String
    rest = dayKey + "|" + FormatJson(bundles) + "|" + choices
    if watershed then rest = rest + "|watershed"
    return rest
end function

function NxSavedKey(build as String, rest as String) as String
    return build + "|" + NxSavedFormat() + "|" + rest
end function

' Whether a saved file's key can be shown at launch under the current key:
' the same once the build is left off. A key saved before NxSavedFormat has
' none, so it doesn't match.
function NxSavedKeyShowable(saved as Dynamic, current as String) as Boolean
    if not NxIsString(saved) then return false
    rest = NxSavedKeyAfterBuild(current)
    return rest <> "" and NxSavedKeyAfterBuild(saved) = rest
end function

function NxSavedKeyAfterBuild(key as String) as String
    i = Instr(1, key, "|")
    if i = 0 then return ""
    return Mid(key, i + 1)
end function
