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

' ── The loaders' skipped count ──────────────────────────────────────────────
' Movies and episodes a loader dropped for having no runtime (missing, zero,
' or under a minute: durationMin <= 0), counted where they are dropped, once
' each, for Settings' SKIPPED (NO RUNTIME) (#207). The library task resets
' it before each server's scan and reads it after; it lives in the thread's
' global AA, so a test can read it too.

sub NxScanSkipsReset()
    GetGlobalAA().nxScanSkipped = 0
    GetGlobalAA().nxScanCapped = 0
    GetGlobalAA().nxScanCapTotal = 0
end sub

sub NxScanSkipAdd()
    g = GetGlobalAA()
    g.nxScanSkipped = NxNumberOr0(g.nxScanSkipped) + 1
end sub

function NxScanSkips() as Integer
    return NxNumberOr0(GetGlobalAA().nxScanSkipped)
end function

' ── The scan's memory guard (I-091) ─────────────────────────────────────────
' A Jellyfin or Emby scan keeps every title it reads as one record (about 6 to
' 9 KB each on the stick), and the channel build, the schedule and the saved
' library then take about a quarter as much again. On a Streaming Stick Plus
' (513,802,240 bytes) a library of 72,000 titles read to 80% of the limit and
' the build took the app past it: EXIT_CHANNEL_MEM_LIMIT_FG at the end of the
' first setup, which a smaller stick reaches with fewer. So a scan stops
' reading more once the app is past NxScanMemoryCeiling percent of its own
' limit (whatever that limit is on this TV), keeps what it has read, and says
' so in the console. The fetcher answers memoryPercent() (a test's has none,
' which is never full).

function NxScanMemoryCeiling() as Integer
    return NxMemCeilingFor(NxMemLimitKB())
end function

function NxScanMemoryFull(fetcher as Object) as Boolean
    if not fetcher.DoesExist("memoryPercent") then return false
    return fetcher.memoryPercent() >= NxScanMemoryCeiling()
end function

' The ceiling for a device whose app limit is limitKB. 55% is what the Streaming Stick Plus
' (limit 501,760 KB) was measured at: the scan holds S, the channel build, the schedule and the
' saved library add about half again (peak 84% of the limit with the scan at 55%, I-091), and the
' app's own fixed memory is about 39,000 KB. A device with a smaller limit gets the ceiling that
' keeps 1.5 x S + the fixed part under 90% of ITS limit; a device with at least the Stick Plus's
' limit gets 55 exactly, as before (a normal TV must behave as it always did).
function NxMemFixedKB() as Integer
    return 39000
end function

function NxMemNormalLimitKB() as Integer
    return 480000
end function

function NxMemCeilingFor(limitKB as Integer) as Integer
    if limitKB <= 0 or limitKB >= NxMemNormalLimitKB() then return 55
    scan# = (0.9# * limitKB - NxMemFixedKB()) / 1.5#
    pct% = Int(scan# * 100# / limitKB)
    if pct% < 15 then pct% = 15
    if pct% > 55 then pct% = 55
    return pct%
end function

' The limit the guard works against, in KB: the device's own foreground limit, or, in a sideload (IsDev)
' with nx_mem_limit_kb in the manifest, a smaller one standing in for a low-memory Roku (the guard
' then sees percent of THAT). 0 when the device does not say.
function NxMemLimitKB() as Integer
    mon = CreateObject("roAppMemoryMonitor")
    limit% = 0
    lim = mon.GetChannelMemoryLimit()
    if type(lim) = "roAssociativeArray" then
        if NxIsNumber(lim.maxForegroundMemory) then limit% = lim.maxForegroundMemory
    end if
    info = CreateObject("roAppInfo")
    if info.IsDev() then
        sim% = Val(NxToStr(info.GetValue("nx_mem_limit_kb"))).ToStr().ToInt()
        if sim% > 0 and (limit% = 0 or sim% < limit%) then return sim%
    end if
    return limit%
end function

' How full the app's memory is, in percent of the limit the guard works against: the device's own percent,
' or (a simulated smaller limit) the memory in use over that limit.
function NxMemPercentNow() as Integer
    mon = CreateObject("roAppMemoryMonitor")
    pct = mon.GetMemoryLimitPercent()
    dev% = 0
    lim = mon.GetChannelMemoryLimit()
    if type(lim) = "roAssociativeArray" then
        if NxIsNumber(lim.maxForegroundMemory) then dev% = lim.maxForegroundMemory
    end if
    eff% = NxMemLimitKB()
    if dev% > 0 and eff% > 0 and eff% < dev% then return Int(pct * dev% / eff%)
    return pct
end function

' The titles a scan stopped at, 0 when it read everything, and how many the
' server holds in all (0 when it could not be counted). The library task
' resets them with the skipped count.
sub NxScanCapSet(titles as Integer, total = 0 as Integer)
    GetGlobalAA().nxScanCapped = titles
    GetGlobalAA().nxScanCapTotal = total
end sub

' The loading block's numbers (source/guide/LoadState.brs): a scan tells the
' task node how many titles it has read so far, which library it is in and how
' far through that library it is (`done` of `total`, only when the server gave
' a total; -1 and 0 otherwise). `base` is what earlier servers gave, and
' nxScanServerLabel the server's name when more than one is read.
sub NxScanBaseSet(titles as Integer, serverLabel = "" as String)
    GetGlobalAA().nxScanBase = titles
    GetGlobalAA().nxScanServerLabel = serverLabel
end sub

function NxScanTitlesRead() as Integer
    return NxNumberOr0(GetGlobalAA().nxScanTitles)
end function

sub NxScanReport(progress as Dynamic, read as Integer, name as String, done = -1 as Integer, total = 0 as Integer)
    if type(progress) <> "roSGNode" then return
    base = NxNumberOr0(GetGlobalAA().nxScanBase)
    label = NxToStr(GetGlobalAA().nxScanServerLabel)
    if label <> "" then name = label + " · " + name
    GetGlobalAA().nxScanTitles = base + read
    progress.loadInfo = { titles: base + read, name: name, done: done, total: total }
end sub

function NxScanCapped() as Integer
    return NxNumberOr0(GetGlobalAA().nxScanCapped)
end function

function NxScanCapTotal() as Integer
    return NxNumberOr0(GetGlobalAA().nxScanCapTotal)
end function

' Whether an audio track's title names a commentary (#236): "commentary"
' anywhere in it, in any case, so "Director's Commentary" too. The picks drop
' such a track while the file has another (NxMbSkipCommentary,
' NxListedSkipCommentary).
function NxIsCommentaryTitle(title as Dynamic) as Boolean
    if not NxIsString(title) then return false
    return Instr(1, LCase(title), "commentary") > 0
end function
