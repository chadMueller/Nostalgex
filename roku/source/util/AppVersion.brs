' The VERSION line on the connect screen and at the end of Settings, as the
' Apple TV app's (SettingsView connectScreenVersionLabel, BundleManagerView
' appVersionLabel): the version, then the build in brackets. The build here
' is the hash scripts/deploy.sh and release.sh write into the manifest as
' `nx_build`; a zip without one shows the version alone.
'
' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

function NxVersionLabel() as String
    info = CreateObject("roAppInfo")
    label = NxFormatVersionLabel(info.GetValue("major_version"), info.GetValue("minor_version"), info.GetValue("build_version"), info.GetValue("nx_build"))
    ' A test build keeps its own data (NxDataSpace) and says so.
    if NxDataSpace() <> "" then label = label + " TEST DATA"
    return label
end function

' From the manifest's own three numbers, so "00002" still reads 2; "?" for
' one that is missing, as upstream's label does.
function NxFormatVersionLabel(major as String, minor as String, build as String, nxBuild as String) as String
    parts = []
    for each p in [major, minor, build]
        if p.Trim() = "" then parts.Push("?") else parts.Push(p.Trim().ToInt().ToStr())
    end for
    label = "VERSION " + parts.Join(".")
    if nxBuild.Trim() <> "" then label = label + " (" + nxBuild.Trim() + ")"
    return label
end function
