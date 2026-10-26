' Small helpers for values that came from JSON, shared by every module.
'
' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

function NxList(v as Dynamic) as Object
    if type(v) = "roArray" then return v
    return []
end function

function NxIsNumber(v as Dynamic) as Boolean
    t = type(v)
    return t = "Integer" or t = "roInt" or t = "roInteger" or t = "LongInteger" or t = "roLongInteger" or t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble"
end function

function NxIsString(v as Dynamic) as Boolean
    t = type(v)
    return t = "String" or t = "roString"
end function

' JS truthiness for the values JSON can hold.
function NxTruthy(v as Dynamic) as Boolean
    if v = invalid then return false
    if type(v) = "Boolean" or type(v) = "roBoolean" then return v
    if NxIsString(v) then return v <> ""
    if NxIsNumber(v) then return v <> 0
    return true
end function

' JS `a || b`.
function NxOr(a as Dynamic, b as Dynamic) as Dynamic
    if NxTruthy(a) then return a
    return b
end function

function NxNumberOr0(v as Dynamic) as Dynamic
    if NxIsNumber(v) then return v
    return 0
end function

function NxToStr(v as Dynamic) as String
    if v = invalid then return ""
    if NxIsString(v) then return v
    if NxIsNumber(v) then
        if type(v) = "Float" or type(v) = "roFloat" or type(v) = "Double" or type(v) = "roDouble" then
            if v = Int(v) then return Int(v).ToStr()
        end if
        return v.ToStr()
    end if
    if type(v) = "Boolean" or type(v) = "roBoolean" then
        if v then return "true"
        return "false"
    end if
    return ""
end function

function NxHasValue(list as Object, v as Dynamic) as Boolean
    for each x in list
        if x = v then return true
    end for
    return false
end function

' Math.floor of a Double, exactly, for |d| < 2^46 (the first guess must fit
' an Integer). Int() takes a Float on a Roku, so past 2^24 it rounds first
' (Jellyfin dates came out up to 64 s off, Discussion #8); here it only
' makes the first guess.
function NxFloorDouble(d as Double) as LongInteger
    a& = Int(d / 65536#)
    a& = a& * 65536&
    while a& > d
        a& = a& - 65536&
    end while
    while a& + 65536& <= d
        a& = a& + 65536&
    end while
    ' a& <= d < a& + 65536: the largest step that stays at or under d.
    stepSize& = 32768&
    while stepSize& >= 1
        if a& + stepSize& <= d then a& = a& + stepSize&
        stepSize& = stepSize& \ 2
    end while
    return a&
end function

' ── Where the app keeps its data ────────────────────────────────────────────

' Every app signed with one developer key shares one registry, so the build
' scripts/deploy.sh sideloads and the store app read and write the same
' sign-in, packages and settings (and may share cachefs: files). A test build (NX_TEST_DATA=1 deploy.sh)
' carries nx_data_ns in its manifest, and its registry sections and cachefs:
' files then sit apart: section "nxtest-guide", files under cachefs:/nxtest.
' release.sh refuses a manifest with the key, so a release always reads ""
' and keeps the names it always had.
function NxDataSpace() as String
    g = GetGlobalAA()
    if g.nxDataSpace = invalid then g.nxDataSpace = NxDataSpaceFrom(CreateObject("roAppInfo").GetValue("nx_data_ns"))
    return g.nxDataSpace
end function

' The manifest value as a name: lowercase letters and digits only, at most
' 16. Nothing, or nothing usable, is the release's "".
function NxDataSpaceFrom(value as Dynamic) as String
    if not NxIsString(value) then return ""
    v = CreateObject("roRegex", "[^a-z0-9]", "").ReplaceAll(LCase(value), "")
    return Left(v, 16)
end function

' A registry section in this build's data space.
function NxRegSection(name as String) as Object
    return CreateObject("roRegistrySection", NxRegName(name, NxDataSpace()))
end function

function NxRegName(name as String, space as String) as String
    if space = "" then return name
    return space + "-" + name
end function

' The cachefs: folder this build keeps its files in: cachefs: itself for a
' release, cachefs:/<space> for a test build (made when first asked for,
' once per thread). The global CreateDirectory, not roFileSystem: SIGN OUT
' clears the caches on the render thread, where CreateObject("roFileSystem")
' gives invalid (a test build crashed there). It returns false for a folder
' that is already there, which is fine.
function NxCacheRoot() as String
    space = NxDataSpace()
    if space = "" then return "cachefs:"
    root = NxCacheRootFor("cachefs:", space)
    g = GetGlobalAA()
    if g.nxCacheRootMade <> root then
        CreateDirectory(root)
        g.nxCacheRootMade = root
    end if
    return root
end function

function NxCacheRootFor(base as String, space as String) as String
    if space = "" then return base
    return base + "/" + space
end function
