' The TV's side of enrichment: HTTPS through roUrlTransfer for
' source/enrich/Enrichment.brs, a registry home for the OMDb backoff, and the
' progress line. Nothing here runs off-device; the tests use a stub network.
'
' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

' opts.net: fetchAll(requests, limit) runs up to `limit` requests at once and
' returns { status, body } for each, in order. Status is the HTTP code, or 0
' for a network error, a timeout or a refused URL. Only HTTPS goes out.
function NxEnrichmentNet() as Object
    return { timeoutMs: 15000, fetchAll: NxEnrichNetFetchAll }
end function

function NxEnrichNetFetchAll(requests as Object, limit as Integer) as Object
    results = []
    for each req in requests
        results.Push({ status: 0, body: "" })
    end for
    port = CreateObject("roMessagePort")
    active = {}
    nextIndex = 0
    while nextIndex < requests.Count() or active.Count() > 0
        while nextIndex < requests.Count() and active.Count() < limit
            req = requests[nextIndex]
            if LCase(Left(req.url, 8)) = "https://" then
                xfer = CreateObject("roUrlTransfer")
                xfer.SetMessagePort(port)
                xfer.SetUrl(req.url)
                xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
                xfer.EnablePeerVerification(true)
                xfer.EnableHostVerification(true)
                xfer.RetainBodyOnError(true)
                xfer.SetHeaders(req.headers)
                xfer.SetRequest(req.method)
                if req.method = "POST" then
                    ok = xfer.AsyncPostFromString(NxToStr(req.body))
                else
                    ok = xfer.AsyncGetToString()
                end if
                if ok then
                    timer = CreateObject("roTimespan")
                    active[xfer.GetIdentity().ToStr()] = { xfer: xfer, index: nextIndex, timer: timer }
                end if
            end if
            nextIndex = nextIndex + 1
        end while
        if active.Count() = 0 then exit while
        msg = Wait(500, port)
        if type(msg) = "roUrlEvent" then
            id = msg.GetSourceIdentity().ToStr()
            a = active[id]
            if a <> invalid then
                code = msg.GetResponseCode()
                if code < 0 then code = 0
                results[a.index] = { status: code, body: msg.GetString() }
                active.Delete(id)
            end if
        end if
        for each id in active.Keys()
            if active[id].timer.TotalMilliseconds() > m.timeoutMs then
                active[id].xfer.AsyncCancel()
                active.Delete(id)
            end if
        end for
    end while
    return results
end function

' Where the OMDb backoff lives between launches.
function NxEnrichRegistryStore() as Object
    return {
        section: NxRegSection("enrichment"),
        read: function() as Dynamic
            return m.section.Read("omdbBlockedUntil")
        end function,
        write: sub(s as String)
            m.section.Write("omdbBlockedUntil", s)
            m.section.Flush()
        end sub
    }
end function

' Progress on the loading screen, from a Task thread.
function NxEnrichTopProgress(top as Object) as Object
    return {
        top: top,
        report: sub(done as Integer, total as Integer, phase as String)
            if phase = "cache" then
                m.top.progress = "Reading shared details: " + done.ToStr() + " of " + total.ToStr()
            else
                m.top.progress = "Fetching details: " + done.ToStr() + " of " + total.ToStr()
            end if
            ' Upstream's "Metadata n/t" bar; no bar until there is a total.
            if total > 0 then
                m.top.bar = done / total
                m.top.barCaption = "Metadata " + done.ToStr() + "/" + total.ToStr()
            end if
        end sub
    }
end function
