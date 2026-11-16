' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    m.top.functionName = "fetchChannels"
end sub

' One GET with a 12 second limit, in this task's thread: the guide never waits
' for it. The registry section "livechannels" holds the time of the last try.
sub fetchChannels()
    store = NxRegSection("livechannels")
    now& = CreateObject("roDateTime").AsSeconds()
    bundled = NxLiveVersionOf(ReadAsciiFile("pkg:/data/channels.json"))
    xfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    xfer.SetUrl(NxLiveChannelsUrl())
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.EnablePeerVerification(true)
    xfer.EnableHostVerification(true)
    xfer.EnableEncodings(true)
    xfer.AddHeader("Accept", "application/json")
    xfer.AddHeader("User-Agent", "Nostalgex/Roku channels")
    ' Conditional: the server answers 304 with no body while the file is the one already kept.
    etag = store.Read("etag")
    if etag <> "" then xfer.AddHeader("If-None-Match", etag)
    clock = CreateObject("roTimespan")
    if not xfer.AsyncGetToString() then
        store.Write("tried", now&.ToStr())
        store.Flush()
        m.top.result = "failed: not started"
        return
    end if
    msg = Wait(12000, port)
    if type(msg) <> "roUrlEvent" then
        xfer.AsyncCancel()
        store.Write("tried", now&.ToStr())
        store.Flush()
        m.top.result = "failed: timeout"
        return
    end if
    code = msg.GetResponseCode()
    print "channels: the live file answered "; code; " in "; clock.TotalMilliseconds(); " ms"
    if code = 304 then
        store.Write("tried", now&.ToStr())
        store.Flush()
        m.top.result = "unchanged"
        return
    end if
    if code <> 200 then
        store.Write("tried", now&.ToStr())
        store.Flush()
        m.top.result = "failed: HTTP " + code.ToStr()
        return
    end if
    clock.Mark()
    previous = Val(store.Read("version")).ToStr().ToInt()
    res = NxLiveChannelsStore(msg.GetString(), NxCacheRoot(), store, now&, bundled)
    print "channels: checked and kept in "; clock.TotalMilliseconds(); " ms; memory "; CreateObject("roAppMemoryMonitor").GetMemoryLimitPercent(); "%"
    if res.stored and type(msg.GetResponseHeaders()) = "roAssociativeArray" then
        store.Write("etag", NxToStr(msg.GetResponseHeaders().etag))
        store.Flush()
    end if
    if res.stored and NxLiveChannelsIsNew(res.version, previous, bundled) then
        ' A copy newer than the one in use: the guide builds from it at a safe point (MainScene).
        m.top.result = "new " + res.version.ToStr()
    else if res.stored then
        m.top.result = "stored " + res.version.ToStr()
    else
        m.top.result = "rejected: " + res.reason
    end if
    print "channels: live copy "; m.top.result
end sub
