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
    if code <> 200 then
        store.Write("tried", now&.ToStr())
        store.Flush()
        m.top.result = "failed: HTTP " + code.ToStr()
        return
    end if
    res = NxLiveChannelsStore(msg.GetString(), NxCacheRoot(), store, now&, bundled)
    if res.stored then
        m.top.result = "stored " + res.version.ToStr()
    else
        m.top.result = "rejected: " + res.reason
    end if
    print "channels: live copy "; m.top.result
end sub
